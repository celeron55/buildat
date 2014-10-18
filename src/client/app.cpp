// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include "core/log.h"
#include "client/config.h"
#include "client/state.h"
#include "lua_bindings/init.h"
#include "lua_bindings/util.h"
#include "interface/fs.h"
#include "interface/voxel.h"
#include "interface/worker_thread.h"
#include <c55/getopt.h>
#include <c55/os.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Application.h>
#include <Engine.h>
#include <LuaScript.h>
#include <CoreEvents.h>
#include <Input.h>
#include <ResourceCache.h>
#include <Graphics.h>
#include <GraphicsEvents.h> // E_SCREENMODE
#include <IOEvents.h> // E_LOGMESSAGE
#include <Log.h>
#include <DebugHud.h>
#include <XMLFile.h>
#include <Scene.h>
#include <LuaFunction.h>
#include <Viewport.h>
#include <Camera.h>
#include <Renderer.h>
#include <Octree.h>
#include <FileSystem.h>
#include <PhysicsWorld.h>
#include <DebugRenderer.h>
#include <Profiler.h>
#pragma GCC diagnostic pop
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <signal.h>
#define MODULE "__app"
namespace magic = Urho3D;

extern client::Config g_client_config;
extern bool g_sigint_received;

namespace app {

void GraphicsOptions::apply(magic::Graphics *magic_graphics)
{
	int w = fullscreen ? full_w : window_w;
	int h = fullscreen ? full_h : window_h;
	magic_graphics->SetMode(w, h, fullscreen, borderless, resizable,
			vsync, triple_buffer, multisampling);
}

class BuildatResourceRouter: public magic::ResourceRouter
{
	OBJECT(BuildatResourceRouter);

	sp_<client::State> m_client;
public:
	BuildatResourceRouter(magic::Context *context):
		magic::ResourceRouter(context)
	{}
	void set_client(sp_<client::State> client)
	{
		m_client = client;
	}

	void Route(magic::String &name, magic::ResourceRequest requestType)
	{
		if(!m_client){
			log_w(MODULE, "Resource route access: %s (client not initialized)",
					name.CString());
			return;
		}
		ss_ path = m_client->get_file_path(name.CString());
		if(path == ""){
			log_v(MODULE, "Resource route access: %s (assuming local file)",
					name.CString());
			// NOTE: Path safety is checked by magic::FileSystem
			return;
		}
		log_v(MODULE, "Resource route access: %s -> %s",
				name.CString(), cs(path));
		name = path.c_str();
	}
};

struct CApp: public App, public magic::Application
{
	sp_<client::State> m_state;
	BuildatResourceRouter *m_router;
	magic::LuaScript *m_script;
	lua_State *L;
	bool m_reboot_requested = false;
	Options m_options;
	bool m_draw_debug_geometry = false;
	int64_t m_last_update_us;

	magic::SharedPtr<magic::Scene> m_scene;
	magic::SharedPtr<magic::Node> m_camera_node;

	sp_<interface::TextureAtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;
	//sp_<interface::BlockRegistry> m_block_reg;

	sp_<interface::worker_thread::ThreadPool> m_thread_pool;

