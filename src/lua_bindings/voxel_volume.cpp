// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "lua_bindings/util.h"
#include "lua_bindings/sandbox_util.h"
#include "client/app.h"
#include "interface/voxel_volume.h"
#include <c55/os.h>
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <VectorBuffer.h>
#pragma GCC diagnostic pop
#define MODULE "lua_bindings"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;
using interface::VoxelRegistry;
using interface::AtlasRegistry;
using namespace Urho3D;

namespace lua_bindings {

int region_get_x0(const pv::Region &region){
	return region.getLowerCorner().getX();
}
int region_get_y0(const pv::Region &region){
	return region.getLowerCorner().getY();
}
int region_get_z0(const pv::Region &region){
	return region.getLowerCorner().getZ();
}
int region_get_x1(const pv::Region &region){
	return region.getUpperCorner().getX();
}
int region_get_y1(const pv::Region &region){
	return region.getUpperCorner().getY();
}
int region_get_z1(const pv::Region &region){
	return region.getUpperCorner().getZ();
}

// These are supposed to store the value so that negative values will be
// preserved
int32_t voxelinstance_get_int32(const VoxelInstance &v){
	return (int32_t)v.data;
}
void voxelinstance_set_int32(VoxelInstance &v, int32_t d){
	v.data = (uint32_t)d;
}

typedef pv::RawVolume<VoxelInstance> CommonVolume;

sp_<CommonVolume> deserialize_volume_int32(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	up_<pv::RawVolume<int32_t>> volume_int32 =
			interface::deserialize_volume_int32(data);

	auto region = volume_int32->getEnclosingRegion();

	sp_<CommonVolume> volume(new CommonVolume(region));

	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				int32_t v = volume_int32->getVoxelAt(x, y, z);
				//log_w(MODULE, "v=%i", v);
				volume->setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
	}

	return volume;
}

sp_<CommonVolume> deserialize_volume_8bit(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	up_<pv::RawVolume<uint8_t>> volume_8bit =
			interface::deserialize_volume_8bit(data);

	auto region = volume_8bit->getEnclosingRegion();

	sp_<CommonVolume> volume(new CommonVolume(region));

	auto &lc = region.getLowerCorner();
	auto &uc = region.getUpperCorner();
	for(int z = lc.getZ(); z <= uc.getZ(); z++){
		for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				uint8_t v = volume_8bit->getVoxelAt(x, y, z);
				volume->setVoxelAt(x, y, z, VoxelInstance(v));
			}
		}
	}

	return volume;
}

#define LUABIND_FUNC(name) def("__buildat_" #name, name)

void init_voxel_volume(lua_State *L)
{
	using namespace luabind;
	module(L)[
		class_<pv::Region, bases<>, sp_<pv::Region>>("__buildat_Region")
			.def(constructor<int, int, int, int, int ,int>())
			.property("x0", &region_get_x0)
			.property("y0", &region_get_y0)
			.property("z0", &region_get_z0)
			.property("x1", &region_get_x1)
			.property("y1", &region_get_y1)
			.property("z1", &region_get_z1)
		,
		class_<VoxelInstance>("__buildat_VoxelInstance")
			.def(constructor<uint32_t>())
			.def_readwrite("data", &VoxelInstance::data)
			.property("id", &VoxelInstance::getId)
			.property("int32", &voxelinstance_get_int32,
					&voxelinstance_set_int32)
			.def("get_id", &VoxelInstance::getId)
		,
		class_<CommonVolume, bases<>, sp_<CommonVolume>>("__buildat_Volume")
			.def(constructor<const pv::Region &>())
			.def("get_voxel_at", (VoxelInstance (CommonVolume::*)
					(int32_t, int32_t, int32_t) const) &CommonVolume::getVoxelAt)
			.def("set_voxel_at", (bool (CommonVolume::*)
					(int32_t, int32_t, int32_t, VoxelInstance))
					&CommonVolume::setVoxelAt)
			.def("get_enclosing_region", &CommonVolume::getEnclosingRegion)
		,
		LUABIND_FUNC(deserialize_volume_int32),
		LUABIND_FUNC(deserialize_volume_8bit)
	];
}

} // namespace lua_bindingss

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
