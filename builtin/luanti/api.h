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

		// Read a Luanti world into the running game's world: the clock it
		// was left at, and as much of its map as this world has room for.
		// One direction: the Luanti world directory is opened read-only and
		// nothing is written back to it.
		//
		// After run_game(), because the nodes the blocks name have to be
		// registered before anything can be said about them -- a name this
		// game does not register becomes "unknown" and is counted. What
		// comes over is the nodes and their two params, the metadata
		// hanging off them, the clock and what the mods remembered; a
		// block's timers and its static objects do not.
		//
		// The mods have therefore already loaded when the storage arrives,
		// so a mod that read its storage while loading read the save's own
		// and sees the imported values from the next run. A value the save
		// already has is kept, so importing twice does not take a mod's
		// memory back to what the Luanti world had.
		virtual void import_world(const ss_ &luanti_world_path) = 0;

		// A client arriving, leaving, and saying where it is. A player is
		// what Luanti calls whoever is on the other end of a client: the
		// name is the caller's to choose and is what everything about the
		// player is keyed by, the join and leave callbacks a mod registers
		// run here, and core.get_connected_players() answers with them.
		//
		// Where a player is is their client's to say; nothing here moves
		// one. The angles are radians, horizontal measured the way
		// core.get_look_horizontal() means it.
		virtual void add_player(const ss_ &name) = 0;
		virtual void remove_player(const ss_ &name) = 0;
		virtual void set_player_pos(const ss_ &name, float x, float y,
				float z, float look_h, float look_v) = 0;

		// What a click comes to. The node is dug the way core.dig_node()
		// digs one -- the pointed thing is handed to the vendored builtin
		// with a nil actor, so can_dig, after_dig_node and the drops are
		// the builtin's own -- and the answer is whether anything happened.
		//
		// There is no player yet, so there is nobody to give the drops to:
		// what a dig drops lands on the ground.
		virtual bool dig_node(int32_t x, int32_t y, int32_t z) = 0;

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
