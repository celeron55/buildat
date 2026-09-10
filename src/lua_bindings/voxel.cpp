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

luabind::object vdef_get_tile_turns(const VoxelDefinition &def, lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < 6; i++)
		result[i+1] = luabind::object(L, (int)def.tile_turns[i]);
	return result;
}

void vdef_set_tile_turns(VoxelDefinition &def, luabind::object value,
		lua_State *L)
{
	for(size_t i = 0; i < 6; i++){
		luabind::object v = value[i+1];
		def.tile_turns[i] = v && luabind::type(v) == LUA_TNUMBER ?
				(uint8_t)(luabind::object_cast<int>(v) & 3) : 0;
	}
}

// vdef.shape: an array of quads, each
//   {tile = 1...6,
//    p = {x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3},
//    uv = {u0,v0, u1,v1, u2,v2, u3,v3}}
// The corners are in the voxel's own cube of -0.5...0.5 and the texture
// coordinates in the tile's own 0...1; see interface/voxel.h.
static luabind::object vdef_get_shape(const VoxelDefinition &def,
		lua_State *L)
{
	luabind::object result = luabind::newtable(L);
	for(size_t i = 0; i < def.shape.size(); i++){
		const interface::VoxelQuad &q = def.shape[i];
		luabind::object quad = luabind::newtable(L);
		quad["tile"] = (int)q.tile + 1;
		luabind::object p = luabind::newtable(L);
		luabind::object uv = luabind::newtable(L);
		for(int c = 0; c < 4; c++){
			for(int a = 0; a < 3; a++)
				p[c * 3 + a + 1] = q.p[c][a];
			for(int a = 0; a < 2; a++)
				uv[c * 2 + a + 1] = q.uv[c][a];
		}
		quad["p"] = p;
		quad["uv"] = uv;
		result[i + 1] = quad;
	}
	return result;
}

static double quad_number(const luabind::object &t, int index)
{
	luabind::object v = t[index];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		throw Exception(ss_()+"VoxelDefinition.shape: entry "+itos(index)+
				" is not a number");
	return luabind::object_cast<double>(v);
}

static void vdef_set_shape(VoxelDefinition &def, const luabind::object &value)
{
	def.shape.clear();
	if(!value || luabind::type(value) != LUA_TTABLE)
		return;
	for(luabind::iterator it(value), end; it != end; ++it){
		luabind::object quad = *it;
		if(luabind::type(quad) != LUA_TTABLE)
			throw Exception("VoxelDefinition.shape: a quad is not a table");
		luabind::object p = quad["p"];
		luabind::object uv = quad["uv"];
		if(!p || luabind::type(p) != LUA_TTABLE ||
				!uv || luabind::type(uv) != LUA_TTABLE)
			throw Exception("VoxelDefinition.shape: a quad wants p and uv");
		interface::VoxelQuad q;
		luabind::object tile = quad["tile"];
		int tile_i = (tile && luabind::type(tile) == LUA_TNUMBER) ?
				(int)luabind::object_cast<double>(tile) : 1;
		if(tile_i < 1 || tile_i > 6)
			throw Exception(ss_()+"VoxelDefinition.shape: tile "+
					itos(tile_i)+" is not one of the six");
		q.tile = (uint8_t)(tile_i - 1);
		for(int c = 0; c < 4; c++){
			for(int a = 0; a < 3; a++)
				q.p[c][a] = (float)quad_number(p, c * 3 + a + 1);
			for(int a = 0; a < 2; a++)
				q.uv[c][a] = (float)quad_number(uv, c * 2 + a + 1);
		}
		def.shape.push_back(q);
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
			.def_readwrite("roughness", &AtlasSegmentDefinition::roughness)
			.def_readwrite("spec_strength",
					&AtlasSegmentDefinition::spec_strength)
			.def_readwrite("bumpiness", &AtlasSegmentDefinition::bumpiness)
			.def_readwrite("translucency",
					&AtlasSegmentDefinition::translucency)
			.def_readwrite("spots", &AtlasSegmentDefinition::spots)
.def_readwrite("static_spots", &AtlasSegmentDefinition::static_spots)
		,
		class_<VoxelDefinition, bases<>, sp_<VoxelDefinition>>(
				"__buildat_VoxelDefinition")
			.def(constructor<>())
			.def_readwrite("name", &VoxelDefinition::name)
			.def_readwrite("id", &VoxelDefinition::id)
			.property("textures", &vdef_get_textures, &vdef_set_textures)
			.property("tile_turns", &vdef_get_tile_turns,
					&vdef_set_tile_turns)
			.def_readwrite("face_draw_type", &VoxelDefinition::face_draw_type)
			.def_readwrite("edge_material_id", &VoxelDefinition::edge_material_id)
			.def_readwrite("physically_solid", &VoxelDefinition::physically_solid)
			.def_readwrite("fully_empty", &VoxelDefinition::fully_empty)
			.property("shape", &vdef_get_shape, &vdef_set_shape)
			.def_readwrite("shape_double_sided",
					&VoxelDefinition::shape_double_sided)
			.def_readwrite("translucent", &VoxelDefinition::translucent)
			.def_readwrite("shape_group", &VoxelDefinition::shape_group)
			.def_readwrite("is_liquid", &VoxelDefinition::is_liquid)
			.def_readwrite("liquid_top", &VoxelDefinition::liquid_top)
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
