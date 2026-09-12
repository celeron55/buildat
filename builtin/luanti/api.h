// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
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

namespace luanti
{
	using main_context::SceneReference;

	// The game's mods have loaded, the voxel registry is built and the map
	// exists. The scene is the module's own: it is what knows the world's
	// node ids and its light, so it is what owns them, and this is how
	// whoever started the game finds out where to put its peers.
	struct GameLoaded: public interface::Event::Private
	{
		SceneReference scene;

		GameLoaded(SceneReference scene): scene(scene){}
	};

	struct Interface
	{
		// Load Luanti's builtin and the game's mods, and run them. The game
		// is a directory with a game.conf, the world one with a world.mt;
		// both live under user_path/luanti, not in anyone's Luanti install.
		//
		// Whatever extends the environment is registered before this is
		// called: Luanti loads its mods once, in order, and a late arrival
		// would be a different kind of thing entirely.
		virtual void run_game(const ss_ &game_path, const ss_ &world_path) = 0;

		// Hand Lua into the Luanti environment. chunkname is what a traceback
		// calls it. An error after run_game(), for the reason above.
		virtual void load_lua(const ss_ &chunk, const ss_ &chunkname) = 0;

		// The scene the map is in, or null until luanti:game_loaded
		virtual SceneReference get_scene() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(luanti::Interface*)> cb)
	{
		return server->access_module("luanti", [&](interface::Module *module){
			auto *iface = (luanti::Interface*)module->check_interface();
			cb(iface);
		});
	}
}

// vim: set noet ts=4 sw=4:
