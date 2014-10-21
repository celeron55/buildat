// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include "core/log.h"
#include "client/app.h"
#include "interface/mesh.h"
#include "interface/voxel_volume.h"
#include "interface/thread_pool.h"
#include <c55/os.h>
#include <tolua++.h>
#include <luabind/luabind.hpp>
#include <luabind/adopt_policy.hpp>
#include <luabind/pointer_traits.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Scene.h>
#include <StaticModel.h>
#include <Model.h>
#include <CustomGeometry.h>
#include <CollisionShape.h>
#include <RigidBody.h>
#pragma GCC diagnostic pop
#define MODULE "lua_bindings"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::VoxelInstance;
using interface::VoxelRegistry;
using interface::AtlasRegistry;
using namespace Urho3D;

namespace lua_bindings {

#define GET_TOLUA_STUFF(result_name, index, type){ \
		tolua_Error tolua_err; \
		if(!tolua_isusertype(L, index, #type, 0, &tolua_err)){ \
			tolua_error(L, __PRETTY_FUNCTION__, &tolua_err); \
			throw Exception("Expected \"" #type "\""); \
		} \
} \
	type *result_name = (type*)tolua_tousertype(L, index, 0);
#define TRY_GET_TOLUA_STUFF(result_name, index, type) \
	type *result_name = nullptr; \
	{ \
		tolua_Error tolua_err; \
		if(tolua_isusertype(L, index, #type, 0, &tolua_err)) \
			result_name = (type*)tolua_tousertype(L, index, 0); \
	}

void set_simple_voxel_model(const luabind::object &node_o,
		int w, int h, int d, const luabind::object &buffer_o)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	TRY_GET_TOLUA_STUFF(buf, 5, const VectorBuffer);

	log_d(MODULE, "set_simple_voxel_model(): node=%p", node);
	log_d(MODULE, "set_simple_voxel_model(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 5);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	if((int)data.size() != w * h * d){
		throw Exception(ss_()+"set_simple_voxel_model(): Data size does not match"
					  " with dimensions ("+cs(data.size())+" vs. "+cs(w*h*d)+")");
	}

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	SharedPtr<Model> fromScratchModel(
			interface::mesh::create_simple_voxel_model(context, w, h, d, data));

	StaticModel *object = node->GetOrCreateComponent<StaticModel>();
	object->SetModel(fromScratchModel);
}

void set_8bit_voxel_geometry(const luabind::object &node_o,
		int w, int h, int d, const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	TRY_GET_TOLUA_STUFF(buf, 5, const VectorBuffer);

	log_d(MODULE, "set_8bit_voxel_geometry(): node=%p", node);
	log_d(MODULE, "set_8bit_voxel_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 5);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	if((int)data.size() != w * h * d){
		throw Exception(ss_()+"set_8bit_voxel_geometry(): Data size does not match"
					  " with dimensions ("+cs(data.size())+" vs. "+cs(w*h*d)+")");
	}

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);
	Context *context = buildat_app->get_scene()->GetContext();

	CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>();

	interface::mesh::set_8bit_voxel_geometry(cg, context, w, h, d, data,
			voxel_reg.get(), atlas_reg.get());

	cg->SetOccluder(true);
	cg->SetCastShadows(true);
}

#ifdef DEBUG_LOG_TIMING
struct ScopeTimer {
	const char *name;
	uint64_t t0;
	ScopeTimer(const char *name = "unknown"): name(name){
		t0 = get_timeofday_us();
	}
	~ScopeTimer(){
		int d = get_timeofday_us() - t0;
		if(d > 3000)
			log_w(MODULE, "%ius (%s)", d, name);
		else
			log_v(MODULE, "%ius (%s)", d, name);
	}
};
#else
struct ScopeTimer {
	ScopeTimer(const char *name = ""){}
};
#endif

struct SetVoxelGeometryTask: public interface::thread_pool::Task
{
	Node *node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;
	sp_<AtlasRegistry> atlas_reg;

	up_<pv::RawVolume<VoxelInstance>> volume;
	sm_<uint, interface::mesh::TemporaryGeometry> temp_geoms;

	SetVoxelGeometryTask(Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg):
		node(node), data(data), voxel_reg(voxel_reg), atlas_reg(atlas_reg)
	{
		ScopeTimer timer("pre geometry");
		// NOTE: Do the pre-processing here so that the calling code can
		//       meaasure how long its execution takes
		// NOTE: Could be split in two calls
		volume = interface::deserialize_volume(data);
		interface::mesh::preload_textures(
				*volume, voxel_reg.get(), atlas_reg.get());
	}
	// Called repeatedly from main thread until returns true
	bool pre()
	{
		return true;
	}
	// Called repeatedly from worker thread until returns true
	bool thread()
	{
		generate_voxel_geometry(
				temp_geoms, *volume, voxel_reg.get(), atlas_reg.get());
		return true;
	}
	// Called repeatedly from main thread until returns true
	bool post()
	{
		ScopeTimer timer("post geometry");
		Context *context = node->GetContext();
		CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>();
		interface::mesh::set_voxel_geometry(
				cg, context, temp_geoms, atlas_reg.get());
		cg->SetOccluder(true);
		cg->SetCastShadows(true);
		return true;
	}
};

struct SetVoxelLodGeometryTask: public interface::thread_pool::Task
{
	int lod;
	Node *node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;
	sp_<AtlasRegistry> atlas_reg;

	up_<pv::RawVolume<VoxelInstance>> lod_volume;
	sm_<uint, interface::mesh::TemporaryGeometry> temp_geoms;

	SetVoxelLodGeometryTask(int lod, Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg):
		lod(lod), node(node), data(data),
		voxel_reg(voxel_reg), atlas_reg(atlas_reg)
	{
		ScopeTimer timer("pre lod geometry");
		// NOTE: Do the pre-processing here so that the calling code can
		//       meaasure how long its execution takes
		// NOTE: Could be split in three calls
		up_<pv::RawVolume<VoxelInstance>> volume_orig =
				interface::deserialize_volume(data);
		lod_volume = interface::mesh::generate_voxel_lod_volume(
				lod, *volume_orig);
		interface::mesh::preload_textures(
				*lod_volume, voxel_reg.get(), atlas_reg.get());
	}
	// Called repeatedly from main thread until returns true
	bool pre()
	{
		return true;
	}
	// Called repeatedly from worker thread until returns true
	bool thread()
	{
		generate_voxel_lod_geometry(
				lod, temp_geoms, *lod_volume, voxel_reg.get(), atlas_reg.get());
		return true;
	}
	// Called repeatedly from main thread until returns true
	bool post()
	{
		ScopeTimer timer("post lod geometry");
		Context *context = node->GetContext();
		CustomGeometry *cg = node->GetOrCreateComponent<CustomGeometry>();
		interface::mesh::set_voxel_lod_geometry(
				lod, cg, context, temp_geoms, atlas_reg.get());
		cg->SetOccluder(true);
		if(lod <= interface::MAX_LOD_WITH_SHADOWS)
			cg->SetCastShadows(true);
		else
			cg->SetCastShadows(false);
		return true;
	}
};

struct SetPhysicsBoxesTask: public interface::thread_pool::Task
{
	Node *node;
	ss_ data;
	sp_<VoxelRegistry> voxel_reg;

	up_<pv::RawVolume<VoxelInstance>> volume;
	sv_<interface::mesh::TemporaryBox> result_boxes;

	SetPhysicsBoxesTask(Node *node, const ss_ &data,
			sp_<VoxelRegistry> voxel_reg):
		node(node), data(data), voxel_reg(voxel_reg)
	{
		// NOTE: Do the pre-processing here so that the calling code can
		//       meaasure how long its execution takes
		// NOTE: Could be split in two calls
		volume = interface::deserialize_volume(data);
	}
	// Called repeatedly from main thread until returns true
	bool pre()
	{
		return true;
	}
	// Called repeatedly from worker thread until returns true
	bool thread()
	{
		interface::mesh::generate_voxel_physics_boxes(
				result_boxes, *volume, voxel_reg.get());
		return true;
	}
	// Called repeatedly from main thread until returns true
	int post_step = 1;
	bool post()
	{
		ScopeTimer timer(
				post_step == 1 ? "post physics 1" :
				post_step == 2 ? "post_physics 2" :
				post_step == 3 ? "post physics 3" :
				"post physics");
		Context *context = node->GetContext();
		switch(post_step){
		case 1:
			node->GetOrCreateComponent<RigidBody>(LOCAL);
			break;
		case 2:
#ifdef DEBUG_LOG_TIMING
			log_v(MODULE, "num boxes: %zu", result_boxes.size());
#endif
			// Times on Dell Precision M6800:
			//   0 boxes ->    30us
			//   1 box   ->   136us
			// 160 boxes ->  7625us (hilly forest)
			// 259 boxes -> 18548us (hilly forest, bad case)
			interface::mesh::set_voxel_physics_boxes(
					node, context, result_boxes, false);
			break;
		case 3:
			// Times on Dell Precision M6800:
			//   0 boxes ->    30us
			//   1 box   ->    64us
			// 160 boxes ->  8419us (hilly forest)
			// 259 boxes -> 15704us (hilly forest, bad case)
			{
				RigidBody *body = node->GetComponent<RigidBody>();
				if(body)
					body->OnSetEnabled();
			}
			return true;
		}
		post_step++;
		return false;
	}
};

void set_voxel_geometry(const luabind::object &node_o,
		const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	log_d(MODULE, "set_voxel_geometry(): node=%p", node);

	TRY_GET_TOLUA_STUFF(buf, 2, const VectorBuffer);
	log_d(MODULE, "set_voxel_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_checkcppstring(L, 2);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetVoxelGeometryTask> task(new SetVoxelGeometryTask(
			node, data, voxel_reg, atlas_reg
	));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void set_voxel_lod_geometry(int lod, const luabind::object &node_o,
		const luabind::object &buffer_o,
		sp_<VoxelRegistry> voxel_reg, sp_<AtlasRegistry> atlas_reg)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 2, Node);
	TRY_GET_TOLUA_STUFF(buf, 3, const VectorBuffer);

	log_d(MODULE, "set_voxel_lod_geometry(): lod=%i", lod);
	log_d(MODULE, "set_voxel_lod_geometry(): node=%p", node);
	log_d(MODULE, "set_voxel_lod_geometry(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 2);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetVoxelLodGeometryTask> task(new SetVoxelLodGeometryTask(
			lod, node, data, voxel_reg, atlas_reg
	));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void clear_voxel_geometry(const luabind::object &node_o)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);

	log_d(MODULE, "clear_voxel_geometry(): node=%p", node);

	CustomGeometry *cg = node->GetComponent<CustomGeometry>();
	if(cg)
		node->RemoveComponent(cg);
}

void set_voxel_physics_boxes(const luabind::object &node_o,
		const luabind::object &buffer_o, sp_<VoxelRegistry> voxel_reg)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);
	TRY_GET_TOLUA_STUFF(buf, 2, const VectorBuffer);

	log_d(MODULE, "set_voxel_physics_boxes(): node=%p", node);
	log_d(MODULE, "set_voxel_physics_boxes(): buf=%p", buf);

	ss_ data;
	if(buf == nullptr)
		data = lua_tocppstring(L, 2);
	else
		data.assign((const char*)&buf->GetBuffer()[0], buf->GetBuffer().Size());

	lua_getfield(L, LUA_REGISTRYINDEX, "__buildat_app");
	app::App *buildat_app = (app::App*)lua_touserdata(L, -1);
	lua_pop(L, 1);

	up_<SetPhysicsBoxesTask> task(new SetPhysicsBoxesTask(
			node, data, voxel_reg
	));

	auto *thread_pool = buildat_app->get_thread_pool();

	thread_pool->add_task(std::move(task));
}

void clear_voxel_physics_boxes(const luabind::object &node_o)
{
	lua_State *L = node_o.interpreter();

	GET_TOLUA_STUFF(node, 1, Node);

	log_d(MODULE, "clear_voxel_physics_boxes(): node=%p", node);

	RigidBody *body = node->GetComponent<RigidBody>();
	if(body)
		node->RemoveComponent(body);

	PODVector<CollisionShape*> previous_shapes;
	node->GetComponents<CollisionShape>(previous_shapes);
	for(size_t i = 0; i < previous_shapes.Size(); i++)
		node->RemoveComponent(previous_shapes[i]);
}

#define LUABIND_FUNC(name) def("__buildat_" #name, name)

void init_mesh(lua_State *L)
{
	using namespace luabind;
	module(L)[
		LUABIND_FUNC(set_simple_voxel_model),
		LUABIND_FUNC(set_8bit_voxel_geometry),
		LUABIND_FUNC(set_voxel_geometry),
		LUABIND_FUNC(set_voxel_lod_geometry),
		LUABIND_FUNC(clear_voxel_geometry),
		LUABIND_FUNC(set_voxel_physics_boxes),
		LUABIND_FUNC(clear_voxel_physics_boxes)
	];
}

} // namespace lua_bindingss


// vim: set noet ts=4 sw=4:
