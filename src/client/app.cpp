// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "app.h"
#include "core/log.h"
#include "client/config.h"
#include "client/state.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
#include <Polycode.h>
#include <PolycodeView.h>
#include <PolycodeLUA.h>
//#include "Physics2DLUA.h"
//#include "Physics3DLUA.h"
#include <UILUA.h>
#include <OSBasics.h>
#pragma GCC diagnostic pop
#include <c55/getopt.h>
#include "c55/os.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <core/log.h>
#include <signal.h>
#define MODULE "__main"

using Polycode::SDLCore;
using Polycode::Logger;
using Polycode::String;
using Polycode::Event;
using Polycode::InputEvent;

extern client::Config g_client_config;

namespace app {

int MyLoader(lua_State *pState)
{
	ss_ module = lua_tostring(pState, 1);

	module += ".lua";
	//Logger::log("Loading custom class: %s\n", module.c_str());

	std::vector<ss_> defaultPaths = {
		g_client_config.polycode_path+"/Bindings/Contents/LUA/API/",
		g_client_config.polycode_path+"/Modules/Bindings/2DPhysics/API/",
		g_client_config.polycode_path+"/Modules/Bindings/3DPhysics/API/",
		g_client_config.polycode_path+"/Modules/Bindings/UI/API/",
	};

	for(ss_ defaultPath : defaultPaths){
		defaultPath.append(module);

		const char *fullPath = module.c_str();

		OSFILE *inFile = OSBasics::open(module, "r");

		if(!inFile){
			inFile =  OSBasics::open(defaultPath, "r");
		}

		if(inFile){
			OSBasics::seek(inFile, 0, SEEK_END);
			long progsize = OSBasics::tell(inFile);
			OSBasics::seek(inFile, 0, SEEK_SET);
			char *buffer = (char*)malloc(progsize + 1);
			memset(buffer, 0, progsize + 1);
			OSBasics::read(buffer, progsize, 1, inFile);
			luaL_loadbuffer(pState, (const char*)buffer, progsize, fullPath);
			free(buffer);
			OSBasics::close(inFile);
			return 1;
		}
	}
	ss_ err = "\n\tError - Could could not find ";
	err += module;
	err += ".";
	lua_pushstring(pState, err.c_str());
	return 1;
}

class BackTraceEntry {
public:
	String fileName;
	unsigned int lineNumber;
};

static int areSameCClass(lua_State *L){
	luaL_checktype(L, 1, LUA_TUSERDATA);
	PolyBase *classOne = *((PolyBase **)lua_touserdata(L, 1));
	luaL_checktype(L, 2, LUA_TUSERDATA);
	PolyBase *classTwo = *((PolyBase **)lua_touserdata(L, 2));

	if(classOne == classTwo){
		lua_pushboolean(L, true);
	} else {
		lua_pushboolean(L, false);
	}
	return 1;
}

// Polycode redirects print() to this
static int debugPrint(lua_State *L)
{
	const char *msg = lua_tostring(L, 1);
	log_i("polycode", "%s", msg);
	return 0;
}

struct CApp: public Polycode::EventHandler, public App
{
	Polycode::Core *core;
	lua_State *L;
	sp_<client::State> m_state;
	int64_t m_last_script_tick_us;

	CApp(Polycode::PolycodeView *view):
		Polycode::EventHandler(), core(NULL), L(NULL),
		m_last_script_tick_us(get_timeofday_us())
	{
		// Win32Core for Windows
		// CocoaCore for Mac
		// SDLCore for Linux
		core = new POLYCODE_CORE(view, 640, 480, false, false, 0, 0, 90, 1, true);

		Polycode::CoreServices::getInstance()->getResourceManager()->addArchive(
				g_client_config.share_path+"/client/default.pak");
		Polycode::CoreServices::getInstance()->getResourceManager()->addDirResource("default",
				false);

		L = lua_open();
		luaL_openlibs(L);
		luaopen_debug(L);
		luaopen_Polycode(L);

		lua_getfield(L, LUA_GLOBALSINDEX, "package");	// push "package"
		lua_getfield(L, -1, "loaders");					// push "package.loaders"
		lua_remove(L, -2);								// remove "package"

		// Count the number of entries in package.loaders.
		// Table is now at index -2, since 'nil' is right on top of it.
		// lua_next pushes a key and a value onto the stack.
		int numLoaders = 0;
		lua_pushnil(L);
		while(lua_next(L, -2) != 0)
		{
			lua_pop(L, 1);
			numLoaders++;
		}

		lua_pushinteger(L, numLoaders + 1);
		lua_pushcfunction(L, MyLoader);
		lua_rawset(L, -3);

		// Table is still on the stack.  Get rid of it now.
		lua_pop(L, 1);

		// Polycode redirects print() to this global
		lua_register(L, "debugPrint", debugPrint);

		// Looks like this global isn't required
		//lua_register(L, "__customError", handle_error);

		// This global is used by Polycode's class implementation
		lua_register(L, "__are_same_c_class", areSameCClass);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "class");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Polycode");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Physics2D");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Physics3D");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "UI");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "tweens");
		error_logging_pcall(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "defaults");
		error_logging_pcall(L, 1, 0);

		// TODO
		//luaopen_Physics2D(L);
		//luaopen_Physics3D(L);
		luaopen_UI(L);

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

		core->getInput()->addEventListener(this, InputEvent::EVENT_KEYDOWN);
		core->getInput()->addEventListener(this, InputEvent::EVENT_KEYUP);
		core->getInput()->addEventListener(this, InputEvent::EVENT_MOUSEDOWN);
		core->getInput()->addEventListener(this, InputEvent::EVENT_MOUSEMOVE);
		core->getInput()->addEventListener(this, InputEvent::EVENT_MOUSEUP);
		core->getInput()->addEventListener(this, InputEvent::EVENT_JOYBUTTON_DOWN);
		core->getInput()->addEventListener(this, InputEvent::EVENT_JOYBUTTON_UP);
		core->getInput()->addEventListener(this, InputEvent::EVENT_JOYAXIS_MOVED);
	}

	~CApp()
	{
		delete core;
		lua_close(L);
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
	}

	bool update()
	{
		script_tick();

		return core->updateAndRender();
	}

	void shutdown()
	{
		core->Shutdown();
	}

	void run_script(const ss_ &script)
	{
		log_v(MODULE, "run_script(): %s", cs(script));

		lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_run_in_sandbox");
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

	// Polycode::EventHandler

	void log_if_error()
	{
		if(lua_toboolean(L, -2)){
			const char *error = lua_tostring(L, -1);
			log_w(MODULE, "%s", error);
			lua_pop(L, 2);
		}
	}

	void handleEvent(Event *event)
	{
		if(event->getDispatcher() == core->getInput()){
			InputEvent *inputEvent = (InputEvent*) event;
			switch(event->getEventCode()){
			case InputEvent::EVENT_KEYDOWN:
				lua_pushinteger(L, inputEvent->keyCode());
				call_global_if_exists(L, "__buildat_key_down", 1, 0);
				break;
			case InputEvent::EVENT_KEYUP:
				lua_pushinteger(L, inputEvent->keyCode());
				call_global_if_exists(L, "__buildat_key_up", 1, 0);
				break;
			case InputEvent::EVENT_MOUSEDOWN:
				lua_pushinteger(L, inputEvent->mouseButton);
				lua_pushnumber(L, inputEvent->mousePosition.x);
				lua_pushnumber(L, inputEvent->mousePosition.y);
				call_global_if_exists(L, "__buildat_mouse_down", 3, 0);
				break;
			case InputEvent::EVENT_MOUSEUP:
				lua_pushinteger(L, inputEvent->mouseButton);
				lua_pushnumber(L, inputEvent->mousePosition.x);
				lua_pushnumber(L, inputEvent->mousePosition.y);
				call_global_if_exists(L, "__buildat_mouse_up", 3, 0);
				break;
			case InputEvent::EVENT_MOUSEMOVE:
				lua_pushnumber(L, inputEvent->mousePosition.x);
				lua_pushnumber(L, inputEvent->mousePosition.y);
				call_global_if_exists(L, "__buildat_mouse_move", 2, 0);
				break;
			case InputEvent::EVENT_JOYBUTTON_DOWN:
				lua_pushnumber(L, inputEvent->joystickIndex);
				lua_pushnumber(L, inputEvent->joystickButton);
				call_global_if_exists(L, "__buildat_joystick_button_down", 2, 0);
				break;
			case InputEvent::EVENT_JOYBUTTON_UP:
				lua_pushnumber(L, inputEvent->joystickIndex);
				lua_pushnumber(L, inputEvent->joystickButton);
				call_global_if_exists(L, "__buildat_joystick_button_up", 2, 0);
				break;
			case InputEvent::EVENT_JOYAXIS_MOVED:
				lua_pushnumber(L, inputEvent->joystickIndex);
				lua_pushnumber(L, inputEvent->joystickAxis);
				lua_pushnumber(L, inputEvent->joystickAxisValue);
				call_global_if_exists(L, "__buildat_joystick_axis_move", 3, 0);
				break;
			}
		}
	}

	// Non-public methods

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
			throw Exception(ss_()+"Lua "+msg+": "+traceback);
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
		log_v(MODULE, "l_pcall()");
		lua_pushcfunction(L, handle_error);
		int handle_error_stack_i = lua_gettop(L);

		lua_pushvalue(L, 1);
		int r = lua_pcall(L, 0, 0, handle_error_stack_i);
		int error_stack_i = lua_gettop(L);
		if(r == 0){
			log_v(MODULE, "l_pcall() returned 0 (no error)");
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

App* createApp(Polycode::PolycodeView *view)
{
	return new CApp(view);
}

}
