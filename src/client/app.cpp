// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include "core/log.h"
#include "client/config.h"
#include "client/state.h"
#include "interface/fs.h"
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
#pragma GCC diagnostic pop
extern "C" {
#include <lua.h>
#include <lauxlib.h>
}
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <signal.h>
#define MODULE "__main"
namespace u3d = Urho3D;

extern client::Config g_client_config;
extern bool g_sigint_received;

namespace app {

struct CApp: public App, public u3d::Application
{
	sp_<client::State> m_state;
	u3d::LuaScript *m_script;
	lua_State *L;
	int64_t m_last_script_tick_us;

	CApp(u3d::Context *context):
		u3d::Application(context),
		m_script(nullptr),
		L(nullptr),
		m_last_script_tick_us(get_timeofday_us())
	{
		engineParameters_["WindowTitle"]   = "Buildat Client";
		engineParameters_["LogName"]       = "client_Urho3D.log";
		engineParameters_["FullScreen"]    = false;
		engineParameters_["Headless"]      = false;

		ss_ urho3d_path = interface::getGlobalFilesystem()->get_absolute_path(
				g_client_config.urho3d_path);
		ss_ tmp_path = interface::getGlobalFilesystem()->get_absolute_path(
				g_client_config.cache_path+"/tmp");
		engineParameters_["ResourcePaths"] = u3d::String() +
				urho3d_path.c_str()+"/Bin/CoreData;"+
				urho3d_path.c_str()+"/Bin/Data;"+
				tmp_path.c_str();
		engineParameters_["AutoloadPaths"] = "";

		// Set up on_update event (this runs every frame)
		SubscribeToEvent(u3d::E_UPDATE, HANDLER(CApp, on_update));

		// Default to not grabbing the mouse
		u3d::Input *u3d_input = GetSubsystem<u3d::Input>();
		u3d_input->SetMouseGrabbed(false);
		u3d_input->SetMouseVisible(true);

		// Default to auto-loading resources as they are modified
		u3d::ResourceCache *u3d_cache = GetSubsystem<u3d::ResourceCache>();
		u3d_cache->SetAutoReloadResources(true);
	}

	~CApp()
	{
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
	}

	int run()
	{
		return u3d::Application::Run();
	}

	void shutdown()
	{
		u3d::Engine *engine = GetSubsystem<u3d::Engine>();
		engine->Exit();
	}

	void run_script(const ss_ &script)
	{
		log_v(MODULE, "run_script(): %s", cs(script));

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

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_file_updated_in_cache");
		lua_pushlstring(L, file_name.c_str(), file_name.size());
		lua_pushlstring(L, file_hash.c_str(), file_hash.size());
		lua_pushlstring(L, cached_path.c_str(), cached_path.size());
		error_logging_pcall(L, 3, 0);
	}

	// Non-public methods

