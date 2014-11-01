// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
}

namespace ground_plane_lighting
{
	using main_context::SceneReference;

	struct Instance
	{
		virtual void set_yst(int32_t x, int32_t z, int32_t yst) = 0;
		virtual int32_t get_yst(int32_t x, int32_t z) = 0;
	};

	struct Interface
	{
		virtual void create_instance(SceneReference scene_ref) = 0;
		virtual void delete_instance(SceneReference scene_ref) = 0;

		virtual Instance* get_instance(SceneReference scene_ref) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(ground_plane_lighting::Interface*)> cb)
	{
		return server->access_module("ground_plane_lighting",
		[&](interface::Module *module){
			auto *iface = (ground_plane_lighting::Interface*)
					module->check_interface();
			cb(iface);
		});
	}
}

// vim: set noet ts=4 sw=4:
