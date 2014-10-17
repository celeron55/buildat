// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#define MODULE "lua_bindings"

namespace lua_bindings {

sv_<ss_> dump_stack(lua_State *L)
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

ss_ lua_tocppstring(lua_State *L, int index)
{
	if(!lua_isstring(L, index))
		throw Exception(ss_()+"lua_tocppstring: Expected string, got "+
					  lua_typename(L, index));
	size_t length;
	const char *s = lua_tolstring(L, index, &length);
	return ss_(s, length);
}

ss_ lua_checkcppstring(lua_State *L, int index)
{
	return lua_tocppstring(L, index);
}

int handle_error(lua_State *L)
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

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
