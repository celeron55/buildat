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
		// How many voxels a section is, which is the chunk a generator is
		// asked for one of at a time
		int section_size = 64;
		// The game's node ids by name, as the game registered them. A
		// generator asks for "mapgen_stone" and gets what the game means by
		// it, which is how Luanti's own mapgens are told what to build
		// with.
		sm_<ss_, uint32_t> content_ids;

		// What a mapgen asks about a node, which decides what a cave may
		// carve through, what a liquid is and what floods. Without these
		// the shim guesses that everything which is not air is solid
		// ground.
		struct NodeProps
		{
			bool walkable = true;
			bool is_ground_content = true;
			bool floodable = false;
			bool light_propagates = false;
			bool sunlight_propagates = false;
			// Luanti's LiquidType: 0 none, 1 flowing, 2 source
			int liquid_type = 0;
		};
		sm_<uint32_t, NodeProps> node_props;

		// A biome as the game registered it, with every node name already
		// turned into the id it means. Without any of these a world is the
		// default biome, which is stone all the way up.
		struct Biome
		{
			ss_ name;
			uint32_t c_top = 0, c_filler = 0, c_stone = 0, c_water_top = 0,
					c_water = 0, c_river_water = 0, c_riverbed = 0,
					c_dust = 0, c_dungeon = 0, c_dungeon_alt = 0,
					c_dungeon_stair = 0;
			int32_t depth_top = 0, depth_filler = 0, depth_water_top = 0,
					depth_riverbed = 0;
			int32_t y_min = -31000, y_max = 31000;
			float heat_point = 0.0f, humidity_point = 0.0f;
			int32_t vertical_blend = 0;
			float weight = 1.0f;
		};
		sv_<Biome> biomes;
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
