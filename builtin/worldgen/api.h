// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "interface/voxel.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/RawVolume.h>
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace worldgen
{
	namespace pv = PolyVox;
	using main_context::SceneReference;

	struct QueueModifiedEvent: public interface::Event::Private
	{
		SceneReference scene;
		size_t queue_size;

		QueueModifiedEvent(SceneReference scene, size_t queue_size):
			scene(scene), queue_size(queue_size)
		{}
	};

	struct GeneratorInterface
	{
		virtual ~GeneratorInterface(){}

		// How far outside the section a single generated thing can reach. A
		// tree grown at the edge of a section stands partly in the next one,
		// and the volume handed to generate() is the section grown by this
		// much on every side so that the whole tree can be placed at once.
		virtual pv::Vector3DInt32 get_padding_voxels()
		{
			return pv::Vector3DInt32(0, 0, 0);
		}

		// Fill the volume over the whole of its region, which is the section
		// plus the padding above.
		//
		// This runs in a worker thread with no module held, so that
		// generation does not keep voxelworld from anything else: nothing in
		// here may access another module. The result is merged into the world
		// afterwards, and a voxel left VOXELTYPEID_UNDEFINED is left to
		// whatever generates the section it belongs to.
		virtual void generate(SceneReference scene_ref,
				const pv::Vector3DInt16 &section_p,
				pv::RawVolume<interface::VoxelInstance> &volume) = 0;
	};

	struct Instance
	{
		virtual void set_generator(GeneratorInterface *generator) = 0;
		virtual void enable() = 0;
		virtual size_t get_num_sections_queued() = 0;
	};

	struct Interface
	{
		virtual void create_instance(SceneReference scene_ref) = 0;
		virtual void delete_instance(SceneReference scene_ref) = 0;

		virtual Instance* get_instance(SceneReference scene_ref) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(worldgen::Interface*)> cb)
	{
		return server->access_module("worldgen", [&](interface::Module *module){
			cb((worldgen::Interface*)module->check_interface());
		});
	}

	inline bool access(interface::Server *server, SceneReference scene_ref,
			std::function<void(worldgen::Instance*instance)> cb)
	{
		return access(server, [&](worldgen::Interface *i){
			worldgen::Instance *instance =
					check(i->get_instance(scene_ref));
			cb(instance);
		});
	}
}


// vim: set noet ts=4 sw=4:
