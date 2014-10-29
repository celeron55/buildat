// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/Region.h>
#include <PolyVoxCore/RawVolume.h>
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
	class Node;
}

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
};

namespace voxelworld
{
	namespace magic = Urho3D;
	namespace pv = PolyVox;
	using interface::VoxelInstance;
	using main_context::SceneReference;

	struct GenerationRequest: public interface::Event::Private
	{
		SceneReference scene;
		pv::Vector3DInt16 section_p;

		GenerationRequest(SceneReference scene,
				const pv::Vector3DInt16 &section_p):
			scene(scene),
			section_p(section_p)
		{}
	};

	struct NodeVolumeUpdated: public interface::Event::Private
	{
		SceneReference scene;
		uint node_id;
		bool is_static_chunk = false;
		pv::Vector3DInt32 chunk_p; // Only set if is_static_chunk == true

		NodeVolumeUpdated(SceneReference scene, uint node_id,
				bool is_static_chunk, const pv::Vector3DInt32 &chunk_p):
			scene(scene), node_id(node_id),
			is_static_chunk(is_static_chunk), chunk_p(chunk_p)
		{}
	};

	struct Instance;

	struct CommitHook
	{
		virtual ~CommitHook(){}
		virtual void in_thread(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p,
				pv::RawVolume<VoxelInstance> &volume){}
		virtual void in_scene(voxelworld::Instance *world,
				const pv::Vector3DInt32 &chunk_p, magic::Node *n){}
	};

	struct Instance
	{
		virtual interface::VoxelRegistry* get_voxel_reg() = 0;

		virtual void add_commit_hook(up_<CommitHook> hook) = 0;

		virtual pv::Vector3DInt16 get_section_size_voxels() = 0;

		virtual pv::Region get_section_region_voxels(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual const pv::Vector3DInt16& get_chunk_size_voxels() = 0;

		virtual pv::Region get_chunk_region_voxels(
				const pv::Vector3DInt32 &chunk_p) = 0;

		virtual void load_or_generate_section(
				const pv::Vector3DInt16 &section_p) = 0;

		virtual void set_voxel(const pv::Vector3DInt32 &p,
				const VoxelInstance &v,
				bool disable_warnings = false) = 0;

		virtual size_t num_buffers_loaded() = 0;

		virtual void commit() = 0;

		virtual VoxelInstance get_voxel(const pv::Vector3DInt32 &p,
				bool disable_warnings = false) = 0;

		// NOTE: There is no interface in here for directly accessing chunk
		// volumes of static nodes, because it is so much more hassly and was
		// tested to improve speed only by 53% compared to the current very
		// robust interface.
	};

	struct Interface
	{
		virtual void create_instance(SceneReference scene_ref,
				const pv::Region &region) = 0;
		virtual void delete_instance(SceneReference scene_ref) = 0;

		virtual Instance* get_instance(SceneReference scene_ref) = 0;

		virtual void commit() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(voxelworld::Interface*)> cb)
	{
		return server->access_module("voxelworld", [&](interface::Module *module){
			auto *iface = (voxelworld::Interface*)module->check_interface();
			cb(iface);
			iface->commit();
		});
	}

	inline bool access(interface::Server *server, SceneReference scene_ref,
			std::function<void(voxelworld::Instance *instance)> cb)
	{
		return access(server, [&](voxelworld::Interface *i){
			voxelworld::Instance *instance = check(i->get_instance(scene_ref));
			cb(instance);
		});
	}
}

// vim: set noet ts=4 sw=4:
