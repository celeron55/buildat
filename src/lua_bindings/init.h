// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
extern "C" {
#include <lua.h>
}

namespace lua_bindings
{
	void init(lua_State *L);
}
// vim: set noet ts=4 sw=4:
