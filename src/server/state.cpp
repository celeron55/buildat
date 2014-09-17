#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
//#include "interface/thread.h"
#include "interface/mutex.h"
#include <c55/log.h>
#include <iostream>
#include <algorithm>

using interface::Event;

extern server::Config g_server_config;

namespace server {

struct CState: public State, public interface::Server
{
	struct ModuleWithMutex {
		interface::Mutex mutex;
		interface::Module *module;

		ModuleWithMutex(interface::Module *module = NULL): module(module){}
	};

	struct SocketState {
		int fd = 0;
		Event::Type event_type;
	};

	up_<rccpp::Compiler> m_compiler;
	ss_ m_modules_path;

	sm_<ss_, ModuleWithMutex> m_modules;
	interface::Mutex m_modules_mutex;

	sv_<Event> m_event_queue;
	interface::Mutex m_event_queue_mutex;

	sv_<sv_<ModuleWithMutex*>> m_event_subs;
	interface::Mutex m_event_subs_mutex;

	sm_<int, SocketState> m_sockets;
	interface::Mutex m_sockets_mutex;

	CState():
		m_compiler(rccpp::createCompiler())
	{
		m_compiler->include_directories.push_back(
		    g_server_config.interface_path);
		m_compiler->include_directories.push_back(
		    g_server_config.interface_path+"/..");
		m_compiler->include_directories.push_back(
		    g_server_config.interface_path+"/../../3rdparty/cereal/include");
		m_compiler->include_directories.push_back(
		    g_server_config.share_path+"/builtin");
	}
	~CState()
	{
		interface::MutexScope ms(m_modules_mutex);
		for(auto &pair : m_modules){
			ModuleWithMutex &mwm = pair.second;
			// Don't lock; it would only cause deadlocks
			delete mwm.module;
		}
	}

	void load_module(const ss_ &module_name, const ss_ &path)
	{
		interface::MutexScope ms(m_modules_mutex);

		std::cerr<<"Loading module "<<module_name<<" from "<<path<<std::endl;
		ss_ build_dst = g_server_config.rccpp_build_path +
		                "/"+module_name+".so";
		m_compiler->include_directories.push_back(m_modules_path);
		m_compiler->build(module_name, path+"/server/init.cpp", build_dst);
		m_compiler->include_directories.pop_back();

		interface::Module *m = static_cast<interface::Module*>(
		                           m_compiler->construct(module_name.c_str(), this));
		m_modules[module_name] = ModuleWithMutex(m);

		{
			ModuleWithMutex &mwm = m_modules[module_name];
			interface::MutexScope ms2(mwm.mutex);
			mwm.module->init();
		}
	}

	void load_modules(const ss_ &path)
	{
		m_modules_path = path;
		ss_ first_module_path = path+"/__loader";
		load_module("__loader", first_module_path);
		// Allow loader load other modules
		emit_event(Event("core:load_modules"));
		handle_events();
		// Now that everyone is listening, we can fire the start event
		emit_event(Event("core:start"));
		handle_events();
	}

	ss_ get_modules_path()
	{
		return m_modules_path;
	}

	ss_ get_builtin_modules_path()
	{
		return g_server_config.share_path+"/builtin";
	}

	/*interface::Module* get_module_u(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return NULL;
		return it->second;
	}

	interface::Module* check_module_u(const ss_ &module_name)
	{
		interface::Module *m = get_module(module_name);
		if(m) return m;
		throw ModuleNotFoundException(ss_()+"Module not found: "+module_name);
	}*/

	bool has_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		return (it != m_modules.end());
	}

