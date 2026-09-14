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
		// Which of the things a mapgen makes it is told to make, in
		// Luanti's own words: "caves,dungeons,light,decorations,biomes,
		// ores", with a "no" in front of one to turn it off. Empty is all
		// of them, which is what Luanti's own default comes to.
		ss_ mg_flags;
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

		// A noise as a mod wrote it, for the things a mapgen shapes with
		// one. The flags are Luanti's own words -- "defaults", "eased",
		// "absvalue" -- because parsing them is the vendored side's job.
		struct NoiseParams
		{
			bool given = false;
			float offset = 0.0f;
			float scale = 1.0f;
			float spread_x = 250.0f, spread_y = 250.0f, spread_z = 250.0f;
			int32_t seed = 0;
			int32_t octaves = 3;
			float persist = 0.6f;
			float lacunarity = 2.0f;
			ss_ flags;
		};

		// An ore as the game registered it: the node names are already the
		// ids they mean, and the biome names are still names, because which
		// number a biome is depends on the order they crossed in.
		struct Ore
		{
			ss_ name;
			ss_ type = "scatter";
			uint32_t c_ore = 0;
			sv_<uint32_t> c_wherein;
			int32_t clust_scarcity = 1;
			int32_t clust_num_ores = 1;
			int32_t clust_size = 0;
			int32_t y_min = -31000;
			int32_t y_max = 31000;
			int32_t ore_param2 = 0;
			ss_ flags;
			float nthresh = 0.0f;
			NoiseParams np;
			sv_<ss_> biomes;
			// A sheet's columns
			int32_t column_height_min = 1;
			int32_t column_height_max = 0;
			float column_midpoint_factor = 0.5f;
			// A puff's two surfaces
			NoiseParams np_puff_top, np_puff_bottom;
			// A vein
			float random_factor = 1.0f;
			// A stratum
			NoiseParams np_stratum_thickness;
			int32_t stratum_thickness = 8;
		};
		sv_<Ore> ores;

		// A schematic: either a .mts file, which the vendored reader opens,
		// or the same thing as a mod wrote it in Lua -- the ids and the
		// probabilities flat, in the order x fastest and then y and then z,
		// which is what a schematic holds.
		struct Schematic
		{
			bool given = false;
			ss_ file;
			sm_<ss_, ss_> replacements;
			int32_t size_x = 0, size_y = 0, size_z = 0;
			// The names the schematic is made of, and one index into them
			// per node -- which is the condensed form a .mts file holds, so
			// that the vendored NodeResolver resolves an inline schematic
			// exactly as it resolves one out of a file
			sv_<ss_> node_names;
			sv_<uint32_t> ids;
			sv_<int32_t> param1;
			sv_<int32_t> param2;
			sv_<int32_t> yslice_prob;
		};

		// A decoration as the game registered it. The node names are ids
		// already; the biome names are names, as an ore's are.
		struct Decoration
		{
			ss_ name;
			ss_ type = "simple";
			sv_<uint32_t> c_place_on;
			int32_t sidelen = 8;
			float fill_ratio = 0.02f;
			int32_t y_min = -31000;
			int32_t y_max = 31000;
			ss_ flags;
			NoiseParams np;
			sv_<ss_> biomes;
			sv_<uint32_t> c_spawnby;
			int32_t nspawnby = -1;
			int32_t place_offset_y = 0;
			int32_t check_offset = -1;
			// simple
			sv_<uint32_t> c_decos;
			int32_t deco_height = 1;
			int32_t deco_height_max = 0;
			int32_t deco_param2 = 0;
			int32_t deco_param2_max = 0;
			// schematic
			ss_ rotation = "0";
			Schematic schematic;
		};
		sv_<Decoration> decorations;

		// Which of the things a mapgen makes the game asked to be told
		// about, in Luanti's own flag words ("dungeon,decoration"), and the
		// decoration ids a mod named. A generator records nothing when no
		// flag is on, which is what every game that never asks costs.
		ss_ gen_notify_flags;
		sv_<uint32_t> gen_notify_deco_ids;
	};

	// One thing a mapgen made and was asked to report: what it is, by
	// Luanti's name for it -- "dungeon", "cave_begin", or "decoration#<id>"
	// for a decoration -- and where.
	struct GennotifyEvent
	{
		ss_ name;
		int32_t x = 0, y = 0, z = 0;
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

		// The level a player can stand at above (x, z), out of the mapgen's
		// own noise and generating nothing -- Luanti's
		// Mapgen::getSpawnLevelAtPoint(), which is what its spawn search
		// asks before it touches the map. False means the column is no
		// place to spawn: a river, or a surface under water. The mapgen
		// this asks is built once per (mapgen, seed) and kept, so a search
		// of a few thousand points costs a few thousand noise samples.
		virtual bool spawn_level(const Params &params, int x, int z,
				int &level_out) = 0;

		// What the generator made in a section and was asked to report,
		// taken away: a generator runs in worldgen's thread and cannot
		// reach a module, so it leaves its gennotify here and whoever runs
		// the game's on_generated over that section picks it up. Nothing is
		// kept for a section no flag was on for.
		virtual void take_gennotify(int section_x, int section_y,
				int section_z, sv_<GennotifyEvent> &out) = 0;
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
