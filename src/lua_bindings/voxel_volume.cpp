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
#include <VectorBuffer.h>
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

sp_<CommonVolume> deserialize_volume(
		const luabind::object &buffer_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 1);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	return interface::deserialize_volume(data);
}

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

// Marches rays through a set of chunk volumes and reports what each one ran
// into. This exists because doing it in Lua costs a call per voxel per ray:
// the sky visibility sampler in builtin/voxel_shading was spending half a
// millisecond a frame on 4 rays, and it wants hundreds.
//
// It is deliberately not a sky visibility function. What it answers per ray is
// "what stopped this, and where had it got to", which is as much use for a
// line of sight check or for pointing at a voxel as it is for lighting. What
// counts as passable is the registry's own physically_solid, so a world with
// glass gets glass, and stop_skylight is the one lighting-flavoured thing in
// it: a threshold at which a ray is called done, which is how a caller asks
// "did this get out to open sky" without a second pass.
//
// args (a table):
//   registry       VoxelRegistry, for physically_solid per voxel id
//   chunk_size     {x=,y=,z=} in voxels
//   volumes        array of {x=,y=,z=, volume=}, chunk positions and their
//                  volumes; a ray entering a chunk that is not in here stops
//                  with status "no data"
//   origin         {x=,y=,z=} in voxels; the voxel it is in is not sampled
//   directions     array of {x=,y=,z=}, need not be unit vectors
//   first, count   which of the directions to cast, 1-based (default: all)
//   max_steps      voxels a ray may enter before giving up
//   stop_skylight  optional 1..15; a passable voxel at or above this stops the
//                  ray with status "skylight"
//
// Returns a table of four arrays, each indexed 1..count:
//   status    one of the VoxelRayStatus values below, which the client Lua
//             API exposes as buildat.VOXEL_RAY
//   hit_id    the voxel id that stopped the ray, or 0
//   skylight  skylight of the last passable voxel entered, or -1 for none
//   steps     voxels entered
//
// The march is a DDA over voxel centers, so it enters every voxel the ray
// passes through and cannot step over a wall one voxel thick.
enum VoxelRayStatus {
	VOXEL_RAY_BLOCKED = 0,   // Ran into something not passable
	VOXEL_RAY_NO_DATA = 1,   // Left the volumes it was given
	VOXEL_RAY_RANGE = 2,     // Used up max_steps
	VOXEL_RAY_SKYLIGHT = 3,  // Reached stop_skylight
};

static const int VOXEL_RAY_MAX_STEPS = 4096;
static const size_t VOXEL_RAY_MAX_DIRECTIONS = 8192;

// Chunk position -> volume, for the duration of one call
struct RayVolumeSet
{
	pv::Vector3DInt32 chunk_size;
	// A flat vector rather than a hash: a ray crosses a chunk boundary once
	// every chunk_size voxels and asks again only then, and the one it asked
	// for last is nearly always the one it wants, so the scan behind that is
	// rare enough that its length does not matter
	sv_<std::pair<pv::Vector3DInt32, CommonVolume*>> volumes;
	int last_hit = -1;

	CommonVolume* find(const pv::Vector3DInt32 &chunk_p)
	{
		if(last_hit >= 0 && volumes[last_hit].first == chunk_p)
			return volumes[last_hit].second;
		for(size_t i = 0; i < volumes.size(); i++){
			if(volumes[i].first == chunk_p){
				last_hit = i;
				return volumes[i].second;
			}
		}
		return nullptr;
	}
};

static int floor_div(int a, int b)
{
	int q = a / b;
	if((a % b) != 0 && ((a < 0) != (b < 0)))
		q--;
	return q;
}

static double table_number(const luabind::object &t, const char *key,
		double default_value)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TNUMBER)
		return default_value;
	return luabind::object_cast<double>(v);
}

static pv::Vector3DInt32 table_vector3_int(const luabind::object &t,
		const char *key)
{
	luabind::object v = t[key];
	if(!v || luabind::type(v) != LUA_TTABLE)
		throw Exception(ss_("cast_voxel_rays(): args.") + key +
				" is not a table");
	return pv::Vector3DInt32(
			(int)table_number(v, "x", 0),
			(int)table_number(v, "y", 0),
			(int)table_number(v, "z", 0));
}

luabind::object cast_voxel_rays(const luabind::object &args, lua_State *L)
{
	if(!args || luabind::type(args) != LUA_TTABLE)
		throw Exception("cast_voxel_rays(): args is not a table");

	VoxelRegistry *voxel_reg = nullptr;
	{
		luabind::object o = args["registry"];
		if(o)
			voxel_reg = luabind::object_cast<VoxelRegistry*>(o);
	}
	if(voxel_reg == nullptr)
		throw Exception("cast_voxel_rays(): args.registry is not a registry");

	RayVolumeSet volume_set;
	volume_set.chunk_size = table_vector3_int(args, "chunk_size");
	if(volume_set.chunk_size.getX() <= 0 || volume_set.chunk_size.getY() <= 0 ||
			volume_set.chunk_size.getZ() <= 0)
		throw Exception("cast_voxel_rays(): args.chunk_size is not positive");

	{
		luabind::object volumes_o = args["volumes"];
		if(!volumes_o || luabind::type(volumes_o) != LUA_TTABLE)
			throw Exception("cast_voxel_rays(): args.volumes is not a table");
		for(luabind::iterator it(volumes_o), end; it != end; ++it){
			luabind::object entry = *it;
			if(luabind::type(entry) != LUA_TTABLE)
				continue;
			luabind::object volume_o = entry["volume"];
			if(!volume_o)
				continue;
			sp_<CommonVolume> volume =
					luabind::object_cast<sp_<CommonVolume>>(volume_o);
			if(volume == nullptr)
				continue;
			volume_set.volumes.push_back(std::make_pair(pv::Vector3DInt32(
					(int)table_number(entry, "x", 0),
					(int)table_number(entry, "y", 0),
					(int)table_number(entry, "z", 0)), volume.get()));
		}
	}

	double origin_x = 0.0, origin_y = 0.0, origin_z = 0.0;
	{
		luabind::object o = args["origin"];
		if(!o || luabind::type(o) != LUA_TTABLE)
			throw Exception("cast_voxel_rays(): args.origin is not a table");
		origin_x = table_number(o, "x", 0.0);
		origin_y = table_number(o, "y", 0.0);
		origin_z = table_number(o, "z", 0.0);
	}

	luabind::object directions_o = args["directions"];
	if(!directions_o || luabind::type(directions_o) != LUA_TTABLE)
		throw Exception("cast_voxel_rays(): args.directions is not a table");

	int max_steps = (int)table_number(args, "max_steps", 32);
	if(max_steps < 1)
		max_steps = 1;
	if(max_steps > VOXEL_RAY_MAX_STEPS)
		max_steps = VOXEL_RAY_MAX_STEPS;

	int stop_skylight = (int)table_number(args, "stop_skylight", 0);

	int first = (int)table_number(args, "first", 1);
	if(first < 1)
		first = 1;
	int count = (int)table_number(args, "count", -1);

	// physically_solid per voxel id, filled as ids turn up. Unknown ids stop a
	// ray: an id with no definition is not something to see the sky through.
	sv_<int8_t> solid_cache;

	luabind::object status_t = luabind::newtable(L);
	luabind::object hit_id_t = luabind::newtable(L);
	luabind::object skylight_t = luabind::newtable(L);
	luabind::object steps_t = luabind::newtable(L);

	int out_i = 0;
	for(int di = first; count < 0 || di < first + count; di++){
		luabind::object dir_o = directions_o[di];
		if(!dir_o || luabind::type(dir_o) != LUA_TTABLE)
			break; // End of the array, or the slice asked for runs past it
		if((size_t)out_i >= VOXEL_RAY_MAX_DIRECTIONS)
			break;
		out_i++;

		double dx = table_number(dir_o, "x", 0.0);
		double dy = table_number(dir_o, "y", 0.0);
		double dz = table_number(dir_o, "z", 0.0);
		double len = sqrt(dx * dx + dy * dy + dz * dz);

		int status = VOXEL_RAY_RANGE;
		int hit_id = 0;
		int skylight = -1;
		int steps = 0;

		if(!(len > 1e-9)){
			// A zero or broken direction goes nowhere rather than looping
			status_t[out_i] = VOXEL_RAY_RANGE;
			hit_id_t[out_i] = 0;
			skylight_t[out_i] = -1;
			steps_t[out_i] = 0;
			continue;
		}
		dx /= len; dy /= len; dz /= len;

		// Voxel coordinates are voxel centers, so the boundaries are at half
		// integers; shifting by a half puts them on integers, where a DDA
		// wants them.
		double px = origin_x + 0.5, py = origin_y + 0.5, pz = origin_z + 0.5;
		int vx = (int)floor(px), vy = (int)floor(py), vz = (int)floor(pz);

		int step_x = dx > 0.0 ? 1 : -1;
		int step_y = dy > 0.0 ? 1 : -1;
		int step_z = dz > 0.0 ? 1 : -1;
		// Distance along the ray to the next boundary on each axis, and the
		// distance between boundaries. Infinity for an axis the ray does not
		// move along, which then never comes up as the nearest boundary.
		double huge_d = 1e30;
		double t_delta_x = fabs(dx) > 1e-9 ? 1.0 / fabs(dx) : huge_d;
		double t_delta_y = fabs(dy) > 1e-9 ? 1.0 / fabs(dy) : huge_d;
		double t_delta_z = fabs(dz) > 1e-9 ? 1.0 / fabs(dz) : huge_d;
		double t_max_x = fabs(dx) > 1e-9 ?
				((step_x > 0 ? (vx + 1 - px) : (px - vx)) / fabs(dx)) : huge_d;
		double t_max_y = fabs(dy) > 1e-9 ?
				((step_y > 0 ? (vy + 1 - py) : (py - vy)) / fabs(dy)) : huge_d;
		double t_max_z = fabs(dz) > 1e-9 ?
				((step_z > 0 ? (vz + 1 - pz) : (pz - vz)) / fabs(dz)) : huge_d;

		CommonVolume *volume = nullptr;
		pv::Vector3DInt32 volume_chunk_p(0, 0, 0);
		bool have_volume = false;

		for(int step = 0; step < max_steps; step++){
			// Step into the next voxel first: the one the origin is in is the
			// caller's own and is not what it is asking about
			if(t_max_x < t_max_y && t_max_x < t_max_z){
				vx += step_x;
				t_max_x += t_delta_x;
			} else if(t_max_y < t_max_z){
				vy += step_y;
				t_max_y += t_delta_y;
			} else {
				vz += step_z;
				t_max_z += t_delta_z;
			}
			steps = step + 1;

			pv::Vector3DInt32 chunk_p(
					floor_div(vx, volume_set.chunk_size.getX()),
					floor_div(vy, volume_set.chunk_size.getY()),
					floor_div(vz, volume_set.chunk_size.getZ()));
			if(!have_volume || chunk_p != volume_chunk_p){
				volume = volume_set.find(chunk_p);
				volume_chunk_p = chunk_p;
				have_volume = true;
			}
			if(volume == nullptr){
				status = VOXEL_RAY_NO_DATA;
				break;
			}

			VoxelInstance v = volume->getVoxelAt(
					vx - chunk_p.getX() * volume_set.chunk_size.getX(),
					vy - chunk_p.getY() * volume_set.chunk_size.getY(),
					vz - chunk_p.getZ() * volume_set.chunk_size.getZ());
			interface::VoxelTypeId id = v.get_id();

			if((size_t)id >= solid_cache.size())
				solid_cache.resize((size_t)id + 1, -1);
			int8_t solid = solid_cache[id];
			if(solid < 0){
				const interface::VoxelDefinition *def = voxel_reg->get(id);
				solid = (def == nullptr || def->physically_solid) ? 1 : 0;
				solid_cache[id] = solid;
			}
			if(solid){
				status = VOXEL_RAY_BLOCKED;
				hit_id = id;
				break;
			}

			skylight = v.get_skylight();
			if(stop_skylight > 0 && skylight >= stop_skylight){
				status = VOXEL_RAY_SKYLIGHT;
				break;
			}
		}

		status_t[out_i] = status;
		hit_id_t[out_i] = hit_id;
		skylight_t[out_i] = skylight;
		steps_t[out_i] = steps;
	}

	luabind::object result = luabind::newtable(L);
	result["count"] = out_i;
	result["status"] = status_t;
	result["hit_id"] = hit_id_t;
	result["skylight"] = skylight_t;
	result["steps"] = steps_t;
	return result;
}

// Writes an array of numbers into a VectorBuffer as floats, replacing what was
// in it. One call for the lot: WriteFloat() per value is a sandbox call each,
// and a shader array parameter rebuilt per frame is hundreds of them.
//
// The buffer is what Urho sets as a float array shader parameter once it is in
// a Variant, so this is how a script hands a shader an array.
void write_floats(const luabind::object &buffer_o,
		const luabind::object &values_o, lua_State *L)
{
	TRY_GET_SANDBOX_STUFF(buf, 1, VectorBuffer);
	if(buf == nullptr)
		throw Exception("write_floats(): first argument is not a VectorBuffer");
	if(!values_o || luabind::type(values_o) != LUA_TTABLE)
		throw Exception("write_floats(): second argument is not a table");

	buf->Clear();
	for(size_t i = 1;; i++){
		luabind::object v = values_o[i];
		if(!v || luabind::type(v) != LUA_TNUMBER)
			break;
		buf->WriteFloat((float)luabind::object_cast<double>(v));
	}
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
			.property("id", &VoxelInstance::get_id)
			.property("int32", &voxelinstance_get_int32,
					&voxelinstance_set_int32)
			.def("get_id", &VoxelInstance::get_id)
			.def("get_skylight", &VoxelInstance::get_skylight)
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
		LUABIND_FUNC(deserialize_volume),
		LUABIND_FUNC(deserialize_volume_int32),
		LUABIND_FUNC(deserialize_volume_8bit),
		LUABIND_FUNC(cast_voxel_rays),
		LUABIND_FUNC(write_floats)
	];
}

} // namespace lua_bindingss

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
