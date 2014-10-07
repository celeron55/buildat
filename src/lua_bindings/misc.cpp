// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/fs.h"
#define MODULE "lua_bindings"

namespace lua_bindings {

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

// Like lua_pcall, but returns a full traceback on error
// pcall(function) -> status, error
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

// fatal_error(error: string)
static int l_fatal_error(lua_State *L)
{
	ss_ error = lua_tocppstring(L, 1);
	log_e(MODULE, "Fatal error: %s", cs(error));
	throw Exception("Fatal error from Lua");
	return 0;
}

void init_misc(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(print_log);
	DEF_BUILDAT_FUNC(mkdir)
	DEF_BUILDAT_FUNC(pcall)
	DEF_BUILDAT_FUNC(fatal_error)
}

}	// namespace lua_bindingss
// vim: set noet ts=4 sw=4:
