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
#include <core/log.h>
#include <signal.h>
#define MODULE "__main"

using Polycode::SDLCore;
using Polycode::Logger;
using Polycode::String;

extern client::Config g_client_config;

namespace app {

int MyLoader(lua_State *pState)
{
	// TODO: Security
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

static int customError(lua_State *L){

	//PolycodePlayer *player = (PolycodePlayer*)CoreServices::getInstance()->getCore()->getUserPointer();
	//player->crashed = true;

	std::vector<BackTraceEntry> backTrace;
	lua_Debug entry;
	int depth = 0;
	while(lua_getstack(L, depth, &entry)){
		lua_getinfo(L, "Sln", &entry);
		std::vector<String> bits = String(entry.short_src).split("\"");
		if(bits.size() > 1){
			String fileName = bits[1];
			if(fileName != "class.lua"){

				BackTraceEntry trace;
				trace.lineNumber = entry.currentline;
				trace.fileName = fileName;
				backTrace.push_back(trace);

				//printf(">>>> In file: %s on line %d\n", fileName.c_str(), trace.lineNumber);
				//backTrace += "In file: "+fileName+" on line "+String::IntToString(entry.currentline)+"\n";
			}
		}
		depth++;
	}

	// horrible hack to determine the filenames of things
	bool stringThatIsTheMainFileSet = false;
	String stringThatIsTheMainFile;

	if(backTrace.size() == 0){

		BackTraceEntry trace;
		trace.lineNumber = 0;
		//trace.fileName = player->fullPath;
		backTrace.push_back(trace);

	} else {
		stringThatIsTheMainFileSet = true;
		stringThatIsTheMainFile = backTrace[backTrace.size() - 1].fileName;
		//backTrace[backTrace.size()-1].fileName = player->fullPath;
	}

	if(stringThatIsTheMainFileSet){
		for(size_t i = 0; i < backTrace.size(); i++){
			if(backTrace[i].fileName == stringThatIsTheMainFile){
				//backTrace[i].fileName = player->fullPath;
			}
		}
	}

	const char *msg = lua_tostring(L, -1);
	if(msg == NULL) msg = "(error with no message)";
	lua_pop(L, 1);

	printf("\n%s\n", msg);

	String errorString;
	std::vector<String> info = String(msg).split(":");

	if(info.size() > 2){
		errorString = info[2];
	} else {
		errorString = msg;
	}

	printf("\n---------------------\n");
	printf("Error: %s\n", errorString.c_str());
	printf("In file: %s\n", backTrace[0].fileName.c_str());
	printf("On line: %d\n", backTrace[0].lineNumber);
	printf("---------------------\n");
	printf("Backtrace\n");
	for(size_t i = 0; i < backTrace.size(); i++){
		printf("* %s on line %d", backTrace[i].fileName.c_str(),
				backTrace[i].lineNumber);
	}
	printf("\n---------------------\n");

	return 0;
}

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
		lua_register(L, "__customError", customError);

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

		ss_ init_lua_path = g_client_config.share_path+"/client/init.lua";
		int error = luaL_dofile(L, init_lua_path.c_str());
		if(error){
			log_w(MODULE, "luaL_dofile: An error occurred: %s\n",
					lua_tostring(L, -1));
			lua_pop(L, 1);
		}
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
};

App* createApp(Polycode::PolycodeView *view)
{
	return new CApp(view);
}

}