	void Start()
	{
		// Instantiate and register the Lua script subsystem so that we can use the LuaScriptInstance component
		context_->RegisterSubsystem(new u3d::LuaScript(context_));

		m_script = context_->GetSubsystem<u3d::LuaScript>();
		L = m_script->GetState();
		if(L == nullptr)
			throw Exception("m_script.GetState() returned null");

		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

#define DEF_BUILDAT_FUNC(name){\
	lua_pushcfunction(L, l_##name);\
	lua_setglobal(L, "__buildat_" #name);\
}
		DEF_BUILDAT_FUNC(print_log);
		DEF_BUILDAT_FUNC(send_packet);
		DEF_BUILDAT_FUNC(get_file_content)
		DEF_BUILDAT_FUNC(get_file_path)
		DEF_BUILDAT_FUNC(get_path)
		DEF_BUILDAT_FUNC(mkdir)
		DEF_BUILDAT_FUNC(pcall)
		DEF_BUILDAT_FUNC(cereal_binary_input)
		DEF_BUILDAT_FUNC(cereal_binary_output)

		ss_ init_lua_path = g_client_config.share_path+"/client/init.lua";
		int error = luaL_dofile(L, init_lua_path.c_str());
		if(error){
			log_w(MODULE, "luaL_dofile: An error occurred: %s\n",
					lua_tostring(L, -1));
			lua_pop(L, 1);
		}
	}

	void on_update(u3d::StringHash eventType, u3d::VariantMap &eventData)
	{
		if(g_sigint_received)
			shutdown();
		if(m_state)
			m_state->update();
		script_tick();
	}

	void script_tick()
	{
		log_t(MODULE, "script_tick()");

		int64_t current_us = get_timeofday_us();
		int64_t d_us = current_us - m_last_script_tick_us;
		if(d_us < 0)
			d_us = 0;
		m_last_script_tick_us = current_us;
		double dtime = d_us / 1000000.0;

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_tick");
		if(lua_isnil(L, -1)){
			lua_pop(L, 1);
			return;
		}
		lua_pushnumber(L, dtime);
		error_logging_pcall(L, 1, 0);
	}

	// print_log(level, module, text)
	static int l_print_log(lua_State *L)
	{
		ss_ level = lua_tocppstring(L, 1);
		const char *module_c = lua_tostring(L, 2);
		const char *text_c = lua_tostring(L, 3);
		int loglevel = LOG_INFO;
		if(level == "debug")
			loglevel = LOG_DEBUG;
		else if(level == "verbose")
			loglevel = LOG_VERBOSE;
		else if(level == "info")
			loglevel = LOG_INFO;
		else if(level == "warning")
			loglevel = LOG_WARNING;
		else if(level == "error")
			loglevel = LOG_ERROR;
		log_(loglevel, module_c, "%s", text_c);
		return 0;
	}

	// send_packet(name: string, data: string)
	static int l_send_packet(lua_State *L)
	{
		ss_ name = lua_tocppstring(L, 1);
		ss_ data = lua_tocppstring(L, 2);

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
		ss_ name = lua_tocppstring(L, 1);

		lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
		CApp *self = (CApp*)lua_touserdata(L, -1);
		lua_pop(L, 1);

		try {
			ss_ hash;
			ss_ path = self->m_state->get_file_path(name, &hash);
			lua_pushlstring(L, path.c_str(), path.size());
			lua_pushlstring(L, hash.c_str(), hash.size());
			return 2;
		} catch(std::exception &e){
			log_w(MODULE, "Exception in get_file_path: %s", e.what());
			return 0;
		}
	}

	// get_file_content(name: string)
	static int l_get_file_content(lua_State *L)
	{
		ss_ name = lua_tocppstring(L, 1);

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

	// get_path(name: string)
	static int l_get_path(lua_State *L)
	{
		ss_ name = lua_tocppstring(L, 1);

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

	// mkdir(path: string)
	static int l_mkdir(lua_State *L)
	{
		ss_ path = lua_tocppstring(L, 1);
		bool ok = interface::getGlobalFilesystem()->create_directories(path);
		if(!ok)
			log_w(MODULE, "Failed to create directory: \"%s\"", cs(path));
		else
			log_v(MODULE, "Created directory: \"%s\"", cs(path));
		lua_pushboolean(L, ok);
		return 1;
	}

	static int handle_error(lua_State *L)
	{
		lua_getglobal(L, "debug");
		if(!lua_istable(L, -1)){
			log_w(MODULE, "handle_error(): debug is nil");
			lua_pop(L, 1);
			return 1;
		}
		lua_getfield(L, -1, "traceback");
		if(!lua_isfunction(L, -1)){
			log_w(MODULE, "handle_error(): debug.traceback is nil");
			lua_pop(L, 2);
			return 1;
		}
		lua_pushvalue(L, 1);
		lua_pushinteger(L, 2);
		lua_call(L, 2, 1);
		return 1;
	}

	// When calling Lua from C++, this is universally good
	static void error_logging_pcall(lua_State *L, int nargs, int nresults)
	{
		log_t(MODULE, "error_logging_pcall(): nargs=%i, nresults=%i",
				nargs, nresults);
		//log_d(MODULE, "stack 1: %s", cs(dump_stack(L)));
		int start_L = lua_gettop(L);
		lua_pushcfunction(L, handle_error);
		lua_insert(L, start_L - nargs);
		int handle_error_L = start_L - nargs;
		//log_d(MODULE, "stack 2: %s", cs(dump_stack(L)));
		int r = lua_pcall(L, nargs, nresults, handle_error_L);
		lua_remove(L, handle_error_L);
		//log_d(MODULE, "stack 3: %s", cs(dump_stack(L)));
		if(r != 0){
			ss_ traceback = lua_tocppstring(L, -1);
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

	// Like lua_pcall, but returns a full traceback on error
	// pcall(untrusted_function) -> status, error
	static int l_pcall(lua_State *L)
	{
		log_d(MODULE, "l_pcall()");
		lua_pushcfunction(L, handle_error);
		int handle_error_stack_i = lua_gettop(L);

		lua_pushvalue(L, 1);
		int r = lua_pcall(L, 0, 0, handle_error_stack_i);
		int error_stack_i = lua_gettop(L);
		if(r == 0){
			log_d(MODULE, "l_pcall() returned 0 (no error)");
			lua_pushboolean(L, true);
			return 1;
		}
		if(r == LUA_ERRRUN)
			log_w(MODULE, "pcall(): Runtime error");
		if(r == LUA_ERRMEM)
			log_w(MODULE, "pcall(): Out of memory");
		if(r == LUA_ERRERR)
			log_w(MODULE, "pcall(): Error handler  failed");
		lua_pushboolean(L, false);
		lua_pushvalue(L, error_stack_i);
		return 2;
	}

	static sv_<ss_> dump_stack(lua_State *L)
	{
		sv_<ss_> result;
		int top = lua_gettop(L);
		for(int i = 1; i <= top; i++){
			int type = lua_type(L, i);
			if(type == LUA_TSTRING)
				result.push_back(ss_()+"\""+lua_tostring(L, i)+"\"");
			else if(type == LUA_TSTRING)
				result.push_back(ss_()+"\""+lua_tostring(L, i)+"\"");
			else if(type == LUA_TBOOLEAN)
				result.push_back(lua_toboolean(L, i) ? "true" : "false");
			else if(type == LUA_TNUMBER)
				result.push_back(cs(lua_tonumber(L, i)));
			else
				result.push_back(lua_typename(L, type));
		}
		return result;
	}

	static ss_ lua_tocppstring(lua_State *L, int index)
	{
		if(!lua_isstring(L, index))
			throw Exception(ss_()+"lua_tocppstring: Expected string, got "+
					lua_typename(L, index));
		size_t length;
		const char *s = lua_tolstring(L, index, &length);
		return ss_(s, length);
	}

	/* Type format:
	{"object",
		{"peer", "int32_t"},
		{"players", {"unordered_map",
			"int32_t",
			{"object",
				{"peer", "int32_t"},
				{"x", "int32_t"},
				{"y", "int32_t"},
			},
		}},
		{"playfield", {"object",
			{"w", "int32_t"},
			{"h", "int32_t"},
			{"tiles", {"array", "int32_t"}},
		}},
	}) */

	static constexpr auto known_types =
			"byte, int32_t, double, array, unordered_map, object";

	// Places result value on top of stack
	static void binary_input_read_value(lua_State *L, int type_L,
			cereal::PortableBinaryInputArchive &ar)
	{
		if(type_L < 0) type_L = lua_gettop(L) + type_L + 1;

		// Read value definition
		bool has_table = false;
		ss_ outfield_type;
		if(lua_istable(L, type_L)){
			has_table = true;
			lua_rawgeti(L, type_L, 1);
			outfield_type = lua_tocppstring(L, -1);
			lua_pop(L, 1);
		} else if(lua_isstring(L, type_L)){
			outfield_type = lua_tocppstring(L, type_L);
		} else {
			throw Exception("Value definition table or string expected");
		}

		log_t(MODULE, "binary_input_read_value(): type=%s", cs(outfield_type));

		if(outfield_type == "byte"){
			uchar value;
			ar(value);
			log_t(MODULE, "byte value=%i", (int)value);
			lua_pushinteger(L, value);
			// value is left on stack
		} else if(outfield_type == "int32_t"){
			int32_t value;
			ar(value);
			log_t(MODULE, "int32_t value=%i", value);
			lua_pushinteger(L, value);
			// value is left on stack
		} else if(outfield_type == "double"){
			double value;
			ar(value);
			log_t(MODULE, "double value=%f", value);
			lua_pushnumber(L, value);
			// value is left on stack
		} else if(outfield_type == "string"){
			ss_ value;
			ar(value);
			log_t(MODULE, "string value=%s", cs(value));
			lua_pushlstring(L, value.c_str(), value.size());
			// value is left on stack
		} else if(outfield_type == "array"){
			if(!has_table)
				throw Exception("array requires parameter table");
			lua_newtable(L);
			int value_result_table_L = lua_gettop(L);
			lua_rawgeti(L, type_L, 2);
			int array_type_L = lua_gettop(L);
			// Loop through array items
			uint64_t num_entries;
			ar(num_entries);
			for(uint64_t i = 0; i < num_entries; i++){
				log_t(MODULE, "array[%s]", cs(i));
				binary_input_read_value(L, array_type_L, ar);
				lua_rawseti(L, value_result_table_L, i + 1);
			}
			lua_pop(L, 1); // array_type_L
			// value_result_table_L is left on stack
		} else if(outfield_type == "unordered_map"){
			if(!has_table)
				throw Exception("unordered_map requires parameter table");
			lua_newtable(L);
			int value_result_table_L = lua_gettop(L);
			lua_rawgeti(L, type_L, 2);
			int map_key_type_L = lua_gettop(L);
			lua_rawgeti(L, type_L, 3);
			int map_value_type_L = lua_gettop(L);
			// Loop through map entries
			uint64_t num_entries;
			ar(num_entries);
			for(uint64_t i = 0; i < num_entries; i++){
				log_t(MODULE, "unordered_map[%s]", cs(i));
				binary_input_read_value(L, map_key_type_L, ar);
				binary_input_read_value(L, map_value_type_L, ar);
				lua_rawset(L, value_result_table_L);
			}
			lua_pop(L, 1); // map_value_type_L
			lua_pop(L, 1); // map_key_type_L
			// value_result_table_L is left on stack
		} else if(outfield_type == "object"){
			if(!has_table)
				throw Exception("object requires parameter table");
			lua_newtable(L);
			int value_result_table_L = lua_gettop(L);
			// Loop through object fields
			size_t field_i = 0;
			lua_pushnil(L);
			while(lua_next(L, type_L) != 0){
				if(field_i != 0){
					log_t(MODULE, "object field %zu", field_i);
					int field_def_L = lua_gettop(L);
					lua_rawgeti(L, field_def_L, 1); // name
					lua_rawgeti(L, field_def_L, 2); // type
					log_t(MODULE, " = object[\"%s\"]", lua_tostring(L, -2));
					binary_input_read_value(L, -1, ar); // Uses type, pushes value
					lua_remove(L, -2); // Remove type
					lua_rawset(L, value_result_table_L); // Set t[#-2] = #-1
				}
				lua_pop(L, 1); // Continue iterating by popping table value
				field_i++;
			}
			// value_result_table_L is left on stack
		} else {
			throw Exception(ss_()+"Unknown type \""+outfield_type+"\""
					"; known types are "+known_types);
		}
	}

	static void binary_output_write_value(lua_State *L, int value_L, int type_L,
			cereal::PortableBinaryOutputArchive &ar)
	{
		if(value_L < 0) value_L = lua_gettop(L) + value_L + 1;
		if(type_L < 0) type_L = lua_gettop(L) + type_L + 1;

		// Read value definition
		bool has_table = false;
		ss_ outfield_type;
		if(lua_istable(L, type_L)){
			has_table = true;
			lua_rawgeti(L, type_L, 1);
			outfield_type = lua_tocppstring(L, -1);
			lua_pop(L, 1);
		} else if(lua_isstring(L, type_L)){
			outfield_type = lua_tocppstring(L, type_L);
		} else {
			throw Exception("Value definition table or string expected");
		}

		log_t(MODULE, "binary_output_write_value(): type=%s", cs(outfield_type));

		if(outfield_type == "byte"){
			uchar value = lua_tointeger(L, value_L);
			log_t(MODULE, "byte value=%i", (int)value);
			ar(value);
		} else if(outfield_type == "int32_t"){
			int32_t value = lua_tointeger(L, value_L);
			log_t(MODULE, "int32_t value=%i", value);
			ar(value);
		} else if(outfield_type == "double"){
			double value = lua_tonumber(L, value_L);
			log_t(MODULE, "double value=%f", value);
			ar(value);
		} else if(outfield_type == "string"){
			ss_ value = lua_tocppstring(L, value_L);
			log_t(MODULE, "string value=%s", cs(value));
			ar(value);
		} else if(outfield_type == "array"){
			if(!has_table)
				throw Exception("array requires parameter table");
			lua_rawgeti(L, type_L, 2);
			int array_type_L = lua_gettop(L);
			// Loop through array items
			uint64_t num_entries = 0;
			lua_pushnil(L);
			while(lua_next(L, value_L) != 0){
				lua_pop(L, 1); // Continue iterating by popping table value
				num_entries++;
			}
			ar(num_entries);
			lua_pushnil(L);
			int i = 1;
			while(lua_next(L, value_L) != 0){
				log_t(MODULE, "array[%i]", i);
				binary_output_write_value(L, -1, array_type_L, ar);
				lua_pop(L, 1); // Continue iterating by popping table value
				i++;
			}
			lua_pop(L, 1); // array_type_L
			// value_result_table_L is left on stack
		} else if(outfield_type == "unordered_map"){
			if(!has_table)
				throw Exception("unordered_map requires parameter table");
			lua_rawgeti(L, type_L, 2);
			int map_key_type_L = lua_gettop(L);
			lua_rawgeti(L, type_L, 3);
			int map_value_type_L = lua_gettop(L);
			// Loop through map entries
			uint64_t num_entries = 0;
			lua_pushnil(L);
			while(lua_next(L, value_L) != 0){
				lua_pop(L, 1); // Continue iterating by popping table value
				num_entries++;
			}
			ar(num_entries);
			lua_pushnil(L);
			while(lua_next(L, value_L) != 0){
				int key_L = lua_gettop(L) - 1;
				int value_L = lua_gettop(L);
				log_t(MODULE, "unordered_map[%s]", lua_tostring(L, key_L));
				binary_output_write_value(L, key_L, map_key_type_L, ar);
				binary_output_write_value(L, value_L, map_value_type_L, ar);
				lua_pop(L, 1); // Continue iterating by popping table value
			}
			lua_pop(L, 1); // map_value_type_L
			lua_pop(L, 1); // map_key_type_L
			// value_result_table_L is left on stack
		} else if(outfield_type == "object"){
			if(!has_table)
				throw Exception("object requires parameter table");
			// Loop through object fields
			size_t field_i = 0;
			lua_pushnil(L);
			while(lua_next(L, type_L) != 0){
				if(field_i != 0){
					log_t(MODULE, "object field %zu", field_i);
					int field_def_L = lua_gettop(L);
					lua_rawgeti(L, field_def_L, 2); // type
					lua_rawgeti(L, field_def_L, 1); // name
					log_t(MODULE, " = object[\"%s\"]", lua_tostring(L, -1));
					// Get value_L[name]; name is replaced by value
					lua_rawget(L, value_L);
					// Recurse into this value
					binary_output_write_value(L, -1, -2, ar);
					lua_pop(L, 1); // Pop value
					lua_pop(L, 1); // Pop type
				}
				lua_pop(L, 1); // Continue iterating by popping table value
				field_i++;
			}
		} else {
			throw Exception(ss_()+"Unknown type \""+outfield_type+"\""
					"; known types are "+known_types);
		}
	}

	// cereal_binary_input(data: string, types: table) -> table of values
	static int l_cereal_binary_input(lua_State *L)
	{
		size_t data_len = 0;
		const char *data_c = lua_tolstring(L, 1, &data_len);
		ss_ data(data_c, data_len);

		int type_L = 2;

		std::istringstream is(data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);

		binary_input_read_value(L, type_L, ar);

		return 1;
	}

	// cereal_binary_output(values: table, types: table) -> data
	static int l_cereal_binary_output(lua_State *L)
	{
		int value_L = 1;

		int type_L = 2;

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);

			binary_output_write_value(L, value_L, type_L, ar);
		}
		ss_ data = os.str();
		lua_pushlstring(L, data.c_str(), data.size());
		return 1;
	}
};

App* createApp(u3d::Context *context)
{
	return new CApp(context);
}

}
