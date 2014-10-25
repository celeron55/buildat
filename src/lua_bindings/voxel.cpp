// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/voxel.h"
#include "lua_bindings/util.h"
#include "lua_bindings/luabind_util.h"
#include "lua_bindings/sandbox_util.h"
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/object.hpp>
#include <tolua++.h>
#include <Vector2.h>
#define MODULE "lua_bindings"

using namespace interface;
using Urho3D::IntVector2;

LUABIND_ENUM_CLASS(FaceDrawType);

namespace lua_bindings {

luabind::object asd_get_total_segments(
		const AtlasSegmentDefinition &def, lua_State *L)
{
	// TODO
	return luabind::object();
}

void asd_set_total_segments(
		AtlasSegmentDefinition &def, luabind::object value_safe, lua_State *L)
{
	GET_SANDBOX_STUFF(v, 2, IntVector2);
	def.total_segments = *v;
}

luabind::object asd_get_select_segment(
		const AtlasSegmentDefinition &def, lua_State *L)
{
	// TODO
	return luabind::object();
}

void asd_set_select_segment(
		AtlasSegmentDefinition &def, luabind::object value, lua_State *L)
{
	GET_SANDBOX_STUFF(v, 2, IntVector2);
	def.select_segment = *v;
}

luabind::object vdef_get_textures(const VoxelDefinition &def, lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < 6; i++){
		result[i+1] = luabind::object(L, def.textures[i]);
	}
	return result;
}

void vdef_set_textures(VoxelDefinition &def, luabind::object value, lua_State *L)
{
	for(size_t i = 0; i < 6; i++){
		def.textures[i] = luabind::object_cast<AtlasSegmentDefinition>(
				value[i+1]);
	}
}

sp_<VoxelRegistry> createVoxelRegistry(lua_State *L)
{
	return sp_<VoxelRegistry>(
			interface::createVoxelRegistry());
}

void init_voxel(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<VoxelName, bases<>, sp_<VoxelName>>("__buildat_VoxelName")
			.def(constructor<>())
			.def_readwrite("block_name", &VoxelName::block_name)
			.def_readwrite("segment_x", &VoxelName::segment_x)
			.def_readwrite("segment_y", &VoxelName::segment_y)
			.def_readwrite("segment_z", &VoxelName::segment_z)
			.def_readwrite("rotation_primary", &VoxelName::rotation_primary)
			.def_readwrite("rotation_secondary", &VoxelName::rotation_secondary)
		,
		class_<AtlasSegmentDefinition, bases<>, sp_<AtlasSegmentDefinition>>(
				"__buildat_AtlasSegmentDefinition")
			.def(constructor<>())
			.def_readwrite("resource_name",
					&AtlasSegmentDefinition::resource_name)
			.property("total_segments",
					&asd_get_total_segments, &asd_set_total_segments)
			.property("select_segment",
					&asd_get_select_segment, &asd_set_select_segment)
			.def_readwrite("lod_simulation",
					&AtlasSegmentDefinition::lod_simulation)
		,
		class_<VoxelDefinition, bases<>, sp_<VoxelDefinition>>(
				"__buildat_VoxelDefinition")
			.def(constructor<>())
			.def_readwrite("name", &VoxelDefinition::name)
			.def_readwrite("id", &VoxelDefinition::id)
			.property("textures", &vdef_get_textures, &vdef_set_textures)
			.def_readwrite("face_draw_type", &VoxelDefinition::face_draw_type)
			.def_readwrite("edge_material_id", &VoxelDefinition::edge_material_id)
			.def_readwrite("physically_solid", &VoxelDefinition::physically_solid)
			.enum_("FaceDrawType")[
				value("FACEDRAWTYPE_NEVER", (int)FaceDrawType::NEVER),
				value("FACEDRAWTYPE_ALWAYS", (int)FaceDrawType::ALWAYS),
				value("FACEDRAWTYPE_ON_EDGE", (int)FaceDrawType::ON_EDGE)
			]
			.enum_("EdgeMaterialId")[
				value("EDGEMATERIALID_EMPTY", EDGEMATERIALID_EMPTY),
				value("EDGEMATERIALID_GROUND", EDGEMATERIALID_GROUND)
			]
		,
		class_<VoxelRegistry, bases<>, sp_<VoxelRegistry>>("VoxelRegistry")
			.def("add_voxel", &VoxelRegistry::add_voxel)
			.def("get_by_id", (const VoxelDefinition*(VoxelRegistry::*)
					(const VoxelTypeId&)) &VoxelRegistry::get)
			.def("get_by_name", (const VoxelDefinition*(VoxelRegistry::*)
					(const VoxelName&)) &VoxelRegistry::get)
			.def("serialize", (ss_(VoxelRegistry::*) ())
					&VoxelRegistry::serialize)
			.def("deserialize", (void(VoxelRegistry::*) (const ss_ &))
					&VoxelRegistry::deserialize)
		,
		def("__buildat_createVoxelRegistry", &createVoxelRegistry)
	];
}

} // namespace lua_bindingss

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