	void sub_event(struct interface::Module *module,
	               const Event::Type &type)
	{
		// Lock modules so that the subscribing one isn't removed asynchronously
		interface::MutexScope ms(m_modules_mutex);
		// Make sure module is a known instance
		ModuleWithMutex *mwm0 = NULL;
		ss_ module_name = "(unknown)";
		for(auto &pair : m_modules){
			ModuleWithMutex &mwm = pair.second;
			if(mwm.module == module){
				mwm0 = &mwm;
				module_name = pair.first;
				break;
			}
		}
		if(mwm0 == nullptr){
			std::cerr<<"sub_event(): Not a known module"<<std::endl;
			return;
		}
		interface::MutexScope ms2(m_event_subs_mutex);
		if(m_event_subs.size() <= type + 1)
			m_event_subs.resize(type + 1);
		sv_<ModuleWithMutex*> &sublist = m_event_subs[type];
		if(std::find(sublist.begin(), sublist.end(), mwm0) != sublist.end()){
			std::cerr<<"sub_event(): Already on list: "<<module_name<<std::endl;
			return;
		}
		std::cerr<<"sub_event(): "<<module_name<<" subscribed to "<<type <<
		          std::endl;
		sublist.push_back(mwm0);
	}

	void emit_event(const Event &event)
	{
		log_d("state", "emit_event(): type=%zu", event.type);
		interface::MutexScope ms(m_event_queue_mutex);
		m_event_queue.push_back(event);
	}

	void handle_events()
	{
		for(size_t loop_i = 0;; loop_i++){
			sv_<Event> event_queue_snapshot;
			sv_<sv_<ModuleWithMutex*>> event_subs_snapshot;
			{
				interface::MutexScope ms2(m_event_queue_mutex);
				interface::MutexScope ms3(m_event_subs_mutex);
				// Swap to clear queue
				m_event_queue.swap(event_queue_snapshot);
				// Copy to leave subscriptions active
				event_subs_snapshot = m_event_subs;
			}
			if(event_queue_snapshot.empty()){
				if(loop_i == 0)
					log_d("state", "handle_events(); Nothing to do");
				break;
			}
			for(const Event &event : event_queue_snapshot){
				if(event.type >= event_subs_snapshot.size()){
					log_d("state", "handle_events(): %zu: No subs", event.type);
					continue;
				}
				sv_<ModuleWithMutex*> &sublist = event_subs_snapshot[event.type];
				if(sublist.empty()){
					log_d("state", "handle_events(): %zu: No subs", event.type);
					continue;
				}
				log_d("state", "handle_events(): %zu: Handling (%zu handlers)",
				      event.type, sublist.size());
				for(ModuleWithMutex *mwm : sublist){
					interface::MutexScope mwm_ms(mwm->mutex);
					mwm->module->event(event.type, event.p.get());
				}
			}
		}
	}

	void add_socket_event(int fd, const Event::Type &event_type)
	{
		log_d("state", "add_socket_event(): fd=%i", fd);
		interface::MutexScope ms(m_sockets_mutex);
		auto it = m_sockets.find(fd);
		if(it == m_sockets.end()){
			SocketState s;
			s.fd = fd;
			s.event_type = event_type;
			m_sockets[fd] = s;
			return;
		}
		const SocketState &s = it->second;
		if(s.event_type != event_type){
			throw Exception("Socket events already requested with different"
			                " event type");
		}
		// Nothing to do; already set.
	}

	void remove_socket_event(int fd)
	{
		interface::MutexScope ms(m_sockets_mutex);
		// TODO
	}

	sv_<int> get_sockets()
	{
		interface::MutexScope ms(m_sockets_mutex);
		sv_<int> result;
		for(auto &pair : m_sockets)
			result.push_back(pair.second.fd);
		return result;
	}

	void emit_socket_event(int fd)
	{
		interface::MutexScope ms(m_sockets_mutex);
		auto it = m_sockets.find(fd);
		if(it == m_sockets.end()){
			// This can be valid if the socket has been removed while waiting
			// for it elsewhere
			log_w("state", "emit_socket_event(): fd=%i not found", fd);
			return;
		}
		SocketState &s = it->second;
		// Create and emit event
		interface::Event event(s.event_type);
		event.p.reset(new interface::SocketEvent(fd));
		emit_event(event);
	}
};

State* createState()
{
	return new CState();
}
}
