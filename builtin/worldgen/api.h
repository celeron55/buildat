// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <PolyVoxCore/Vector.h>
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
};

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
		virtual void generate_section(interface::Server *server,
				SceneReference scene_ref, const pv::Vector3DInt16 &section_p) = 0;
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
			std::function<void(worldgen::Instance *instance)> cb)
	{
		return access(server, [&](worldgen::Interface *i){
			worldgen::Instance *instance = check(i->get_instance(scene_ref));
			cb(instance);
		});
	}
}

// vim: set noet ts=4 sw=4:

