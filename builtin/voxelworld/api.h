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

namespace voxelworld
{
	namespace magic = Urho3D;
	namespace pv = PolyVox;
	using interface::VoxelInstance;

	struct GenerationRequest: public interface::Event::Private
	{
		pv::Vector3DInt16 section_p;

		GenerationRequest(const pv::Vector3DInt16 &section_p):
			section_p(section_p)
		{}
	};

	struct NodeVoxelDataUpdatedEvent: public interface::Event::Private
	{
		uint node_id;

		NodeVoxelDataUpdatedEvent(uint node_id): node_id(node_id){}
	};

	struct Interface;

	struct CommitHook
	{
		virtual ~CommitHook(){}
		virtual void in_thread(voxelworld::Interface *ivoxelworld,
				const pv::Vector3DInt32 &chunk_p,
				sp_<pv::RawVolume<VoxelInstance>> volume){}
		virtual void in_scene(voxelworld::Interface *ivoxelworld,
				const pv::Vector3DInt32 &chunk_p, magic::Node *n){}
		// TODO: Remove this hook callback and use an event instead
		virtual void after_commit(voxelworld::Interface *ivoxelworld,
				const pv::Vector3DInt32 &chunk_p){}
	};

	struct Interface
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

	inline bool access(interface::Server *server,
			std::function<void(voxelworld::Interface*)> cb)
	{
		return server->access_module("voxelworld", [&](interface::Module *module){
			auto *iface = (voxelworld::Interface*)module->check_interface();
			cb(iface);
			iface->commit();
		});
	}
}

// vim: set noet ts=4 sw=4:
