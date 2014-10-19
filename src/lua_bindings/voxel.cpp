// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/voxel.h"
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#define MODULE "lua_bindings"

#define DEF_METHOD(name){ \
		lua_pushcfunction(L, l_##name); \
		lua_setfield(L, -2, #name); \
}

using interface::VoxelInstance;
using interface::VoxelRegistry;

namespace lua_bindings {

void init_voxel(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<VoxelRegistry, bases<>, sp_<VoxelRegistry>>("VoxelRegistry")
			.def("serialize", (ss_(VoxelRegistry::*)())
					&VoxelRegistry::serialize)
			.def("deserialize", (void(VoxelRegistry::*)(const ss_&))
					&VoxelRegistry::deserialize),
		def("createVoxelRegistry", &interface::createVoxelRegistry,
				adopt_policy<0>())
	];
}

} // namespace lua_bindingss

// vim: set noet ts=4 sw=4:
