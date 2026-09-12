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

namespace storage
{
	struct Save;
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
		// is a directory with a game.conf, under user_path/luanti and not in
		// anyone's Luanti install.
		//
		// The world is the save, and the save is the caller's to open and to
		// keep open: the map, the clock and everything else the world is go
		// into it. A Luanti world directory is never written to -- it is
		// read for which game it wants, or imported, and that is all.
		// core.get_worldpath() is a directory of the save's rather than the
		// save's own root, since a Luanti mod writing through it -- which is
		// normal, and which games depend on -- must not be able to land on
		// save.sqlite.
		//
		// Whatever extends the environment is registered before this is
		// called: Luanti loads its mods once, in order, and a late arrival
		// would be a different kind of thing entirely.
		virtual void run_game(const ss_ &game_path, storage::Save *save) = 0;

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
