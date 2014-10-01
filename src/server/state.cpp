// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/file_watch.h"
//#include "interface/thread.h"
#include "interface/mutex.h"
#include <c55/string_util.h>
#include <c55/filesys.h>
#include <iostream>
#include <algorithm>
#include <fstream>
#define MODULE "__state"

using interface::Event;

extern server::Config g_server_config;
extern bool g_sigint_received;

namespace server {

static sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs)
{
	ss_ base_dir = c55fs::stripFilename(path);
	std::ifstream ifs(path);
	sv_<ss_> result;
	ss_ line;
	while(std::getline(ifs, line)){
		c55::Strfnd f(line);
		f.next("#");
		if(f.atend())
			continue;
		f.next("include");
		f.while_any(" ");
		ss_ quote = f.while_any("<\"");
		ss_ include = f.next(quote == "<" ? ">" : "\"");
		bool found = false;
		sv_<ss_> include_dirs_now = include_dirs;
		if(quote == "\"")
			include_dirs_now.insert(include_dirs_now.begin(), base_dir);
		else
			include_dirs_now.push_back(base_dir);
		for(const ss_ &dir : include_dirs){
			ss_ include_path = dir+"/"+include;
			//log_v(MODULE, "Trying %s", cs(include_path));
			std::ifstream ifs2(include_path);
			if(ifs2.good()){
				result.push_back(include_path);
				found = true;
				break;
			}
		}
		if(!found){
			// Not a huge problem, just log at debug
			log_d(MODULE, "Include file not found for watching: %s", cs(include));
		}
	}
	return result;
}

struct CState: public State, public interface::Server
{
	struct ModuleContainer {
		interface::Mutex mutex;
		interface::Module *module;
		interface::ModuleInfo info;

		ModuleContainer(interface::Module *module = NULL,
				const interface::ModuleInfo &info = interface::ModuleInfo()):
			module(module), info(info){}
	};

	struct SocketState {
		int fd = 0;
		Event::Type event_type;
	};

	bool m_shutdown_requested = false;
	int  m_shutdown_exit_status = 0;
	ss_ m_shutdown_reason;

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

	sm_<ss_, ss_> m_tmp_data;
	interface::Mutex m_tmp_data_mutex;

	CState():
		m_compiler(rccpp::createCompiler(g_server_config.compiler_command))
	{
		m_compiler->include_directories.push_back(
				g_server_config.interface_path);
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/..");
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/../../3rdparty/cereal/include");
		m_compiler->include_directories.push_back(
				g_server_config.share_path+"/builtin");
		sv_<ss_> urho3d_subdirs = {
			"Audio", "Container", "Core", "Engine", "Graphics", "Input", "IO",
			"LuaScript", "Math", "Navigation", "Network", "Physics", "Resource",
			"Scene", "Script", "UI", "Urho2D",
		};
		for(const ss_ &subdir : urho3d_subdirs){
			m_compiler->include_directories.push_back(
					g_server_config.urho3d_path+"/Source/Engine/"+subdir);
		}
		m_compiler->include_directories.push_back(
				g_server_config.urho3d_path+"/Build/Engine"); // Urho3D.h
		m_compiler->libraries.push_back(
				g_server_config.urho3d_path+"/Lib/libUrho3D.a");
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

	void shutdown(int exit_status, const ss_ &reason)
	{
		if(m_shutdown_requested && exit_status == 0){
			// Only reset these values for exit values indicating failure
			return;
		}
		log_i(MODULE, "Server shutdown requested; exit_status=%i, reason=\"%s\"",
				exit_status, cs(reason));
		m_shutdown_requested = true;
		m_shutdown_exit_status = exit_status;
		m_shutdown_reason = reason;
	}

	bool is_shutdown_requested(int *exit_status = nullptr, ss_ *reason = nullptr)
	{
		if(m_shutdown_requested){
			if(exit_status)
				*exit_status = m_shutdown_exit_status;
			if(reason)
				*reason = m_shutdown_reason;
		}
		return m_shutdown_requested;
	}

	bool load_module(const interface::ModuleInfo &info)
	{
		interface::MutexScope ms(m_modules_mutex);

		log_i(MODULE, "Loading module %s from %s", cs(info.name), cs(info.path));

		ss_ build_dst = g_server_config.rccpp_build_path +
				"/"+info.name+".so";
		ss_ init_cpp_path = info.path+"/"+info.name+".cpp";

		// Set up file watch

		sv_<ss_> files_to_watch = {init_cpp_path};
		sv_<ss_> include_dirs = m_compiler->include_directories;
		include_dirs.push_back(m_modules_path);
		sv_<ss_> includes = list_includes(init_cpp_path, include_dirs);
		log_d(MODULE, "Includes: %s", cs(dump(includes)));
		files_to_watch.insert(files_to_watch.end(), includes.begin(), includes.end());

		if(m_module_file_watches.count(info.name) == 0){
			m_module_file_watches[info.name] = sp_<interface::FileWatch>(
					interface::createFileWatch(files_to_watch,
					[this, info]()
			{
				log_i(MODULE, "Module modified: %s: %s",
						cs(info.name), cs(info.path));
				emit_event(Event("core:module_modified",
						new interface::ModuleModifiedEvent(info.name, info.path)));
				handle_events();
			}));
		}

		// Build

		ss_ extra_cxxflags = info.meta.cxxflags;
		ss_ extra_ldflags = info.meta.ldflags;
		log_d(MODULE, "extra_cxxflags: %s", cs(extra_cxxflags));
		log_d(MODULE, "extra_ldflags: %s", cs(extra_ldflags));

		m_compiler->include_directories.push_back(m_modules_path);
		bool build_ok = m_compiler->build(info.name, init_cpp_path, build_dst,
				extra_cxxflags, extra_ldflags);
		m_compiler->include_directories.pop_back();

		if(!build_ok){
			log_w(MODULE, "Failed to build module %s", cs(info.name));
			return false;
		}

		// Construct instance

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(info.name.c_str(), this));
		if(m == nullptr){
			log_w(MODULE, "Failed to construct module %s instance",
					cs(info.name));
			return false;
		}
		m_modules[info.name] = ModuleContainer(m, info);

		// Call init()

		{
			ModuleContainer &mc = m_modules[info.name];
			interface::MutexScope ms2(mc.mutex);
			mc.module->init();
		}

		emit_event(Event("core:module_loaded",
				new interface::ModuleLoadedEvent(info.name)));
		return true;
	}

