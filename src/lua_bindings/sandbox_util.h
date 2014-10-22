// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <tolua++.h>

#define GET_TOLUA_STUFF(result_name, index, type){ \
		tolua_Error tolua_err; \
		if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
			tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
			throw Exception("Expected \"" #type "\""); \
		} \
} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);

#define GET_SANDBOX_STUFF(result_name, index, type) \
	lua_getmetatable(L, index); \
	lua_getfield(L, -1, "type_name"); \
	if(!lua_isstring(L, -1) || ss_(lua_tostring(L, -1)) != #type){ \
		lua_pop(L, 2); /* type_name, metatable */ \
		throw Exception("Value is not a sandboxed " #type); \
	} \
	lua_pop(L, 1); /* type_name */ \
	lua_getfield(L, -1, "unsafe"); \
	int top_##result_name##_L = lua_gettop(L); \
	GET_TOLUA_STUFF(result_name, top_##result_name##_L, type); \
	lua_pop(L, 2); /* unsafe, metatable */

#define TRY_GET_SANDBOX_STUFF(result_name, index, type) \
	lua_getmetatable(L, index); \
	lua_getfield(L, -1, "type_name"); \
	type *result_name = nullptr; \
	if(!lua_isstring(L, -1) || ss_(lua_tostring(L, -1)) != #type){ \
		lua_pop(L, 2); /* type_name, metatable */ \
	} else { \
		lua_pop(L, 1); /* type_name */ \
		lua_getfield(L, -1, "unsafe"); \
		int top_L = lua_gettop(L); \
		tolua_Error tolua_err; \
		if(tolua_isusertype(L, top_L, #type, 0, &tolua_err)) \
			result_name = (type*)tolua_tousertype(L, top_L, 0); \
		lua_pop(L, 2); /* unsafe, metatable */ \
	}


// vim: set noet ts=4 sw=4:
