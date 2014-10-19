// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/init.h"
#include "core/log.h"
#include "interface/fs.h"
#include <luabind/luabind.hpp>
#include <luabind/class_info.hpp>
#define MODULE "lua_bindings"

namespace lua_bindings {

extern void init_misc(lua_State *L);
extern void init_cereal(lua_State *L);
extern void init_voxel(lua_State *L);
extern void init_atlas(lua_State *L);
extern void init_mesh(lua_State *L);
extern void init_spatial_update_queue(lua_State *L);
extern void init_misc_urho3d(lua_State *L);

void init(lua_State *L)
{
	luabind::open(L);
	luabind::bind_class_info(L);

	init_misc(L);
	init_cereal(L);
	init_voxel(L);
	init_atlas(L);
	init_mesh(L);
	init_spatial_update_queue(L);
	init_misc_urho3d(L);
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:
