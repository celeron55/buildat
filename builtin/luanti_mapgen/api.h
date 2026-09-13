// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include "worldgen/api.h"
#include <functional>

// Luanti's own mapgens, vendored, behind a generator worldgen can run.
//
// A module of its own and not a part of builtin/luanti, because a
// runtime-compiled module is one translation unit: the mapgen is thousands
// of lines that change rarely, and builtin/luanti is the file that changes
// most. See "Mapgen stage 3: how it lands" in
// doc/plan/luanti_module_plan.md.
//
// What crosses this boundary is what a generator needs and nothing else:
// the game's node ids by name, the seed, and which mapgen. Nothing here
// knows about Lua, mods or the Luanti environment, and nothing in the
// generator may touch a module -- worldgen runs it in a thread.
namespace luanti_mapgen
{
	// Which mapgen, and everything it is a function of. The names are
	// Luanti's own: "singlenode" is a node everywhere, and what the rest
	// will be is v7 and its friends.
	struct Params
	{
		ss_ mgname = "singlenode";
		int64_t seed = 0;
		// Water level, which is a mapgen parameter in Luanti and a number
		// every generator leans on
		int water_level = 1;
		// The voxel word a singlenode world is filled with: the node id and
		// the sunlight, packed by whoever asked, because the format is the
		// caller's business and not this module's
		uint32_t singlenode_word = 0;
		// The game's node ids by name, as the game registered them. A
		// generator asks for "mapgen_stone" and gets what the game means by
		// it, which is how Luanti's own mapgens are told what to build
		// with.
		sm_<ss_, uint32_t> content_ids;
	};

	struct Interface
	{
		// A generator for these parameters. It belongs to whoever is given
		// it -- worldgen deletes the one it is handed -- and it holds a
		// copy of everything it needs, because it runs in a thread with no
		// module held.
		virtual worldgen::GeneratorInterface* create_generator(
				const Params &params) = 0;

		// Which mapgens this build has. "singlenode" is always one of them.
		virtual sv_<ss_> list_mapgens() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(luanti_mapgen::Interface*)> cb)
	{
		return server->access_module("luanti_mapgen",
				[&](interface::Module *module){
			cb((luanti_mapgen::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
