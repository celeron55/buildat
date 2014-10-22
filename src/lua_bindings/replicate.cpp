// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/replicate.h"
#include "core/log.h"
#include <luabind/luabind.hpp>
#define MODULE "lua_bindings"

namespace lua_bindings {
namespace replicate {

void on_node_created(lua_State *L, uint node_id)
{
	luabind::call_function<void>(L, "__buildat_replicate_on_node_created",
			(uint32_t)node_id);
}

} // namespace replicate
} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
