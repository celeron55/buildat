// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/voxel.h"
#include <luabind/luabind.hpp>
#define MODULE "lua_bindings"

using interface::VoxelInstance;
using interface::VoxelRegistry;

namespace lua_bindings {

sp_<VoxelRegistry> createVoxelRegistry(lua_State *L)
{
	return sp_<VoxelRegistry>(
			interface::createVoxelRegistry());
}

void init_voxel(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<VoxelRegistry, bases<>, sp_<VoxelRegistry>>("VoxelRegistry")
			.def("serialize", (ss_(VoxelRegistry::*) ())
					&VoxelRegistry::serialize)
			.def("deserialize", (void(VoxelRegistry::*) (const ss_ &))
					&VoxelRegistry::deserialize),
		def("__buildat_createVoxelRegistry", &createVoxelRegistry)
	];
}

} // namespace lua_bindingss

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
