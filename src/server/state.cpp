#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/file_watch.h"
//#include "interface/thread.h"
#include "interface/mutex.h"
#include <iostream>
#include <algorithm>
#define MODULE "__state"

using interface::Event;

extern server::Config g_server_config;

namespace server {

struct CState: public State, public interface::Server
{
	struct ModuleContainer {
		interface::Mutex mutex;
		interface::Module *module;

		ModuleContainer(interface::Module *module = NULL): module(module){}
	};

	struct SocketState {
		int fd = 0;
		Event::Type event_type;
	};

	up_<rccpp::Compiler> m_compiler;
	ss_ m_modules_path;

	sm_<ss_, ModuleContainer> m_modules;
	set_<ss_> m_unloads_requested;
	sm_<ss_, sp_<interface::FileWatch>> m_module_file_watches;
	interface::Mutex m_modules_mutex;

	sv_<Event> m_event_queue;
	interface::Mutex m_event_queue_mutex;

	sv_<sv_<ModuleContainer*>> m_event_subs;
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
			ModuleContainer &mc = pair.second;
			// Don't lock; it would only cause deadlocks
			delete mc.module;
		}
	}

	void load_module(const ss_ &module_name, const ss_ &path)
	{
		interface::MutexScope ms(m_modules_mutex);

		log_i(MODULE, "Loading module %s from %s", cs(module_name), cs(path));

		ss_ build_dst = g_server_config.rccpp_build_path +
				"/"+module_name+".so";
		ss_ init_cpp_path = path+"/"+module_name+".cpp";

		// Set up file watch

		if(m_module_file_watches.count(module_name) == 0){
			m_module_file_watches[module_name] = sp_<interface::FileWatch>(
					interface::createFileWatch({init_cpp_path},
					[this, module_name, path]()
			{
				log_i(MODULE, "Module modified: %s: %s",
						cs(module_name), cs(path));
				emit_event(Event("core:module_modified",
						new interface::ModuleModifiedEvent(module_name, path)));
				handle_events();
			}));
		}

		// Build

		m_compiler->include_directories.push_back(m_modules_path);
		bool build_ok = m_compiler->build(module_name, init_cpp_path, build_dst);
		m_compiler->include_directories.pop_back();

		if(!build_ok){
			log_w(MODULE, "Failed to build module %s", cs(module_name));
			return;
		}

		// Construct instance

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(module_name.c_str(), this));
		if(m == nullptr){
			log_w(MODULE, "Failed to construct module %s instance",
					cs(module_name));
			return;
		}
		m_modules[module_name] = ModuleContainer(m);

		// Call init()

		{
			ModuleContainer &mc = m_modules[module_name];
			interface::MutexScope ms2(mc.mutex);
			mc.module->init();
		}
	}

	void load_modules(const ss_ &path)
	{
		m_modules_path = path;
		ss_ first_module_path = path+"/__loader";
		load_module("__loader", first_module_path);
		// Allow loader to load other modules
		emit_event(Event("core:load_modules"));
		handle_events();
		// Now that everyone is listening, we can fire the start event
		emit_event(Event("core:start"));
		handle_events();
	}

	// interface::Server version; doesn't directly unload
	void unload_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return;
		m_unloads_requested.insert(module_name);
	}

	void reload_module(const ss_ &module_name, const ss_ &path)
	{
		log_i(MODULE, "reload_module(%s)", cs(module_name));
		unload_module_u(module_name);
		load_module(module_name, path);
		// Send core::continue directly to module
		{
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_modules.find(module_name);
			if(it == m_modules.end()){
				log_w(MODULE, "reload_module: Module not found: %s",
						cs(module_name));
				return;
			}
			ModuleContainer *mc = &it->second;
			interface::MutexScope mc_ms(mc->mutex);
			mc->module->event(Event::t("core:continue"), nullptr);
		}
	}

	// Direct version; internal and unsafe
	void unload_module_u(const ss_ &module_name)
	{
		log_i(MODULE, "unload_module_u(): module_name=%s", cs(module_name));
		interface::MutexScope ms(m_modules_mutex);
		// Get and lock module
		auto it = m_modules.find(module_name);
		if(it == m_modules.end()){
			log_w(MODULE, "unload_module_u: Module not found: %s", cs(module_name));
			return;
		}
		ModuleContainer *mc = &it->second;
		interface::MutexScope mc_ms(mc->mutex);
		// Clear unload request
		m_unloads_requested.erase(module_name);
		// Delete subscriptions
		{
			interface::MutexScope ms(m_event_subs_mutex);
			for(Event::Type type = 0; type < m_event_subs.size(); type++){
				sv_<ModuleContainer*> &sublist = m_event_subs[type];
				sv_<ModuleContainer*> new_sublist;
				for(ModuleContainer *mc1 : sublist){
					if(mc1 != mc)
						new_sublist.push_back(mc1);
					else
						log_v(MODULE, "Removing %s subscription to event %zu",
								cs(module_name), type);
				}
				sublist = new_sublist;
			}
		}
		// Delete module
		delete mc->module;
		m_modules.erase(module_name);
		m_compiler->unload(module_name);
	}

	ss_ get_modules_path()
	{
		return m_modules_path;
	}

	ss_ get_builtin_modules_path()
	{
		return g_server_config.share_path+"/builtin";
	}

	interface::Module* get_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return NULL;
		return it->second.module;
	}

	interface::Module* check_module(const ss_ &module_name)
	{
		interface::Module *m = get_module(module_name);
		if(m) return m;
		throw ModuleNotFoundException(ss_()+"Module not found: "+module_name);
	}

	bool has_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		return (it != m_modules.end());
	}

	bool access_module(const ss_ &module_name,
			std::function<void(interface::Module*)> cb)
	{
		// This prevents module from being deleted while it is being called
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return false;
		ModuleContainer *mc = &it->second;
		interface::MutexScope mc_ms(mc->mutex);
		cb(mc->module);
		return true;
	}

	void sub_event(struct interface::Module *module,
			const Event::Type &type)
	{
		// Lock modules so that the subscribing one isn't removed asynchronously
		interface::MutexScope ms(m_modules_mutex);
		// Make sure module is a known instance
		ModuleContainer *mc0 = NULL;
		ss_ module_name = "(unknown)";
		for(auto &pair : m_modules){
			ModuleContainer &mc = pair.second;
			if(mc.module == module){
				mc0 = &mc;
				module_name = pair.first;
				break;
			}
		}
		if(mc0 == nullptr){
			log_w(MODULE, "sub_event(): Not a known module");
			return;
		}
		interface::MutexScope ms2(m_event_subs_mutex);
		if(m_event_subs.size() <= type + 1)
			m_event_subs.resize(type + 1);
		sv_<ModuleContainer*> &sublist = m_event_subs[type];
		if(std::find(sublist.begin(), sublist.end(), mc0) != sublist.end()){
			log_w(MODULE, "sub_event(): Already on list: %s", cs(module_name));
			return;
		}
		log_v(MODULE, "sub_event(): %s subscribed to %zu", cs(module_name), type);
		sublist.push_back(mc0);
	}

	void emit_event(Event event)
	{
		log_d("state", "emit_event(): type=%zu", event.type);
		interface::MutexScope ms(m_event_queue_mutex);
		m_event_queue.push_back(std::move(event));
	}

	void handle_events()
	{
		// Note: Locking m_modules_mutex here is not needed because no modules
		// can be deleted while this is running, because modules are deleted
		// only by this same thread.
		for(size_t loop_i = 0;; loop_i++){
			sv_<Event> event_queue_snapshot;
			sv_<sv_<ModuleContainer*>> event_subs_snapshot;
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
				sv_<ModuleContainer*> &sublist = event_subs_snapshot[event.type];
				if(sublist.empty()){
					log_d("state", "handle_events(): %zu: No subs", event.type);
					continue;
				}
				log_d("state", "handle_events(): %zu: Handling (%zu handlers)",
						event.type, sublist.size());
				for(ModuleContainer *mc : sublist){
					interface::MutexScope mc_ms(mc->mutex);
					mc->module->event(event.type, event.p.get());
				}
			}
			interface::MutexScope ms(m_modules_mutex);
			for(const ss_ &module_name : m_unloads_requested){
				log_w("state", "Unloading %s: not implemented", cs(module_name));
				// TODO: Unload
			}
			m_unloads_requested.clear();
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
		m_sockets.erase(fd);
	}

	sv_<int> get_sockets()
	{
		sv_<int> result;
		{
			interface::MutexScope ms(m_sockets_mutex);
			for(auto &pair : m_sockets)
				result.push_back(pair.second.fd);
		}
		{
			interface::MutexScope ms(m_modules_mutex);
			for(auto &pair : m_module_file_watches){
				auto fds = pair.second->get_fds();
				result.insert(result.end(), fds.begin(), fds.end());
			}
		}
		return result;
	}

	void emit_socket_event(int fd)
	{
		log_d(MODULE, "emit_socket_event(): fd=%i", fd);
		// Break if not found; return if found and handled.
		do {
			interface::MutexScope ms(m_modules_mutex);
			for(auto &pair : m_module_file_watches){
				sv_<int> fds = pair.second->get_fds();
				if(std::find(fds.begin(), fds.end(), fd) != fds.end()){
					pair.second->report_fd(fd);
					return;
				}
			}
		} while(0);
		do {
			interface::MutexScope ms(m_sockets_mutex);
			auto it = m_sockets.find(fd);
			if(it == m_sockets.end())
				break;
			SocketState &s = it->second;
			// Create and emit event
			interface::Event event(s.event_type);
			event.p.reset(new interface::SocketEvent(fd));
			emit_event(std::move(event));
			return;
		} while(0);
	}
};

State* createState()
{
	return new CState();
}
}
