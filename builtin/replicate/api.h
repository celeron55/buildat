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

namespace replicate
{
	namespace magic = Urho3D;

	struct Interface
	{
	};

	inline bool access(interface::Server *server,
			std::function<void(replicate::Interface*)> cb)
	{
		return server->access_module("replicate", [&](interface::Module *module){
			cb((replicate::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
