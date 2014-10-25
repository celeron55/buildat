// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "state.h"
#include "core/log.h"
#include "rccpp.h"
#include "config.h"
#include "urho3d_log_redirect.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/file_watch.h"
#include "interface/fs.h"
#include "interface/magic_event.h"
#include "interface/sha1.h"
#include "interface/mutex.h"
#include "interface/thread_pool.h"
#include <c55/string_util.h>
#include <c55/filesys.h>
#include <Variant.h>
#include <Context.h>
#include <Engine.h>
#include <Scene.h>
#include <SceneEvents.h>
#include <Component.h>
#include <ReplicationState.h>
#include <PhysicsWorld.h>
#include <ResourceCache.h>
#include <Octree.h>
#include <Profiler.h>
#include <iostream>
#include <algorithm>
#include <fstream>
#define MODULE "__state"

#ifdef _WIN32
	#define MODULE_EXTENSION "dll"
#else
	#define MODULE_EXTENSION "so"
#endif

using interface::Event;
namespace magic = Urho3D;

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
		if(include == "")
			continue;
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

static ss_ hash_files(const sv_<ss_> &paths)
{
	std::ostringstream os(std::ios::binary);
	for(const ss_ &path : paths){
		std::ifstream f(path);
		try {
			std::string content((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
			os<<content;
		} catch(std::ios_base::failure &e){
			// Just ignore errors
			log_w(MODULE, "hash_files: failed to read file %s: %s",
					cs(path), e.what());
		}
	}
	return interface::sha1::calculate(os.str());
}

class BuildatResourceRouter: public magic::ResourceRouter
{
	OBJECT(BuildatResourceRouter);

	server::State *m_server;
public:
	BuildatResourceRouter(magic::Context *context, server::State *server):
		magic::ResourceRouter(context),
		m_server(server)
	{}
	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		ss_ path = m_server->get_file_path(name.CString());
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			return;
		}
		log_v(MODULE, "Resource route access: %s -> %s",
				name.CString(), cs(path));
		name = path.c_str();
	}
};

// This can be used for subscribing to Urho3D events as Buildat events
struct MagicEventHandler: public magic::Object
{
	OBJECT(MagicEventHandler);

	interface::Server *m_server;
	interface::Event::Type m_buildat_event_type;

	MagicEventHandler(magic::Context *context,
			interface::Server *server,
			const magic::StringHash &event_type,
			const interface::Event::Type &buildat_event_type):
		magic::Object(context),
		m_server(server),
		m_buildat_event_type(buildat_event_type)
	{
		SubscribeToEvent(event_type, HANDLER(MagicEventHandler, on_event));
	}

	void on_event(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		auto *evreg = interface::getGlobalEventRegistry();
		if(log_get_max_level() >= LOG_DEBUG){
			log_d(MODULE, "MagicEventHandler::on_event(): %s (%zu)",
					cs(evreg->name(m_buildat_event_type)), m_buildat_event_type);
		}
		// Convert pointers to IDs because the event will be queued for later
		// handling and pointers may become invalid
		if(event_type == magic::E_NODEADDED ||
				event_type == magic::E_NODEREMOVED){
			magic::Node *parent = static_cast<magic::Node*>(
					event_data["Parent"].GetVoidPtr());
			event_data["ParentID"] = parent->GetID();
			event_data.Erase("Parent");
			magic::Node *node = static_cast<magic::Node*>(
					event_data["Node"].GetVoidPtr());
			event_data["NodeID"] = node->GetID();
			event_data.Erase("Node");
		}
		if(event_type == magic::E_COMPONENTADDED ||
				event_type == magic::E_COMPONENTREMOVED){
			magic::Node *node = static_cast<magic::Node*>(
					event_data["Node"].GetVoidPtr());
			event_data["NodeID"] = node->GetID();
			event_data.Erase("Node");
			magic::Component *c = static_cast<magic::Component*>(
					event_data["Component"].GetVoidPtr());
			event_data["ComponentID"] = c->GetID();
			event_data.Erase("Component");
		}
		m_server->emit_event(m_buildat_event_type, new interface::MagicEvent(
					event_type, event_data));
	}
};

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
	int m_shutdown_exit_status = 0;
	ss_ m_shutdown_reason;

	up_<rccpp::Compiler> m_compiler;
	ss_ m_modules_path;

	magic::SharedPtr<magic::Context> m_magic_context;
	magic::SharedPtr<magic::Engine> m_magic_engine;
	magic::SharedPtr<magic::Scene> m_magic_scene;
	sm_<Event::Type, magic::SharedPtr<MagicEventHandler>> m_magic_event_handlers;
	// NOTE: m_magic_mutex must be locked when constructing or destructing
	//       modules. In every other case modules must use access_scene().
	// NOTE: If not locked, creating or destructing Urho3D Objects can cause a
	//       crash.
	interface::Mutex m_magic_mutex; // Lock for all of Urho3D

	sm_<ss_, interface::ModuleInfo> m_module_info; // Info of every seen module
	sm_<ss_, ModuleContainer> m_modules; // Currently loaded modules
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
	interface::Mutex m_modules_mutex;

	sv_<Event> m_event_queue;
	interface::Mutex m_event_queue_mutex;

	sv_<sv_<ModuleContainer* >> m_event_subs;
	interface::Mutex m_event_subs_mutex;

	sm_<int, SocketState> m_sockets;
	interface::Mutex m_sockets_mutex;

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

		// Initialize Urho3D

		m_magic_context = new magic::Context();
		m_magic_engine = new magic::Engine(m_magic_context);

		// Load hardcoded log redirection module
		{
			interface::Module *m = new urho3d_log_redirect::Module(this);
			load_module_direct_u(m, "urho3d_log_redirect");

			// Disable timestamps in Urho3D log message events
			magic::Log *magic_log = m_magic_context->GetSubsystem<magic::Log>();
			magic_log->SetTimeStamp(false);
		}

		sv_<ss_> resource_paths = {
			g_server_config.urho3d_path+"/Bin/CoreData",
			g_server_config.urho3d_path+"/Bin/Data",
		};
		auto *fs = interface::getGlobalFilesystem();
		ss_ resource_paths_s;
		for(const ss_ &path : resource_paths){
			if(!resource_paths_s.empty())
				resource_paths_s += ";";
			resource_paths_s += fs->get_absolute_path(path);
		}

		magic::VariantMap params;
		params["ResourcePaths"] = resource_paths_s.c_str();
		params["Headless"] = true;
		params["LogName"] = ""; // Don't log to file
		params["LogQuiet"] = true; // Don't log to stdout
		if(!m_magic_engine->Initialize(params))
			throw Exception("Urho3D engine initialization failed");

		m_magic_scene = new magic::Scene(m_magic_context);

		auto *physics = m_magic_scene->CreateComponent<magic::PhysicsWorld>(
				magic::LOCAL);
		physics->SetFps(30);
		physics->SetInterpolation(false);

		// Useless but gets rid of warnings like
		// "ERROR: No Octree component in scene, drawable will not render"
		m_magic_scene->CreateComponent<magic::Octree>(magic::LOCAL);

		magic::ResourceCache *magic_cache =
				m_magic_context->GetSubsystem<magic::ResourceCache>();
		//magic_cache->SetAutoReloadResources(true);
		magic_cache->SetResourceRouter(
				new BuildatResourceRouter(m_magic_context, this));
	}
	~CState()
	{
		interface::MutexScope ms(m_modules_mutex);
		interface::MutexScope ms_magic(m_magic_mutex);
		// Unload modules in reverse load order to make things work more
		// predictably
		for(auto name_it = m_module_load_order.rbegin();
				name_it != m_module_load_order.rend(); ++name_it){
			auto it2 = m_modules.find(*name_it);
			if(it2 == m_modules.end())
				continue;
			ModuleContainer &mc = it2->second;
			// Don't lock; it would only cause deadlocks
			delete mc.module;
			mc.module = nullptr;
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

	// Call with m_modules_mutex and m_magic_mutex locked
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
		interface::MutexScope ms(m_modules_mutex);
		interface::MutexScope ms_magic(m_magic_mutex);

		interface::ModuleInfo info;
		info.name = name;
		info.path = "";

		log_i(MODULE, "Loading module %s (hardcoded)", cs(info.name));

		m_module_info[info.name] = info;

		m_modules[info.name] = ModuleContainer(m, info);
		m_module_load_order.push_back(info.name);

		// Call init()
		ModuleContainer &mc = m_modules[info.name];
		interface::MutexScope ms2(mc.mutex);
		mc.module->init();
	}

	bool load_module(const interface::ModuleInfo &info)
	{
		interface::MutexScope ms(m_modules_mutex);
		interface::MutexScope ms_magic(m_magic_mutex);

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
		m_modules[info.name] = ModuleContainer(m, info);
		m_module_load_order.push_back(info.name);

		// Call init()

		if(m){
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

		if(is_shutdown_requested())
			return;

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
		ModuleContainer *mc = &it->second;
		{
			interface::MutexScope mc_ms(mc->mutex);
			// Send core::unload directly to module
			mc->module->event(Event::t("core:unload"), nullptr);
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
			{
				interface::MutexScope ms_magic(m_magic_mutex);
				delete mc->module;
			}
		}
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
		if(log_get_max_level() >= LOG_TRACE){
			auto *evreg = interface::getGlobalEventRegistry();
			log_t("state", "emit_event(): %s (%zu)",
					cs(evreg->name(event.type)), event.type);
		}
		interface::MutexScope ms(m_event_queue_mutex);
		m_event_queue.push_back(std::move(event));
	}

	void access_scene(std::function<void(magic::Scene*)> cb)
	{
		interface::MutexScope ms(m_magic_mutex);
		cb(m_magic_scene);
	}

	void sub_magic_event(struct interface::Module *module,
			const magic::StringHash &event_type,
			const Event::Type &buildat_event_type)
	{
		{
			interface::MutexScope ms(m_magic_mutex);
			m_magic_event_handlers[buildat_event_type] = new MagicEventHandler(
					m_magic_context, this, event_type, buildat_event_type);
		}
		sub_event(module, buildat_event_type);
	}

	void handle_events()
	{
		magic::AutoProfileBlock profiler_block(m_magic_context->
			GetSubsystem<magic::Profiler>(), "Buildat|handle_events");

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
		// Note: Locking m_modules_mutex here is not needed because no modules
		// can be deleted while this is running, because modules are deleted
		// only by this same thread.
		for(size_t loop_i = 0;; loop_i++){
			if(g_sigint_received){
				// Get out fast
				throw ServerShutdownRequest("Server shutdown requested via SIGINT");
			}
			sv_<Event> event_queue_snapshot;
			sv_<sv_<ModuleContainer* >> event_subs_snapshot;
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
					log_t("state", "handle_events(); Nothing to do");
				break;
			}
			for(const Event &event : event_queue_snapshot){
				if(event.type >= event_subs_snapshot.size()){
					log_t("state", "handle_events(): %zu: No subs", event.type);
					continue;
				}
				sv_<ModuleContainer*> &sublist = event_subs_snapshot[event.type];
				if(sublist.empty()){
					log_t("state", "handle_events(): %zu: No subs", event.type);
					continue;
				}
				log_t("state", "handle_events(): %zu: Handling (%zu handlers)",
						event.type, sublist.size());
				for(ModuleContainer *mc : sublist){
					interface::MutexScope mc_ms(mc->mutex);
					mc->module->event(event.type, event.p.get());
				}
			}
			handle_unloads_and_reloads();
		}
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
		m_reloads_requested.clear();
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
			interface::Event event(s.event_type,
					new interface::SocketEvent(fd));
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