	void load_modules(const ss_ &path)
	{
		m_modules_path = path;

		interface::ModuleInfo info;
		info.name = "__loader";
		info.path = path+"/"+info.name;

		if(!load_module(info)){
			shutdown(1, "Failed to load __loader module");
			return;
		}

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
		log_v(MODULE, "unload_module(%s)", cs(module_name));
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end()){
			log_w(MODULE, "unload_module(%s): Not loaded", cs(module_name));
			return;
		}
		m_unloads_requested.insert(module_name);
	}

	void reload_module(const interface::ModuleInfo &info)
	{
		log_i(MODULE, "reload_module(%s)", cs(info.name));
		{
			interface::MutexScope ms(m_modules_mutex);
			unload_module_u(info.name);
		}
		load_module(info);
		// Send core::continue directly to module
		{
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_modules.find(info.name);
			if(it == m_modules.end()){
				log_w(MODULE, "reload_module: Module not found: %s",
						cs(info.name));
				return;
			}
			ModuleContainer *mc = &it->second;
			interface::MutexScope mc_ms(mc->mutex);
			mc->module->event(Event::t("core:continue"), nullptr);
		}
	}

	void reload_module(const ss_ &module_name)
	{
		interface::ModuleInfo info;
		{
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_modules.find(module_name);
			if(it == m_modules.end()){
				log_w(MODULE, "reload_module: Module not found: %s",
						cs(module_name));
				return;
			}
			ModuleContainer *mc = &it->second;
			info = mc->info;
		}
		reload_module(info);
	}

	// Direct version; internal and unsafe
	// Call with m_modules_mutex locked.
	void unload_module_u(const ss_ &module_name)
	{
		log_i(MODULE, "unload_module_u(): module_name=%s", cs(module_name));
		// Get and lock module
		auto it = m_modules.find(module_name);
		if(it == m_modules.end()){
			log_w(MODULE, "unload_module_u: Module not found: %s", cs(module_name));
			return;
		}
		ModuleContainer *mc = &it->second;
		interface::MutexScope mc_ms(mc->mutex);
		// Send core::unload directly to module
		mc->module->event(Event::t("core:unload"), nullptr);
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

		emit_event(Event("core:module_unloaded",
				new interface::ModuleUnloadedEvent(module_name)));
	}

	ss_ get_modules_path()
	{
		return m_modules_path;
	}

	ss_ get_builtin_modules_path()
	{
		return g_server_config.share_path+"/builtin";
	}

	ss_ get_module_path(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			throw ModuleNotFoundException(ss_()+"Module not found: "+module_name);
		ModuleContainer *mc = &it->second;
		return mc->info.path;
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

	sv_<ss_> get_loaded_modules()
	{
		interface::MutexScope ms(m_modules_mutex);
		sv_<ss_> result;
		for(auto &pair : m_modules){
			result.push_back(pair.first);
		}
		return result;
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
		auto *evreg = interface::getGlobalEventRegistry();
		log_d(MODULE, "sub_event(): %s subscribed to %s (%zu)",
				cs(module_name), cs(evreg->name(type)), type);
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
			if(g_sigint_received){
				// Get out fast
				throw ServerShutdownRequest("Server shutdown requested via SIGINT");
			}
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
			for(auto it = m_unloads_requested.begin();
					it != m_unloads_requested.end();){
				ss_ module_name = *it; // Copy
				it++; // Increment before unload_module_u; it erases this
				log_i("state", "Unloading %s as requested", cs(module_name));
				unload_module_u(module_name);
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

	void tmp_store_data(const ss_ &name, const ss_ &data)
	{
		interface::MutexScope ms(m_tmp_data_mutex);
		m_tmp_data[name] = data;
	}

	ss_ tmp_restore_data(const ss_ &name)
	{
		interface::MutexScope ms(m_tmp_data_mutex);
		ss_ data = m_tmp_data[name];
		m_tmp_data.erase(name);
		return data;
	}
};

State* createState()
{
	return new CState();
}
}
// vim: set noet ts=4 sw=4:
