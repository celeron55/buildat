// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
// TODO: Clean up
#include "interface/voxel.h"
#include <PolyVoxCore/Vector.h>
#include <PolyVoxCore/Region.h>
#include <PolyVoxCore/RawVolume.h>
#include <functional>

// TODO: Clean up
namespace Urho3D
{
	class Context;
	class Scene;
	class Node;
}

namespace ground_plane_lighting
{
	// TODO: Clean up
	namespace magic = Urho3D;
	namespace pv = PolyVox;
	using interface::VoxelInstance;

	struct Interface
	{
		virtual void set_yst(int32_t x, int32_t z, int32_t yst) = 0;
		virtual int32_t get_yst(int32_t x, int32_t z) = 0;
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
