// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace Urho3D
{
	class Context;
	class Scene;
}

namespace voxelworld
{
	namespace magic = Urho3D;

	struct Interface
	{
	};

	inline bool access(interface::Server *server,
			std::function<void(voxelworld::Interface*)> cb)
	{
		return server->access_module("voxelworld", [&](interface::Module *module){
			cb((voxelworld::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
