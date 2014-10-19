// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <luabind/luabind.hpp>

#define LUABIND_ENUM_CLASS(X) \
	namespace luabind { \
		template<> struct default_converter<X>: \
			native_converter_base<X> \
		{ \
			static int compute_score(lua_State* L, int index){ \
				return lua_type(L, index) == LUA_TNUMBER ? 0 : -1; \
			} \
			X to_cpp_deferred(lua_State* L, int index){ \
				return X(lua_tonumber(L, index)); \
			} \
			void to_lua_deferred(lua_State* L, X const& x){ \
				lua_pushinteger(L, (int)x); \
			} \
		}; \
		template<> struct default_converter<X const&>: \
			default_converter<X> \
		{}; \
	} \

// vim: set noet ts=4 sw=4:
