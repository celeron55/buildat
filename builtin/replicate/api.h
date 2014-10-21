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
	using interface::Event;

	typedef size_t PeerId;

	struct Interface
	{
		virtual sv_<PeerId> find_peers_that_know_node(uint node_id) = 0;

		virtual void emit_after_next_sync(Event event) = 0;

		virtual void sync_node_immediate(uint node_id) = 0;
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
