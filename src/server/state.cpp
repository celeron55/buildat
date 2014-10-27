// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "state.h"
#include "core/log.h"
#include "rccpp.h"
#include "rccpp_util.h"
#include "config.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/file_watch.h"
#include "interface/fs.h"
#include "interface/sha1.h"
#include "interface/mutex.h"
#include "interface/thread_pool.h"
#include "interface/thread.h"
#include "interface/semaphore.h"
#include <iostream>
#include <algorithm>
#include <fstream>
#include <deque>
#define MODULE "__state"

#ifdef _WIN32
	#define MODULE_EXTENSION "dll"
#else
	#define MODULE_EXTENSION "so"
#endif

extern server::Config g_server_config;
extern bool g_sigint_received;

namespace server {

using interface::Event;

struct ModuleContainer;

struct ModuleThread: public interface::ThreadedThing
{
	ModuleContainer *mc = nullptr;

	ModuleThread(ModuleContainer *mc):
		mc(mc)
	{}

	void run(interface::Thread *thread);
};

struct ModuleContainer
{
	interface::ThreadLocalKey *thread_local_key; // Stores mc*
	up_<interface::Module> module;
	interface::ModuleInfo info;
	interface::Mutex mutex; // Protects each of the former variables
	up_<interface::Thread> thread;

	// Allows directly executing code in the module thread
	const std::function<void(interface::Module*)> *direct_cb = nullptr;
	// The actual event queue
	std::deque<Event> event_queue; // Push back, pop front
	// Protects direct_cb and event_queue
	interface::Mutex event_queue_mutex;
	// Counts queued events, and +1 for direct_cb
	interface::Semaphore event_queue_sem;
	// post() when direct_cb has been executed, wait() for that to happen
	interface::Semaphore direct_cb_executed_sem;
	// post() when direct_cb becomes free, wait() for that to happen
	interface::Semaphore direct_cb_free_sem;

	ModuleContainer(interface::ThreadLocalKey *thread_local_key = NULL,
			interface::Module *module = NULL,
			const interface::ModuleInfo &info = interface::ModuleInfo()):
		thread_local_key(thread_local_key),
		module(module),
		info(info)
	{
		direct_cb_free_sem.post();
	}
	~ModuleContainer(){
		log_t(MODULE, "ModuleContainer[%s]: Destructing", cs(info.name));
		stop_and_delete_module();
	}
	void init_and_start_thread(){
		{
			interface::MutexScope ms(mutex);
			if(!module)
				throw Exception("init_and_start_thread(): module is null");
			if(info.name != module->m_module_name)
				throw Exception("init_and_start_thread(): Module name does not"
						" match: info.name=\""+info.name+"\","
						" module->m_module_name=\""+module->m_module_name+"\"");
			thread.reset(interface::createThread(new ModuleThread(this)));
			thread->set_name(info.name);
			thread->start();
		}
		// Initialize in thread
		execute_direct_cb([&](interface::Module *module){
			module->init();
		});
	}
	void stop_and_delete_module(){
		if(thread){
			log_t(MODULE, "ModuleContainer[%s]: Asking thread to exit",
					cs(info.name));
			thread->request_stop();
			// Clear direct callback
			{
				interface::MutexScope ms(event_queue_mutex);
				direct_cb = nullptr;
			}
			// Pretend that the current direct callback was executed
			direct_cb_executed_sem.post();
			// Wake up thread so it can exit
			event_queue_sem.post();
			log_t(MODULE, "ModuleContainer[%s]: Asked thread to exit; waiting",
					cs(info.name));
			thread->join();
			thread.reset();
			log_t(MODULE, "ModuleContainer[%s]: Thread exited", cs(info.name));
		} else {
			log_t(MODULE, "ModuleContainer[%s]: No thread", cs(info.name));
		}
		// Module should have been deleted by the thread. In case the thread
		// failed, delete it here.
		module.reset();
	}
	void push_event(const Event &event){
		interface::MutexScope ms(event_queue_mutex);
		event_queue.push_back(event);
		event_queue_sem.post();
	}
	void emit_event_sync(const Event &event){
		interface::MutexScope ms(mutex);
		module->event(event.type, event.p.get());
	}
	void execute_direct_cb(const std::function<void(interface::Module*)> &cb){
		log_t(MODULE, "execute_direct_cb[%s]: Waiting for direct_cb to be free",
				cs(info.name));
		direct_cb_free_sem.wait(); // Wait for direct_cb to be free
		log_t(MODULE, "execute_direct_cb[%s]: Direct_cb is now free. "
				"Waiting for event queue lock", cs(info.name));
		{
			interface::MutexScope ms(event_queue_mutex);
			log_t(MODULE, "execute_direct_cb[%s]: Posting direct_cb",
					cs(info.name));
			direct_cb = &cb;
			event_queue_sem.post();
		}
		log_t(MODULE, "execute_direct_cb[%s]: Waiting for execution to finish",
				cs(info.name));
		direct_cb_executed_sem.wait(); // Wait for execution to finish
		direct_cb_free_sem.post(); // Set direct_cb to be free now
		log_t(MODULE, "execute_direct_cb[%s]: Execution finished",
				cs(info.name));
	}
};

void ModuleThread::run(interface::Thread *thread)
{
	mc->thread_local_key->set((void*)mc);

	for(;;){
		// Wait for an event
		mc->event_queue_sem.wait();
		// Check if should stop
		if(thread->stop_requested())
			break;
		// Grab the direct callback or an event from the queue
		const std::function<void(interface::Module*)> *direct_cb = nullptr;
		Event event;
		{
			interface::MutexScope ms(mc->event_queue_mutex);
			if(mc->direct_cb){
				direct_cb = mc->direct_cb;
			} else if(!mc->event_queue.empty()){
				event = mc->event_queue.front();
				mc->event_queue.pop_front();
			} else {
				continue;
			}
		}
		if(direct_cb){
			// Handle the direct callback
			interface::MutexScope ms(mc->mutex);
			if(!mc->module){
				log_w(MODULE, "ModuleContainer[%s]: Module is null; cannot"
						" call direct callback", cs(mc->info.name));
			} else {
				try {
					log_t(MODULE, "run[%s]: Direct_cb: Executing",
							cs(mc->info.name));
					(*direct_cb)(mc->module.get());
					log_t(MODULE, "run[%s]: Direct_cb: Executed",
							cs(mc->info.name));
				} catch(std::exception &e){
					log_w(MODULE, "direct_cb() failed: %s", e.what());
				}
			}
			{
				interface::MutexScope ms(mc->event_queue_mutex);
				mc->direct_cb = nullptr;
			}
			mc->direct_cb_executed_sem.post();
		} else {
			// Handle the event
			interface::MutexScope ms(mc->mutex);
			if(!mc->module){
				log_w(MODULE, "ModuleContainer[%s]: Module is null; cannot"
						" handle event", cs(mc->info.name));
				continue;
			}
			try {
				mc->module->event(event.type, event.p.get());
			} catch(std::exception &e){
				log_w(MODULE, "module->event() failed: %s", e.what());
			}
		}
	}
	// Delete module in this thread. This is important in case the destruction
	// of some objects in the module is required to be done in the same thread
	// as they were created in.
	// It is also important to delete the module outside of mc->mutex, as doing
	// it in the locked state will only cause deadlocks.
	up_<interface::Module> module_moved;
	{
		interface::MutexScope ms(mc->mutex);
		module_moved = std::move(mc->module);
	}
	module_moved.reset();
}

struct CState: public State, public interface::Server
{
	struct SocketState {
		int fd = 0;
		Event::Type event_type;
	};

	bool m_shutdown_requested = false;
	int m_shutdown_exit_status = 0;
	ss_ m_shutdown_reason;

	up_<rccpp::Compiler> m_compiler;
	ss_ m_modules_path;

	// Thread-local pointer to ModuleContainer of the module of each module
	// thread
	interface::ThreadLocalKey m_thread_local_mc_key;

	sm_<ss_, interface::ModuleInfo> m_module_info; // Info of every seen module
	sm_<ss_, sp_<ModuleContainer>> m_modules; // Currently loaded modules
	set_<ss_> m_unloads_requested;
	sv_<interface::ModuleInfo> m_reloads_requested;
	sm_<ss_, sp_<interface::FileWatch>> m_module_file_watches;
	// Module modifications are accumulated here and core:module_modified events
	// are fired every event loop based on this to lump multiple modifications
	// into one (generally a modification causes many notifications)
	set_<ss_> m_modified_modules; // Module names
	// TODO: Handle properly in reloads (unload by popping from top, then reload
	//       everything until top)
	sv_<ss_> m_module_load_order;
	sv_<sv_<wp_<ModuleContainer>>> m_event_subs;
	// NOTE: You can make a copy of an sp_<ModuleContainer> and unlock this
	//       mutex for processing the module asynchronously (just lock mc->mutex)
	interface::Mutex m_modules_mutex;

	sm_<ss_, ss_> m_tmp_data;
	interface::Mutex m_tmp_data_mutex;

	sm_<ss_, ss_> m_file_paths;
	interface::Mutex m_file_paths_mutex;

	sp_<interface::thread_pool::ThreadPool> m_thread_pool;
	interface::Mutex m_thread_pool_mutex;

	CState():
		m_compiler(rccpp::createCompiler(g_server_config.compiler_command)),
		m_thread_pool(interface::thread_pool::createThreadPool())
	{
		m_thread_pool->start(4); // TODO: Configurable

		// Set basic RCC++ include directories

		// We don't want to directly add the interface path as it contains
		// stuff like mutex.h which match on Windows to Urho3D's Mutex.h
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/..");
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/../../3rdparty/cereal/include");
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+
				"/../../3rdparty/polyvox/library/PolyVoxCore/include");
		m_compiler->include_directories.push_back(
				g_server_config.share_path+"/builtin");

		// Setup Urho3D in RCC++

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
		m_compiler->library_directories.push_back(
				g_server_config.urho3d_path+"/Lib");
		m_compiler->libraries.push_back("-lUrho3D");
		m_compiler->include_directories.push_back(
				g_server_config.urho3d_path+"/Source/ThirdParty/Bullet/src");
	}
	~CState()
	{
		// Unload modules in reverse load order to make things work more
		// predictably
		sv_<sp_<ModuleContainer>> mcs;
		{
			// Don't have this locked when handling modules because it causes
			// deadlocks
			interface::MutexScope ms(m_modules_mutex);
			for(auto name_it = m_module_load_order.rbegin();
					name_it != m_module_load_order.rend(); ++name_it){
				auto it2 = m_modules.find(*name_it);
				if(it2 == m_modules.end())
					continue;
				sp_<ModuleContainer> &mc = it2->second;
				mcs.push_back(mc);
			}
		}
		for(sp_<ModuleContainer> &mc : mcs){
			log_v(MODULE, "Destructing module %s", cs(mc->info.name));
			mc->stop_and_delete_module();
			// Remove our reference to the module container, so that any child
			// threads it will now delete will not get deadlocked in trying to
			// access the module
			// (This is a shared pointer)
			mc.reset();
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

	interface::Module* build_module_u(const interface::ModuleInfo &info)
	{
		ss_ init_cpp_path = info.path+"/"+info.name+".cpp";

		// Set up file watch

		sv_<ss_> files_to_watch = {init_cpp_path};
		sv_<ss_> include_dirs = m_compiler->include_directories;
		include_dirs.push_back(m_modules_path);
		sv_<ss_> includes = list_includes(init_cpp_path, include_dirs);
		log_d(MODULE, "Includes: %s", cs(dump(includes)));
		files_to_watch.insert(files_to_watch.end(), includes.begin(),
				includes.end());

		if(m_module_file_watches.count(info.name) == 0){
			sp_<interface::FileWatch> w(interface::createFileWatch());
			for(const ss_ &watch_path : files_to_watch){
				ss_ dir_path = interface::Filesystem::strip_file_name(watch_path);
				w->add(dir_path, [this, info, watch_path](const ss_ &modified_path){
					if(modified_path != watch_path)
						return;
					log_i(MODULE, "Module modified: %s: %s",
							cs(info.name), cs(info.path));
					m_modified_modules.insert(info.name);
				});
			}
			m_module_file_watches[info.name] = w;
		}

		// Build

		ss_ extra_cxxflags = info.meta.cxxflags;
		ss_ extra_ldflags = info.meta.ldflags;
#ifdef _WIN32
		extra_cxxflags += " "+info.meta.cxxflags_windows;
		extra_ldflags += " "+info.meta.ldflags_windows;
		// Needed for every module
		extra_ldflags += " -lbuildat_core";
		// Always include these to make life easier
		extra_ldflags += " -lwsock32 -lws2_32";
#else
		extra_cxxflags += " "+info.meta.cxxflags_linux;
		extra_ldflags += " "+info.meta.ldflags_linux;
#endif
		log_d(MODULE, "extra_cxxflags: %s", cs(extra_cxxflags));
		log_d(MODULE, "extra_ldflags: %s", cs(extra_ldflags));

		bool skip_compile = g_server_config.skip_compiling_modules.count(info.name);

		sv_<ss_> files_to_hash = {init_cpp_path};
		files_to_hash.insert(
				files_to_hash.begin(), includes.begin(), includes.end());
		ss_ content_hash = hash_files(files_to_hash);
		log_d(MODULE, "Module hash: %s", cs(interface::sha1::hex(content_hash)));

#ifdef _WIN32
		// On Windows, we need a new name for each modification of the module
		// because Windows caches DLLs by name
		ss_ build_dst = g_server_config.rccpp_build_path +
				"/"+info.name+"_"+interface::sha1::hex(content_hash)+"."+
				MODULE_EXTENSION;
		// TODO: Delete old ones
#else
		ss_ build_dst = g_server_config.rccpp_build_path +
				"/"+info.name+"."+MODULE_EXTENSION;
#endif

		ss_ hashfile_path = build_dst+".hash";

		if(!skip_compile){
			if(!std::ifstream(build_dst).good()){
				// Result file does not exist at all, no need to check hashes
			} else {
				ss_ previous_hash;
				{
					std::ifstream f(hashfile_path);
					if(f.good()){
						previous_hash = ss_((std::istreambuf_iterator<char>(f)),
									std::istreambuf_iterator<char>());
					}
				}
				if(previous_hash == content_hash){
					log_v(MODULE, "No need to recompile %s", cs(info.name));
					skip_compile = true;
				}
			}
		}

		m_compiler->include_directories.push_back(m_modules_path);
		bool build_ok = m_compiler->build(info.name, init_cpp_path, build_dst,
					extra_cxxflags, extra_ldflags, skip_compile);
		m_compiler->include_directories.pop_back();

		if(!build_ok){
			log_w(MODULE, "Failed to build module %s", cs(info.name));
			return nullptr;
		}

		// Update hash file
		if(!skip_compile){
			std::ofstream f(hashfile_path);
			f<<content_hash;
		}

		// Construct instance

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(info.name.c_str(), this));
		return m;
	}

	// Can be used for loading hardcoded modules.
	// There intentionally is no core:module_loaded event.
	void load_module_direct_u(interface::Module *m, const ss_ &name)
	{
		sp_<ModuleContainer> mc;
		{
			interface::MutexScope ms(m_modules_mutex);

			interface::ModuleInfo info;
			info.name = name;
			info.path = "";

			log_i(MODULE, "Loading module %s (hardcoded)", cs(info.name));

			m_module_info[info.name] = info;

			mc = sp_<ModuleContainer>(new ModuleContainer(
					&m_thread_local_mc_key, m, info));
			m_modules[info.name] = mc;
			m_module_load_order.push_back(info.name);
		}

		// Call init() and start thread
		mc->init_and_start_thread();
	}

	bool load_module(const interface::ModuleInfo &info)
	{
		sp_<ModuleContainer> mc;
		{
			interface::MutexScope ms(m_modules_mutex);

			if(m_modules.find(info.name) != m_modules.end()){
				log_w(MODULE, "Cannot load module %s from %s: Already loaded",
						cs(info.name), cs(info.path));
				return false;
			}

			log_i(MODULE, "Loading module %s from %s", cs(info.name), cs(info.path));

			m_module_info[info.name] = info;

			interface::Module *m = nullptr;
			if(!info.meta.disable_cpp){
				m = build_module_u(info);

				if(m == nullptr){
					log_w(MODULE, "Failed to construct module %s instance",
							cs(info.name));
					return false;
				}
			}
			mc = sp_<ModuleContainer>(new ModuleContainer(
					&m_thread_local_mc_key, m, info));
			m_modules[info.name] = mc;
			m_module_load_order.push_back(info.name);
		}

		// Call init() and start thread
		mc->init_and_start_thread();

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

		// Allow loader to load other modules.
		// Emit synchronously because threading doesn't matter at this point in
		// initialization and we have to wait for it to complete.
		emit_event(Event("core:load_modules"), true);

		if(is_shutdown_requested())
			return;

		// Now that everyone is listening, we can fire the start event
		emit_event(Event("core:start"));
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
		interface::MutexScope ms(m_modules_mutex);
		for(interface::ModuleInfo &info0 : m_reloads_requested){
			if(info0.name == info.name){
				info0 = info; // Update existing request
				return;
			}
		}
		m_reloads_requested.push_back(info);
	}

	void reload_module(const ss_ &module_name)
	{
		interface::ModuleInfo info;
		{
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_module_info.find(module_name);
			if(it == m_module_info.end()){
				log_w(MODULE, "reload_module: Module info not found: %s",
						cs(module_name));
				return;
			}
			info = it->second;
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
		sp_<ModuleContainer> mc = it->second;
		{
			interface::MutexScope mc_ms(mc->mutex);
			// Send core::unload directly to module
			mc->module->event(Event::t("core:unload"), nullptr);
			// Delete subscriptions
			{
				for(Event::Type type = 0; type < m_event_subs.size(); type++){
					sv_<wp_<ModuleContainer>> &sublist = m_event_subs[type];
					sv_<wp_<ModuleContainer>> new_sublist;
					for(wp_<ModuleContainer> &mc1 : sublist){
						if(sp_<ModuleContainer>(mc1.lock()).get() !=
								mc.get())
							new_sublist.push_back(mc1);
						else
							log_v(MODULE, "Removing %s subscription to event %zu",
									cs(module_name), type);
					}
					sublist = new_sublist;
				}
			}
		}
		{
			// Delete module and container
			m_modules.erase(module_name);
		}
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
		ModuleContainer *mc = it->second.get();
		return mc->info.path;
	}

	interface::Module* get_module(const ss_ &module_name)
	{
		interface::MutexScope ms(m_modules_mutex);
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return NULL;
		return it->second->module.get();
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
		sp_<ModuleContainer> mc;
		{
			// This prevents module from being deleted while a reference is
			// being copied
			interface::MutexScope ms(m_modules_mutex);
			auto it = m_modules.find(module_name);
			if(it == m_modules.end())
				return false;
			mc = it->second;

			// Get container of current module
			ModuleContainer *caller_mc =
					(ModuleContainer*)mc->thread_local_key->get();
			if(caller_mc){
				log_t(MODULE, "access_module(\"%s\"): Called by \"%s\"",
						cs(mc->info.name), cs(caller_mc->info.name));
			} else {
				log_t(MODULE, "access_module(\"%s\"): Called by something else"
						" than a module", cs(mc->info.name));
			}

			// TODO: Check that the module being accessed is a direct or
			//       indirect dependency of the module accessing it, and not the
			//       module itself
		}
		mc->execute_direct_cb(cb);
		return true;
	}

	void sub_event(struct interface::Module *module,
			const Event::Type &type)
	{
		// Lock modules so that the subscribing one isn't removed asynchronously
		interface::MutexScope ms(m_modules_mutex);
		// Make sure module is a known instance
		sp_<ModuleContainer> mc0;
		ss_ module_name = "(unknown)";
		for(auto &pair : m_modules){
			sp_<ModuleContainer> &mc = pair.second;
			if(mc->module.get() == module){
				mc0 = mc;
				module_name = pair.first;
				break;
			}
		}
		if(mc0 == nullptr){
			log_w(MODULE, "sub_event(): Not a known module");
			return;
		}
		if(m_event_subs.size() <= type + 1)
			m_event_subs.resize(type + 1);
		sv_<wp_<ModuleContainer>> &sublist = m_event_subs[type];
		bool found = false;
		for(wp_<ModuleContainer> &item : sublist){
			if(item.lock() == mc0){
				found = true;
				break;
			}
		}
		if(found){
			log_w(MODULE, "sub_event(): Already on list: %s", cs(module_name));
			return;
		}
		auto *evreg = interface::getGlobalEventRegistry();
		log_d(MODULE, "sub_event(): %s subscribed to %s (%zu)",
				cs(module_name), cs(evreg->name(type)), type);
		sublist.push_back(wp_<ModuleContainer>(mc0));
	}

	// Do not use synchronous=true unless specifically needed in a special case.
	void emit_event(Event event, bool synchronous)
	{
		if(log_get_max_level() >= LOG_TRACE){
			auto *evreg = interface::getGlobalEventRegistry();
			log_t("state", "emit_event(): %s (%zu)",
					cs(evreg->name(event.type)), event.type);
		}

		sv_<sv_<wp_<ModuleContainer>>> event_subs_snapshot;
		{
			interface::MutexScope ms(m_modules_mutex);
			event_subs_snapshot = m_event_subs;
		}

		if(event.type >= event_subs_snapshot.size()){
			log_t("state", "emit_event(): %zu: No subs", event.type);
			return;
		}
		sv_<wp_<ModuleContainer>> &sublist = event_subs_snapshot[event.type];
		if(sublist.empty()){
			log_t("state", "emit_event(): %zu: No subs", event.type);
			return;
		}
		if(log_get_max_level() >= LOG_TRACE){
			auto *evreg = interface::getGlobalEventRegistry();
			log_t("state", "emit_event(): %s (%zu): Pushing to %zu modules",
					cs(evreg->name(event.type)), event.type, sublist.size());
		}
		for(wp_<ModuleContainer> &mc_weak : sublist){
			sp_<ModuleContainer> mc(mc_weak.lock());
			if(mc){
				if(synchronous)
					mc->emit_event_sync(event);
				else
					mc->push_event(event);
			} else {
				auto *evreg = interface::getGlobalEventRegistry();
				log_t("state", "emit_event(): %s: (%zu): Subscriber weak pointer"
						" is null", cs(evreg->name(event.type)), event.type);
			}
		}
	}

	void emit_event(Event event)
	{
		emit_event(event, false);
	}

	void handle_events()
	{
		// Get modified modules and push events to queue
		{
			interface::MutexScope ms(m_modules_mutex);
			set_<ss_> modified_modules;
			modified_modules.swap(m_modified_modules);
			for(const ss_ &name : modified_modules){
				auto it = m_module_info.find(name);
				if(it == m_module_info.end())
					throw Exception("Info of modified module not available");
				interface::ModuleInfo &info = it->second;
				emit_event(Event("core:module_modified",
						new interface::ModuleModifiedEvent(
							info.name, info.path)));
			}
		}

		// Handle module unloads and reloads as requested
		handle_unloads_and_reloads();
	}

	void handle_unloads_and_reloads()
	{
		interface::MutexScope ms(m_modules_mutex);
		// Unload according to unload requests
		for(auto it = m_unloads_requested.begin();
				it != m_unloads_requested.end();){
			ss_ module_name = *it; // Copy
			it++;
			log_i("state", "Unloading %s (unload requested)", cs(module_name));
			m_unloads_requested.erase(module_name);
			unload_module_u(module_name);
		}
		// Unload according to reload requests
		for(const interface::ModuleInfo &info : m_reloads_requested){
			log_i("state", "Unloading %s (reload requested)", cs(info.name));
			unload_module_u(info.name);
		}
		// Load according to reload requests
		for(const interface::ModuleInfo &info : m_reloads_requested){
			log_i("state", "Loading %s (reload requested)", cs(info.name));
			load_module(info);
			// Send core::continue directly to module
			{
				sp_<ModuleContainer> mc;
				{
					// This prevents module from being deleted while a reference
					// is being copied
					interface::MutexScope ms(m_modules_mutex);
					auto it = m_modules.find(info.name);
					if(it == m_modules.end()){
						log_w(MODULE, "reload_module: Module not found: %s",
								cs(info.name));
						return;
					}
					mc = it->second;
				}
				interface::MutexScope mc_ms(mc->mutex);
				mc->module->event(Event::t("core:continue"), nullptr);
			}
		}
		m_reloads_requested.clear();
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

	// Add resource file path (to make a mirror of the client)
	void add_file_path(const ss_ &name, const ss_ &path)
	{
		log_d(MODULE, "add_file_path(): %s -> %s", cs(name), cs(path));
		interface::MutexScope ms(m_file_paths_mutex);
		m_file_paths[name] = path;
	}

	// Returns "" if not found
	ss_ get_file_path(const ss_ &name)
	{
		interface::MutexScope ms(m_file_paths_mutex);
		auto it = m_file_paths.find(name);
		if(it == m_file_paths.end())
			return "";
		return it->second;
	}

	const interface::ServerConfig& get_config()
	{
		return g_server_config;
	}

	void access_thread_pool(std::function<void(
				interface::thread_pool::ThreadPool*pool)> cb)
	{
		interface::MutexScope ms(m_thread_pool_mutex);
		cb(m_thread_pool.get());
	}
};

State* createState()
{
	return new CState();
}
}
// vim: set noet ts=4 sw=4:
