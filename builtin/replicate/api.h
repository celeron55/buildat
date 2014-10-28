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

namespace main_context
{
	struct OpaqueSceneReference;
	typedef OpaqueSceneReference* SceneReference;
};

namespace replicate
{
	namespace magic = Urho3D;
	using interface::Event;
	using main_context::SceneReference;

	typedef size_t PeerId;

	struct PeerJoinedScene: public Event::Private
	{
		PeerId peer;
		SceneReference scene;

		PeerJoinedScene(PeerId peer, SceneReference scene):
			peer(peer), scene(scene){}
	};

	struct PeerLeftScene: public Event::Private
	{
		PeerId peer;
		SceneReference scene;

		PeerLeftScene(PeerId peer, SceneReference scene):
			peer(peer), scene(scene){}
	};

	struct Interface
	{
		// Use scene_ref=nullptr to deassign
		virtual void assign_scene_to_peer(
				main_context::SceneReference scene_ref, PeerId peer) = 0;

		virtual sv_<PeerId> find_peers_that_know_node(
				main_context::SceneReference scene_ref, uint node_id) = 0;

		virtual void emit_after_next_sync(Event event) = 0;

		virtual void sync_node_immediate(
				main_context::SceneReference scene_ref, uint node_id) = 0;
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
