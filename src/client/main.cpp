#include "client/config.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
	#include <Polycode.h>
	#include <PolycodeView.h>
	#include <PolycodeLUA.h>
	#include <OSBasics.h>
#pragma GCC diagnostic pop
#include <c55_getopt.h>

using Polycode::PolycodeView;
using Polycode::SDLCore;
using Polycode::Logger;
using Polycode::String;

client::Config g_config;

int MyLoader(lua_State* pState)
{
	// TODO: Security
	std::string module = lua_tostring(pState, 1);

	module += ".lua";
	//Logger::log("Loading custom class: %s\n", module.c_str());

	std::vector<std::string> defaultPaths = {
		g_config.polycode_path+"/Bindings/Contents/LUA/API/",
		g_config.polycode_path+"/Modules/Bindings/2DPhysics/API/",
		g_config.polycode_path+"/Modules/Bindings/3DPhysics/API/",
		g_config.polycode_path+"/Modules/Bindings/UI/API/",
	};

	for(std::string defaultPath : defaultPaths){
		defaultPath.append(module);

		const char* fullPath = module.c_str();		

		OSFILE *inFile = OSBasics::open(module, "r");	
		
		if(!inFile) {
			inFile =  OSBasics::open(defaultPath, "r");	
		}
		
		if(inFile) {
			OSBasics::seek(inFile, 0, SEEK_END);	
			long progsize = OSBasics::tell(inFile);
			OSBasics::seek(inFile, 0, SEEK_SET);
			char *buffer = (char*)malloc(progsize+1);
			memset(buffer, 0, progsize+1);
			OSBasics::read(buffer, progsize, 1, inFile);
			luaL_loadbuffer(pState, (const char*)buffer, progsize, fullPath);
			free(buffer);
			OSBasics::close(inFile);
			return 1;
		}
	}
	std::string err = "\n\tError - Could could not find ";
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

static int customError(lua_State *L) {
	
	//PolycodePlayer *player = (PolycodePlayer*)CoreServices::getInstance()->getCore()->getUserPointer();		
	//player->crashed = true;
	
	std::vector<BackTraceEntry> backTrace;
	lua_Debug entry;
	int depth = 0;		
	while (lua_getstack(L, depth, &entry)) {
		lua_getinfo(L, "Sln", &entry);
		std::vector<String> bits = String(entry.short_src).split("\"");
		if(bits.size() > 1) {
			String fileName = bits[1];
			if(fileName != "class.lua") {
				
				BackTraceEntry trace;
				trace.lineNumber = entry.currentline;
				trace.fileName = fileName;
				backTrace.push_back(trace);
				
				//printf(">>>> In file: %s on line %d\n", fileName.c_str(), trace.lineNumber);
				//backTrace += "In file: " + fileName + " on line " + String::IntToString(entry.currentline)+"\n";
			}
		}
		depth++;
	}

	// horrible hack to determine the filenames of things
	bool stringThatIsTheMainFileSet = false;
	String stringThatIsTheMainFile;
	
	if(backTrace.size() == 0) {
				
				BackTraceEntry trace;
				trace.lineNumber = 0;
				//trace.fileName = player->fullPath;
				backTrace.push_back(trace);
	
	} else {
		stringThatIsTheMainFileSet = true;
		stringThatIsTheMainFile = backTrace[backTrace.size()-1].fileName;
		//backTrace[backTrace.size()-1].fileName = player->fullPath;
	}
	
	if(stringThatIsTheMainFileSet) {
		for(size_t i=0; i < backTrace.size(); i++) {
			if(backTrace[i].fileName == stringThatIsTheMainFile) {
				//backTrace[i].fileName = player->fullPath;
			}
		}
	}
	
	const char *msg = lua_tostring(L, -1);		
	if (msg == NULL) msg = "(error with no message)";
	lua_pop(L, 1);
	
	printf("\n%s\n", msg);
	
	String errorString;
	std::vector<String> info = String(msg).split(":");
		
	if(info.size() > 2) {
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
	for(size_t i=0; i < backTrace.size(); i++) {
		printf("* %s on line %d", backTrace[i].fileName.c_str(), backTrace[i].lineNumber);
	}
	printf("\n---------------------\n");
			
	return 0;
}

static int areSameCClass(lua_State *L) {
	luaL_checktype(L, 1, LUA_TUSERDATA);
	PolyBase *classOne = *((PolyBase**)lua_touserdata(L, 1));
	luaL_checktype(L, 2, LUA_TUSERDATA);
	PolyBase *classTwo = *((PolyBase**)lua_touserdata(L, 2));
	
	if(classOne == classTwo) {
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

class HelloPolycodeApp : public Polycode::EventHandler {
public:
	HelloPolycodeApp(Polycode::PolycodeView *view);
	~HelloPolycodeApp();
	bool Update();

private:
	Polycode::Core *core;
	Polycode::Scene *scene;
	Polycode::SceneLabel *label;
	lua_State *L;
};

HelloPolycodeApp::HelloPolycodeApp(Polycode::PolycodeView *view):
		Polycode::EventHandler(), core(NULL), scene(NULL), label(NULL), L(NULL)
{
	// Win32Core for Windows
	// CocoaCore for Mac
	// SDLCore for Linux
	core = new POLYCODE_CORE(view, 640,480,false,false,0,0,90, 1, true);

	Polycode::CoreServices::getInstance()->getResourceManager()->addArchive(g_config.share_path+"/default.pak");
	Polycode::CoreServices::getInstance()->getResourceManager()->addDirResource("default", false);

	scene = new Polycode::Scene(Polycode::Scene::SCENE_2D);
	scene->getActiveCamera()->setOrthoSize(640, 480);
	label = new Polycode::SceneLabel("Hello, Polycode!", 32);
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
	while (lua_next(L, -2) != 0) 
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

	//luaopen_Physics2D(L);
	//luaopen_Physics3D(L);
	//luaopen_UI(L);

	int error = luaL_dofile(L, (g_config.share_path+"/init.lua").c_str());
	if(error){
		Logger::log("luaL_dofile: An error occurred: %s\n", lua_tostring(L, -1));
		lua_pop(L, 1);
	}
}

HelloPolycodeApp::~HelloPolycodeApp() {
	delete scene;
	delete label;
	delete core;
	lua_close(L);
}

bool HelloPolycodeApp::Update() {
	return core->updateAndRender();
}

int main(int argc, char *argv[])
{
	client::Config &config = g_config;

	const char opts[100] = "hs:p:P:";
	const char usagefmt[1000] =
	"Usage: %s [OPTION]...\n"
	"  -h                   Show this help\n"
	"  -s [address]         Specify server address\n"
	"  -p [polycode_path]   Specify polycode path\n"
	"  -P [share_path]      Specify share/ path\n"
	;

	int c;
	while((c = c55_getopt(argc, argv, opts)) != -1)
	{  
		switch(c)
		{
		case 'h':
			printf(usagefmt, argv[0]);
			return 1;
		case 's':
			fprintf(stderr, "INFO: config.server_address: %s\n", c55_optarg);
			config.server_address = c55_optarg;
			break;
		case 'p':
			fprintf(stderr, "INFO: config.polycode_path: %s\n", c55_optarg);
			config.polycode_path = c55_optarg;
			break;
		case 'P':
			fprintf(stderr, "INFO: config.share_path: %s\n", c55_optarg);
			config.share_path = c55_optarg;
			break;
		default:
			fprintf(stderr, "ERROR: Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	PolycodeView *view = new PolycodeView("Hello Polycode!");
	HelloPolycodeApp *app = new HelloPolycodeApp(view);
	while(app->Update());
	return 0;
}
