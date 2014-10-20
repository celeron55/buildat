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
	if(ss_(lua_tostring(L, -1)) != #type){ \
		lua_pop(L, 2); /* type_name, metatable */ \
		throw Exception("Value is not a sandboxed " #type); \
	} \
	lua_pop(L, 1); /* type_name */ \
	lua_getfield(L, -1, "unsafe"); \
	int top_##name##_L = lua_gettop(L); \
	GET_TOLUA_STUFF(result_name, top_##name##_L, type); \
	lua_pop(L, 2); /* unsafe, metatable */

// vim: set noet ts=4 sw=4:

