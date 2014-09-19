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
#include <OSBasics.h>
#pragma GCC diagnostic pop
#include <c55/getopt.h>
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

static int debugPrint(lua_State *L)
{
	const char *msg = lua_tostring(L, 1);

	Logger::log(">> %s\n", msg);
	return 0;
}

struct CApp: public Polycode::EventHandler, public App
{
	Polycode::Core *core;
	Polycode::Scene *scene;
	Polycode::SceneLabel *label;
	lua_State *L;
	sp_<client::State> m_state;

	CApp(Polycode::PolycodeView *view):
		Polycode::EventHandler(), core(NULL), scene(NULL), label(NULL), L(NULL)
	{
		// Win32Core for Windows
		// CocoaCore for Mac
		// SDLCore for Linux
		core = new POLYCODE_CORE(view, 640, 480, false, false, 0, 0, 90, 1, true);

		Polycode::CoreServices::getInstance()->getResourceManager()->addArchive(
				g_client_config.share_path+"/client/default.pak");
		Polycode::CoreServices::getInstance()->getResourceManager()->addDirResource("default",
				false);

		scene = new Polycode::Scene(Polycode::Scene::SCENE_2D);
		scene->getActiveCamera()->setOrthoSize(640, 480);
		label = new Polycode::SceneLabel("Hello from Polycode C++!", 32);
		scene->addChild(label);

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

		lua_register(L, "debugPrint", debugPrint);
		lua_register(L, "__customError", handle_error);

		lua_register(L, "__are_same_c_class", areSameCClass);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "class");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Polycode");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Physics2D");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "Physics3D");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "UI");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "tweens");
		lua_call(L, 1, 0);

		lua_getfield(L, LUA_GLOBALSINDEX, "require");
		lua_pushstring(L, "defaults");
		lua_call(L, 1, 0);

		// TODO
		//luaopen_Physics2D(L);
		//luaopen_Physics3D(L);
		//luaopen_UI(L);

		lua_pushlightuserdata(L, (void*)this);
		lua_setfield(L, LUA_REGISTRYINDEX, "__buildat_app");

#define DEF_BUILDAT_FUNC(name){\
	lua_pushcfunction(L, l_##name);\
	lua_setglobal(L, "__buildat_" #name);\
}
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
		delete scene;
		delete label;
		delete core;
		lua_close(L);
	}

	void set_state(sp_<client::State> state)
	{
		m_state = state;
	}

	bool update()
	{
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
		lua_call(L, 1, 1);
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
		lua_call(L, 2, 0);
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
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_key_down");
					lua_pushinteger(L, inputEvent->keyCode());
					lua_pcall(L, 1, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_KEYUP:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_key_up");
					lua_pushinteger(L, inputEvent->keyCode());
					lua_pcall(L, 1, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_MOUSEDOWN:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_mouse_down");
					lua_pushinteger(L, inputEvent->mouseButton);
					lua_pushnumber(L, inputEvent->mousePosition.x);
					lua_pushnumber(L, inputEvent->mousePosition.y);
					lua_pcall(L, 3, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_MOUSEUP:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_mouse_up");
					lua_pushinteger(L, inputEvent->mouseButton);
					lua_pushnumber(L, inputEvent->mousePosition.x);
					lua_pushnumber(L, inputEvent->mousePosition.y);
					lua_pcall(L, 3, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_MOUSEMOVE:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX, "__buildat_mouse_move");
					lua_pushnumber(L, inputEvent->mousePosition.x);
					lua_pushnumber(L, inputEvent->mousePosition.y);
					lua_pcall(L, 2, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_JOYBUTTON_DOWN:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX,
							"__buildat_joystick_button_down");
					lua_pushnumber(L, inputEvent->joystickIndex);
					lua_pushnumber(L, inputEvent->joystickButton);
					lua_pcall(L, 2, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_JOYBUTTON_UP:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX,
							"__buildat_joystick_button_up");
					lua_pushnumber(L, inputEvent->joystickIndex);
					lua_pushnumber(L, inputEvent->joystickButton);
					lua_pcall(L, 2, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			case InputEvent::EVENT_JOYAXIS_MOVED:
				if(L){
					lua_getfield (L, LUA_GLOBALSINDEX, "__customError");
					int errH = lua_gettop(L);
					lua_getfield(L, LUA_GLOBALSINDEX,
							"__buildat_joystick_axis_move");
					lua_pushnumber(L, inputEvent->joystickIndex);
					lua_pushnumber(L, inputEvent->joystickAxis);
					lua_pushnumber(L, inputEvent->joystickAxisValue);
					lua_pcall(L, 3, 2, errH);
					log_if_error();
					lua_settop(L, 0);
				}
				break;
			}
		}
	}

	// Non-public methods

	// send_packet(name: string, data: string)
	static int l_send_packet(lua_State *L)
	{
		size_t name_len = 0;
		const char *name_c = lua_tolstring(L, 1, &name_len);
		ss_ name(name_c, name_len);
		size_t data_len = 0;
		const char *data_c = lua_tolstring(L, 2, &data_len);
		ss_ data(data_c, data_len);

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
		size_t name_len = 0;
		const char *name_c = lua_tolstring(L, 1, &name_len);
		ss_ name(name_c, name_len);

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
		size_t name_len = 0;
		const char *name_c = lua_tolstring(L, 1, &name_len);
		ss_ name(name_c, name_len);

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
		size_t name_len = 0;
		const char *name_c = lua_tolstring(L, 1, &name_len);
		ss_ name(name_c, name_len);

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
		log_v(MODULE, "handle_error()");
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

	// cereal_binary_input(data: string, types: table of strings)
	// -> table of values
	static int l_cereal_binary_input(lua_State *L)
	{
		size_t data_len = 0;
		const char *data_c = lua_tolstring(L, 1, &data_len);
		ss_ data(data_c, data_len);

		int types_table_L = 2;

		lua_newtable(L);
		int result_table_L = lua_gettop(L);

		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);

			int output_index = 1;
			lua_pushnil(L);
			while(lua_next(L, types_table_L) != 0)
			{
				ss_ type = lua_tostring(L, -1);
				lua_pop(L, 1);
				log_t(MODULE, "type=%s", cs(type));
				if(type == "byte"){
					uchar b;
					ar(b);
					lua_pushinteger(L, b);
					lua_rawseti(L, result_table_L, output_index++);
					continue;
				}
				if(type == "int32"){
					int32_t i;
					ar(i);
					lua_pushinteger(L, i);
					lua_rawseti(L, result_table_L, output_index++);
					continue;
				}
				if(type == "double"){
					double d;
					ar(d);
					lua_pushnumber(L, d);
					lua_rawseti(L, result_table_L, output_index++);
					continue;
				}
				if(type == "string"){
					ss_ s;
					ar(s);
					lua_pushlstring(L, s.c_str(), s.size());
					lua_rawseti(L, result_table_L, output_index++);
					continue;
				}
				throw Exception(ss_()+"Unknown type \""+type+"\""
						"; known types are byte, int32, double, string");
			}
		}
		// Result table is on top of stack
		return 1;
	}

	// cereal_binary_output(values: table of values, types: table of strings)
	// -> data
	static int l_cereal_binary_output(lua_State *L)
	{
		int values_table_L = 1;

		int types_table_L = 2;

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);

			int value_index = 1;
			lua_pushnil(L);
			while(lua_next(L, types_table_L) != 0)
			{
				ss_ type = lua_tostring(L, -1);
				lua_pop(L, 1);
				log_t(MODULE, "type=%s", cs(type));
				if(type == "byte"){
					lua_rawgeti(L, values_table_L, value_index++);
					uchar b = lua_tointeger(L, -1);
					lua_pop(L, 1);
					ar(b);
					continue;
				}
				if(type == "int32"){
					lua_rawgeti(L, values_table_L, value_index++);
					int32_t i = lua_tointeger(L, -1);
					lua_pop(L, 1);
					ar(i);
					continue;
				}
				if(type == "double"){
					lua_rawgeti(L, values_table_L, value_index++);
					double d = lua_tonumber(L, -1);
					lua_pop(L, 1);
					ar(d);
					continue;
				}
				if(type == "string"){
					lua_rawgeti(L, values_table_L, value_index++);
					size_t cs_len = 0;
					const char *cs = lua_tolstring(L, -1, &cs_len);
					lua_pop(L, 1);
					ss_ s(cs, cs_len);
					ar(s);
					continue;
				}
				throw Exception(ss_()+"Unknown type \""+type+"\""
						"; known types are byte, int32, double, string");
			}
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