	CApp(magic::Context *context, const Options &options):
		magic::Application(context),
		m_script(nullptr),
		L(nullptr),
		m_options(options),
		m_last_update_us(get_timeofday_us()),
		m_thread_pool(interface::worker_thread::createThreadPool())
	{
		log_v(MODULE, "constructor()");
		log_v(MODULE, "window size: %ix%i",
				m_options.graphics.window_w, m_options.graphics.window_h);

		m_thread_pool->start(4); // TODO: Configurable

		sv_<ss_> resource_paths = {
			g_client_config.cache_path+"/tmp",
			g_client_config.share_path+"/extensions", // Could be unsafe
			g_client_config.urho3d_path+"/Bin/CoreData",
			g_client_config.urho3d_path+"/Bin/Data",
		};
		auto *fs = interface::getGlobalFilesystem();
		ss_ resource_paths_s;
		for(const ss_ &path : resource_paths){
			if(!resource_paths_s.empty())
				resource_paths_s += ";";
			resource_paths_s += fs->get_absolute_path(path);
		}

		// Set allowed paths in urho3d filesystem (part of sandbox)
		magic::FileSystem *magic_fs = GetSubsystem<magic::FileSystem>();
		for(const ss_ &path : resource_paths){
			magic_fs->RegisterPath(fs->get_absolute_path(path).c_str());
		}
		magic_fs->RegisterPath(
				fs->get_absolute_path(g_client_config.cache_path).c_str());

		// Useful for saving stuff for inspection when debugging
		magic_fs->RegisterPath("/tmp");

		// Set Urho3D engine parameters
		engineParameters_["WindowTitle"] = "Buildat Client";
		engineParameters_["Headless"] = false;
		engineParameters_["ResourcePaths"] = resource_paths_s.c_str();
		engineParameters_["AutoloadPaths"] = "";
		engineParameters_["LogName"] = "";
		engineParameters_["LogQuiet"] = true; // Don't log to stdout

		// Graphics options
		engineParameters_["FullScreen"] = m_options.graphics.fullscreen;
		if(m_options.graphics.fullscreen){
			engineParameters_["WindowWidth"] = m_options.graphics.full_w;
			engineParameters_["WindowHeight"] = m_options.graphics.full_h;
		} else {
			engineParameters_["WindowWidth"] = m_options.graphics.window_w;
			engineParameters_["WindowHeight"] = m_options.graphics.window_h;
			engineParameters_["WindowResizable"] = m_options.graphics.resizable;
		}
		engineParameters_["VSync"] = m_options.graphics.vsync;
		engineParameters_["TripleBuffer"] = m_options.graphics.triple_buffer;
		engineParameters_["Multisample"] = m_options.graphics.multisampling;

		magic::Log *magic_log = GetSubsystem<magic::Log>();
		// Disable timestamps in log messages (also added to events)
		magic_log->SetTimeStamp(false);

		// Set up event handlers
		SubscribeToEvent(magic::E_UPDATE, HANDLER(CApp, on_update));
		SubscribeToEvent(magic::E_POSTRENDERUPDATE,
				HANDLER(CApp, on_post_render_update));
		SubscribeToEvent(magic::E_KEYDOWN, HANDLER(CApp, on_keydown));
		SubscribeToEvent(magic::E_SCREENMODE, HANDLER(CApp, on_screenmode));
		SubscribeToEvent(magic::E_LOGMESSAGE, HANDLER(CApp, on_logmessage));

		// Default to not grabbing the mouse
		magic::Input *magic_input = GetSubsystem<magic::Input>();
		magic_input->SetMouseVisible(true);

		// Default to auto-loading resources as they are modified
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->SetAutoReloadResources(true);
		m_router = new BuildatResourceRouter(context_);
		magic_cache->SetResourceRouter(m_router);

		// Create atlas and voxel registries
		m_atlas_reg.reset(interface::createTextureAtlasRegistry(context));
		m_voxel_reg.reset(interface::createVoxelRegistry());

		// Add test voxels
		// TOOD: Remove this from here
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "air";
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "";
				seg.total_segments = magic::IntVector2(0, 0);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
			m_voxel_reg->add_voxel(vdef); // id 1
		}
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "rock";
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/rock.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			m_voxel_reg->add_voxel(vdef); // id 2
		}
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "dirt";
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/dirt.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			m_voxel_reg->add_voxel(vdef); // id 3
		}
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "grass";
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/grass.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			m_voxel_reg->add_voxel(vdef); // id 4
		}
		{
			interface::VoxelDefinition vdef;
			vdef.name.block_name = "leaves";
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t i = 0; i < 6; i++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[i];
				seg.resource_name = "main/leaves.png";
				seg.total_segments = magic::IntVector2(1, 1);
				seg.select_segment = magic::IntVector2(0, 0);
			}
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = true;
			m_voxel_reg->add_voxel(vdef); // id 5
		}
	}

	~CApp()
	{
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
		m_router->set_client(state);
	}

	int run()
	{
		return magic::Application::Run();
	}

	void shutdown()
	{
		log_v(MODULE, "shutdown()");

		// Save window position
		magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
		magic::IntVector2 v = magic_graphics->GetWindowPosition();
		m_options.graphics.window_x = v.x_;
		m_options.graphics.window_y = v.y_;

		magic::Engine *engine = GetSubsystem<magic::Engine>();
		engine->Exit();
	}

	bool reboot_requested()
	{
		return m_reboot_requested;
	}

	Options get_current_options()
	{
		return m_options;
	}

	void run_script(const ss_ &script)
	{
		log_v(MODULE, "run_script():\n%s", cs(script));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_run_code_in_sandbox");
		lua_pushlstring(L, script.c_str(), script.size());
		error_logging_pcall(L, 1, 1);
		bool status = lua_toboolean(L, -1);
		lua_pop(L, 1);
		if(status == false){
			log_w(MODULE, "run_script(): failed");
		} else {
			log_v(MODULE, "run_script(): succeeded");
		}
	}

	bool run_script_no_sandbox(const ss_ &script)
	{
		log_v(MODULE, "run_script_no_sandbox():\n%s", cs(script));

		// TODO: Use lua_load() so that chunkname can be set
		if(luaL_loadstring(L, script.c_str())){
			ss_ error = lua_bindings::lua_tocppstring(L, -1);
			log_e("%s", cs(error));
			lua_pop(L, 1);
			return false;
		}
		error_logging_pcall(L, 0, 0);
		return true;
	}

	void handle_packet(const ss_ &name, const ss_ &data)
	{
		log_v(MODULE, "handle_packet(): %s", cs(name));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_handle_packet");
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, data.c_str(), data.size());
		error_logging_pcall(L, 2, 0);
	}

	void file_updated_in_cache(const ss_ &file_name,
			const ss_ &file_hash, const ss_ &cached_path)
	{
		log_v(MODULE, "file_updated_in_cache(): %s", cs(file_name));

		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic_cache->ReloadResourceWithDependencies(file_name.c_str());

		/*lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_file_updated_in_cache");
		if(lua_isnil(L, -1)){
		    lua_pop(L, 1);
		    return;
		}
		lua_pushlstring(L, file_name.c_str(), file_name.size());
		lua_pushlstring(L, file_hash.c_str(), file_hash.size());
		lua_pushlstring(L, cached_path.c_str(), cached_path.size());
		error_logging_pcall(L, 3, 0);*/
	}

	magic::Scene* get_scene()
	{
		return m_scene;
	}

	interface::VoxelRegistry* get_voxel_registry()
	{
		return m_voxel_reg.get();
	}

	interface::TextureAtlasRegistry* get_atlas_registry()
	{
		return m_atlas_reg.get();
	}

	interface::worker_thread::ThreadPool* get_thread_pool()
	{
		return m_thread_pool.get();
	}

	// Non-public methods

	void Start()
	{
		log_v(MODULE, "Start()");

		// Restore window to previous position
		if(m_options.graphics.window_x != GraphicsOptions::UNDEFINED_INT &&
				m_options.graphics.window_y != GraphicsOptions::UNDEFINED_INT){
			magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
			magic_graphics->SetWindowPosition(
					m_options.graphics.window_x, m_options.graphics.window_y);
		}

		// Instantiate and register the Lua script subsystem so that we can use the LuaScriptInstance component
		context_->RegisterSubsystem(new magic::LuaScript(context_));

		m_script = context_->GetSubsystem<magic::LuaScript>();
		L = m_script->GetState();
		if(L == nullptr)
			throw Exception("m_script.GetState() returned null");

		// Store current CApp instance in registry
		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

		lua_bindings::init(L);

#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}

		DEF_BUILDAT_FUNC(connect_server)
		DEF_BUILDAT_FUNC(disconnect)
		DEF_BUILDAT_FUNC(send_packet);
		DEF_BUILDAT_FUNC(get_file_path)
		DEF_BUILDAT_FUNC(get_file_content)
		DEF_BUILDAT_FUNC(get_path)
		DEF_BUILDAT_FUNC(extension_path)

		// Create a scene that will be synchronized from the server
		m_scene = new magic::Scene(context_);
		m_scene->CreateComponent<magic::Octree>(magic::LOCAL);
		m_scene->CreateComponent<magic::PhysicsWorld>(magic::LOCAL);
		m_scene->CreateComponent<magic::DebugRenderer>(magic::LOCAL);

		// Create a camera and a viewport for the scene. The scene can then be
		// accessed in Lua by magic.renderer:GetViewport(0):GetScene().

		// NOTE: These are accessed, stored and removed by
		//       client/replication.lua, and extensions/replicate exposes the
		//       scene as a clean API.

		m_camera_node = m_scene->CreateChild(
				"__buildat_replicated_scene_camera", magic::LOCAL);
		magic::Camera *camera =
				m_camera_node->CreateComponent<magic::Camera>(magic::LOCAL);
		camera->SetFarClip(300.0f);
		m_camera_node->SetPosition(magic::Vector3(7.0, 7.0, 7.0));
		m_camera_node->LookAt(magic::Vector3(0, 1, 0));

		magic::Renderer *renderer = GetSubsystem<magic::Renderer>();
		magic::SharedPtr<magic::Viewport> viewport(new magic::Viewport(
				context_, m_scene, m_camera_node->GetComponent<magic::Camera>()));
		renderer->SetViewport(0, viewport);

		// Won't work; accessing the resulting value in Lua segfaults.
		/*magic::WeakPtr<magic::LuaFunction> f =
		        m_script->GetFunction("__buildat_set_sync_scene");
		if(!f)
		    throw Exception("__buildat_set_sync_scene not found");
		f->BeginCall();
		f->PushUserType(m_scene.Get(), "Scene");
		f->EndCall();*/

		// Run initial client Lua scripts
		ss_ init_lua_path = g_client_config.share_path+"/client/init.lua";
		int error = luaL_dofile(L, init_lua_path.c_str());
		if(error){
			log_w(MODULE, "luaL_dofile: An error occurred: %s\n",
					lua_tostring(L, -1));
			lua_pop(L, 1);
			throw AppStartupError("Could not initialize Lua environment");
		}

		// Launch menu if requested
		if(g_client_config.boot_to_menu){
			ss_ extname = g_client_config.menu_extension_name;
			ss_ script = ss_() +
				"local m = require('buildat/extension/"+extname+"')\n"
					"if type(m) ~= 'table' then\n"
					"    error('Failed to load extension "+extname+"')\n"
					"end\n"
					"m.boot()\n";
			if(!run_script_no_sandbox(script)){
				throw AppStartupError(ss_()+
							  "Failed to load and run extension "+extname);
			}
		}

		// Create debug HUD
		magic::ResourceCache *magic_cache = GetSubsystem<magic::ResourceCache>();
		magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
		dhud->SetDefaultStyle(magic_cache->GetResource<magic::XMLFile>(
					"UI/DefaultStyle.xml"));
	}

	void on_update(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		/*magic::AutoProfileBlock profiler_block(
		        GetSubsystem<magic::Profiler>(), "App::on_update");*/

		m_atlas_reg->update();

		if(g_sigint_received)
			shutdown();
		if(m_state)
			m_state->update();

		{
			magic::AutoProfileBlock profiler_block(
					GetSubsystem<magic::Profiler>(), "Buildat|ThreadPool::post");
			m_thread_pool->run_post();
		}

#ifdef DEBUG_LOG_TIMING
		int64_t t1 = get_timeofday_us();
		int interval = t1 - m_last_update_us;
		if(interval > 30000)
			log_w(MODULE, "Too long update interval: %ius", interval);
		m_last_update_us = t1;
#endif
	}

	void on_post_render_update(
			magic::StringHash event_type, magic::VariantMap &event_data)
	{
		if(m_draw_debug_geometry)
			m_scene->GetComponent<magic::PhysicsWorld>()->DrawDebugGeometry(true);
	}

	void on_keydown(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		int key = event_data["Key"].GetInt();
		if(key == Urho3D::KEY_F11){
			log_v(MODULE, "F11");
			magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
			if(magic_graphics->GetFullscreen()){
				// Switch to windowed mode
				magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
				m_options.graphics.fullscreen = false;
				m_options.graphics.resizable = true;
				m_options.graphics.apply(magic_graphics);
			} else {
				// Switch to fullscreen mode
				magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
				m_options.graphics.fullscreen = true;
				m_options.graphics.resizable = false;
				m_options.graphics.apply(magic_graphics);
			}
		}
		if(key == Urho3D::KEY_F10){
			ss_ extname = "sandbox_test";
			ss_ script = ss_() +
				"local m = require('buildat/extension/"+extname+"')\n"
					"if type(m) ~= 'table' then\n"
					"    error('Failed to load extension "+extname+"')\n"
					"end\n"
					"m.toggle()\n";
			if(!run_script_no_sandbox(script)){
				log_e(MODULE, "Failed to load and run extension %s", cs(extname));
			}
		}
		if(key == Urho3D::KEY_F9){
			magic::DebugHud *dhud = GetSubsystem<magic::Engine>()->CreateDebugHud();
			dhud->ToggleAll();
		}
		if(key == Urho3D::KEY_F8){
			m_draw_debug_geometry = !m_draw_debug_geometry;
		}
	}

	void on_screenmode(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		// If in windowed mode, update resolution in options
		magic::Graphics *magic_graphics = GetSubsystem<magic::Graphics>();
		if(!magic_graphics->GetFullscreen()){
			m_options.graphics.window_w = event_data["Width"].GetInt();
			m_options.graphics.window_h = event_data["Height"].GetInt();
			log_v(MODULE, "Window size in graphics options updated: %ix%i",
					m_options.graphics.window_w, m_options.graphics.window_h);
		}
	}

	void on_logmessage(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		int magic_level = event_data["Level"].GetInt();
		ss_ message = event_data["Message"].GetString().CString();
		//log_v(MODULE, "on_logmessage(): %i, %s", magic_level, cs(message));
		int c55_level = LOG_ERROR;
		if(magic_level == magic::LOG_DEBUG)
			c55_level = LOG_DEBUG;
		else if(magic_level == magic::LOG_INFO)
			c55_level = LOG_VERBOSE;
		else if(magic_level == magic::LOG_WARNING)
			c55_level = LOG_WARNING;
		else if(magic_level == magic::LOG_ERROR)
			c55_level = LOG_ERROR;
		log_(c55_level, MODULE, "Urho3D %s", cs(message));
	}

	// Apps-specific lua functions

	// connect_server(address: string) -> status: bool, error: string or nil
	static int l_connect_server(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ address = lua_bindings::lua_tocppstring(L, 1);

		ss_ error;
		bool ok = self->m_state->connect(address, &error);
		lua_pushboolean(L, ok);
		if(ok)
			lua_pushnil(L);
		else
			lua_pushstring(L, error.c_str());
		return 2;
	}

	// disconnect()
	static int l_disconnect(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		if(g_client_config.boot_to_menu){
			// If menu, reboot client into menu
			self->m_reboot_requested = true;
			self->shutdown();
		} else {
			// If no menu, shutdown client
			self->shutdown();
		}

		return 0;
	}

	// send_packet(name: string, data: string)
	static int l_send_packet(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		ss_ data = lua_bindings::lua_tocppstring(L, 2);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			self->m_state->send_packet(name, data);
			return 0;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in send_packet: %s", e.what());
			return 0;
		}
	}

	// get_file_path(name: string) -> path, hash
	static int l_get_file_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		ss_ hash;
		ss_ path = self->m_state->get_file_path(name, &hash);
		if(path == "")
			return 0;
		lua_pushlstring(L, path.c_str(), path.size());
		lua_pushlstring(L, hash.c_str(), hash.size());
		return 2;
	}

	// get_file_content(name: string)
	static int l_get_file_content(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			ss_ content = self->m_state->get_file_content(name);
			lua_pushlstring(L, content.c_str(), content.size());
			return 1;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in get_file_content: %s", e.what());
			return 0;
		}
	}

	// When calling Lua from C++, this is universally good
	static void error_logging_pcall(lua_State *L, int nargs, int nresults)
	{
		log_t(MODULE, "error_logging_pcall(): nargs=%i, nresults=%i",
				nargs, nresults);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_pushcfunction(L, lua_bindings::handle_error);
		lua_insert(L, start_L - nargs);
		int handle_error_L = start_L - nargs;
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
		int r = lua_pcall(L, nargs, nresults, handle_error_L);
		lua_remove(L, handle_error_L);
		//log_d(MODULE, "stack 3: %s", cs(dump_stack(L)));
		if(r != 0){
			ss_ traceback = lua_bindings::lua_tocppstring(L, -1);
			lua_pop(L, 1);
			const char *msg =
					r == LUA_ERRRUN ? "runtime error" :
					r == LUA_ERRMEM ? "ran out of memory" :
					r == LUA_ERRERR ? "error handler failed" : "unknown error";
			//log_e(MODULE, "Lua %s: %s", msg, cs(traceback));
			throw Exception(ss_()+"Lua "+msg+":\n"+traceback);
		}
		//log_d(MODULE, "stack 4: %s", cs(dump_stack(L)));
	}

	static void call_global_if_exists(lua_State *L,
			const char *global_name, int nargs, int nresults)
	{
		log_t(MODULE, "call_global_if_exists(): \"%s\"", global_name);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_getfield(L, LUA_GLOBALSINDEX, global_name);
		if(lua_isnil(L, -1)){
			lua_pop(L, 1 + nargs);
			return;
		}
		lua_insert(L, start_L - nargs + 1);
		error_logging_pcall(L, nargs, nresults);
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
	}

	// get_path(name: string)
	static int l_get_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);

		if(name == "share"){
			ss_ path = g_client_config.share_path;
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "cache"){
			ss_ path = g_client_config.cache_path;
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		if(name == "tmp"){
			ss_ path = g_client_config.cache_path+"/tmp";
			lua_pushlstring(L, path.c_str(), path.size());
			return 1;
		}
		log_w(MODULE, "Unknown named path: \"%s\"", cs(name));
		return 0;
	}

	// extension_path(name: string)
	static int l_extension_path(lua_State *L)
	{
		ss_ name = lua_bindings::lua_tocppstring(L, 1);
		ss_ path = g_client_config.share_path+"/extensions/"+name;
		// TODO: Check if extension actually exists and do something suitable if
		//       not
		lua_pushlstring(L, path.c_str(), path.size());
		return 1;
	}
};

App* createApp(magic::Context *context, const Options &options)
{
	return new CApp(context, options);
}

}
// vim: set noet ts=4 sw=4:
