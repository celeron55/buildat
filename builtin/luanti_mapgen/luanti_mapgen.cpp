// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Luanti's mapgens, vendored, behind a generator worldgen can run. See
// api.h for what crosses the boundary and why this is a module of its own.
//
// What is here so far is the seam and singlenode; what comes next is
// vendor/, which is Luanti's src/mapgen with a shim under it. See "Mapgen
// stage 3: how it lands" in doc/plan/luanti_module_plan.md.
#include "luanti_mapgen/api.h"
#include "worldgen/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "interface/mutex.h"
#include <cassert>
#define MODULE "luanti_mapgen"

// Luanti's own code and the shim under it, in one translation unit because
// that is what a runtime-compiled module is. See vendor/README.txt.
//
// What is compiled so far is the bottom of the tree: the voxel manipulator
// every mapgen writes into, the noise adapter, and the node definitions
// they ask about. The generators themselves are vendored in but not yet
// built -- vendor/README.txt says where the port stopped and what the next
// missing piece is.
#include "vendor/log.cpp"
#include "vendor/globals.cpp"
#include "vendor/util/serialize.cpp"
#include "vendor/nodedef.cpp"
#include "vendor/mapnode.cpp"
#include "vendor/serialization.cpp"
#include "vendor/noise.cpp"
#include "vendor/voxel.cpp"
#include "vendor/objdef.cpp"
#include "vendor/mapgen.cpp"
#include "vendor/mg_biome.cpp"
#include "vendor/mg_ore.cpp"
#include "vendor/mg_decoration.cpp"
#include "vendor/mg_schematic.cpp"
#include "vendor/cavegen.cpp"
#include "vendor/dungeongen.cpp"
#include "vendor/treegen.cpp"
#include "vendor/mapgen_singlenode.cpp"
#include "vendor/mapgen_v5.cpp"
#include "vendor/mapgen_v6.cpp"
#include "vendor/mapgen_v7.cpp"
#include "vendor/mapgen_flat.cpp"
#include "vendor/mapgen_fractal.cpp"
#include "vendor/mapgen_valleys.cpp"
#include "vendor/mapgen_carpathian.cpp"

namespace pv = PolyVox;

using interface::Event;

namespace luanti_mapgen {

// Luanti's MapgenSinglenode: one node everywhere, and the sunlight with it.
// What a mod reads out of a part of the world nobody has built in is that
// node and not "ignore", which is what every mod that looks before it
// places is written against.
struct SinglenodeGenerator: public worldgen::GeneratorInterface
{
	uint32_t m_word;

	SinglenodeGenerator(uint32_t word): m_word(word){}

	void generate(main_context::SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			interface::VoxelVolume &volume)
	{
		volume.fill(interface::VoxelInstance(m_word));
	}
};

// The game's word for how a node is drawn, as Luanti's own enum. The mapgen
// draws nothing; what it reads this for is whether a voxel is open space a
// dungeon must leave alone (airlike and the liquids) and whether it is cubic
// enough for a biome's dust to settle on (normal, allfaces, the glasslikes)
// -- so every other shape has to be some drawtype that is neither, and not
// the NDT_NORMAL a missing one used to leave behind.
static NodeDrawType drawtype_of(const ss_ &name)
{
	static const sm_<ss_, NodeDrawType> map = {
		{"normal", NDT_NORMAL},
		{"airlike", NDT_AIRLIKE},
		{"liquid", NDT_LIQUID},
		{"flowingliquid", NDT_FLOWINGLIQUID},
		{"glasslike", NDT_GLASSLIKE},
		{"glasslike_framed", NDT_GLASSLIKE_FRAMED},
		{"glasslike_framed_optional", NDT_GLASSLIKE_FRAMED_OPTIONAL},
		{"allfaces", NDT_ALLFACES},
		{"allfaces_optional", NDT_ALLFACES_OPTIONAL},
		{"torchlike", NDT_TORCHLIKE},
		{"signlike", NDT_SIGNLIKE},
		{"plantlike", NDT_PLANTLIKE},
		{"plantlike_rooted", NDT_PLANTLIKE_ROOTED},
		{"firelike", NDT_FIRELIKE},
		{"fencelike", NDT_FENCELIKE},
		{"raillike", NDT_RAILLIKE},
		{"nodebox", NDT_NODEBOX},
		{"mesh", NDT_MESH},
	};
	auto it = map.find(name);
	return it != map.end() ? it->second : NDT_NORMAL;
}

// The vendored VoxelManipulator through the shim under it, which is the
// one thing that has to be right before any of Luanti's mapgens can be:
// every generator writes into one of these, and what comes out of it is
// translated into a voxelworld volume.
//
// The orders have to agree. VoxelArea indexes x fastest and then y and then
// z, which is what interface::VoxelVolume is in as well, and the
// translation leans on that.
static void check_voxel_manipulator()
{
	VoxelManipulator vm;
	VoxelArea area(v3s16(-2, -3, -4), v3s16(5, 6, 7));
	vm.addArea(area);

	vm.setNodeNoEmerge(v3s16(1, 2, 3), MapNode(42, 7, 9));
	MapNode n = vm.getNodeNoEx(v3s16(1, 2, 3));
	assert(n.getContent() == 42);
	assert(n.param1 == 7 && n.param2 == 9);
	// One voxel over is not the one that was written
	assert(vm.getNodeNoEx(v3s16(1, 2, 4)).getContent() == CONTENT_IGNORE);
	// And outside the area is nothing at all
	assert(vm.getNodeNoEx(v3s16(99, 99, 99)).getContent() == CONTENT_IGNORE);

	const v3s32 extent = area.getExtent();
	assert(area.index(1, 0, 0) - area.index(0, 0, 0) == 1);
	assert(area.index(0, 1, 0) - area.index(0, 0, 0) == extent.X);
	assert(area.index(0, 0, 1) - area.index(0, 0, 0) == extent.X * extent.Y);
	assert(area.index(-2, -3, -4) == 0);
	assert((size_t)area.getVolume() == (size_t)extent.X * extent.Y * extent.Z);

	// And a definition answers what a mapgen asks of it
	NodeDefManager ndef;
	ContentFeatures f;
	f.name = "check:stone";
	f.walkable = true;
	f.is_ground_content = true;
	f.param_type = CPT_LIGHT;
	ndef.set_content("check:stone", 42, f);
	assert(ndef.getId("check:stone") == 42);
	assert(ndef.getId("check:nothing") == CONTENT_IGNORE);
	assert(ndef.get((content_t)42).is_ground_content);
	assert(!ndef.get((content_t)43).is_ground_content);
	assert(ndef.getLightingFlags((content_t)42).has_light);

	// And the game's word for a drawtype is the enum the mapgen tests
	// against: open space it must not carve a dungeon into, and the cubic
	// shapes a biome's dust settles on
	assert(drawtype_of("airlike") == NDT_AIRLIKE);
	assert(drawtype_of("flowingliquid") == NDT_FLOWINGLIQUID);
	assert(drawtype_of("glasslike_framed") == NDT_GLASSLIKE_FRAMED);
	assert(drawtype_of("plantlike") == NDT_PLANTLIKE);
	assert(drawtype_of("nodebox") == NDT_NODEBOX);
	// One a game made up, or a newer Luanti's, is drawn as a cube
	assert(drawtype_of("cakelike") == NDT_NORMAL);

	log_v(MODULE, "check_voxel_manipulator: the vendored one reads back, "
			"and its order is voxelworld's");
}

// Luanti's own words for the shapes an ore comes in; its own l_mapgen.cpp
// keeps the same table for the same purpose.
static bool ore_type_of(const ss_ &name, OreType &out)
{
	if(name == "scatter") out = ORE_SCATTER;
	else if(name == "sheet") out = ORE_SHEET;
	else if(name == "puff") out = ORE_PUFF;
	else if(name == "blob") out = ORE_BLOB;
	else if(name == "vein") out = ORE_VEIN;
	else if(name == "stratum") out = ORE_STRATUM;
	else return false;
	return true;
}

// A noise as it crossed, into the vendored NoiseParams the mapgen wants
static void read_noise_params(const luanti_mapgen::Params::NoiseParams &src,
		NoiseParams &out)
{
	out.offset = src.offset;
	out.scale = src.scale;
	out.spread = v3f(src.spread_x, src.spread_y, src.spread_z);
	out.seed = src.seed;
	out.octaves = (u16)src.octaves;
	out.persist = src.persist;
	out.lacunarity = src.lacunarity;
	// Luanti parses these with flagdesc_noiseparams, which lives in the
	// noise.cpp this build replaced; the words are the same three, and a
	// "no" in front of one clears it. This build's noise reads none of them
	// -- see the note at the top of vendor/noise.h -- so what this is for
	// is that a mod's flags arrive as the mod wrote them.
	out.flags = NOISE_FLAG_DEFAULTS;
	ss_ word;
	ss_ text = src.flags;
	text.push_back(',');
	for(char c : text){
		if(c != ',' && c != ' ' && c != '\t'){
			word.push_back(c);
			continue;
		}
		if(word.empty())
			continue;
		bool off = false;
		if(word.size() > 2 && word.compare(0, 2, "no") == 0){
			off = true;
			word = word.substr(2);
		}
		u32 bit = 0;
		if(word == "defaults") bit = NOISE_FLAG_DEFAULTS;
		else if(word == "eased") bit = NOISE_FLAG_EASED;
		else if(word == "absvalue") bit = NOISE_FLAG_ABSVALUE;
		if(bit != 0){
			if(off)
				out.flags &= ~bit;
			else
				out.flags |= bit;
		}
		word.clear();
	}
}

static bool deco_type_of(const ss_ &name, DecorationType &out)
{
	if(name == "simple") out = DECO_SIMPLE;
	else if(name == "schematic") out = DECO_SCHEMATIC;
	else if(name == "lsystem") out = DECO_LSYSTEM;
	else return false;
	return true;
}

static Rotation rotation_of(const ss_ &name)
{
	if(name == "90") return ROTATE_90;
	if(name == "180") return ROTATE_180;
	if(name == "270") return ROTATE_270;
	if(name == "random") return ROTATE_RAND;
	return ROTATE_0;
}

// Where a generator leaves what it was asked to report, because it runs in
// worldgen's thread and the module that answers for it is elsewhere. One
// per module, shared with every generator it makes.
struct GennotifyStore
{
	interface::Mutex mutex;
	// Push back, take from anywhere: a section is generated once and its
	// events are taken once, so this is short unless nobody is taking them
	sv_<std::pair<int64_t, sv_<GennotifyEvent>>> sections;
	// What is kept when nobody takes them, which is what a game that asks
	// to be told and then never looks does. Luanti drops them the same way
	// -- the emerge thread's events go with the chunk.
	static const size_t MAX_SECTIONS = 256;

	static int64_t key_of(int x, int y, int z)
	{
		return ((int64_t)(int16_t)x << 32) | ((int64_t)(uint16_t)y << 16) |
				(int64_t)(uint16_t)z;
	}

	void put(int64_t key, sv_<GennotifyEvent> &&events)
	{
		interface::MutexScope ms(mutex);
		for(auto &pair : sections){
			if(pair.first == key){
				pair.second = std::move(events);
				return;
			}
		}
		if(sections.size() >= MAX_SECTIONS)
			sections.erase(sections.begin());
		sections.push_back(std::make_pair(key, std::move(events)));
	}

	void take(int64_t key, sv_<GennotifyEvent> &out)
	{
		interface::MutexScope ms(mutex);
		for(size_t i = 0; i < sections.size(); i++){
			if(sections[i].first != key)
				continue;
			out = std::move(sections[i].second);
			sections.erase(sections.begin() + i);
			return;
		}
	}
};

// One of Luanti's own mapgens, generating into the volume worldgen hands
// over. Everything it needs was given to it when the world was made: the
// node ids by name, the seed and the parameters. Nothing here touches a
// module -- this runs in worldgen's thread.
struct VendoredGenerator: public worldgen::GeneratorInterface,
		public luanti_mapgen::BiomeQuery
{
	// Luanti's mapgens write a chunk plus one mapblock of padding around
	// it, which is where a tree at the edge or a cave's mouth lands
	static const int PADDING = MAP_BLOCKSIZE;

	NodeDefManager m_ndef;
	// The bundle the mapgen is built with, and which the mapgen deletes:
	// Luanti's Mapgen destructor does that, and the EmergeParams takes the
	// managers and the biome generator with it. So nothing here is a member
	// by value and nothing here deletes them a second time.
	EmergeParams *m_emerge = nullptr;
	Server m_server;
	MapgenParams *m_params = nullptr;
	BiomeParams *m_bparams = nullptr;
	Mapgen *m_mapgen = nullptr;
	// How many mapblocks a section is; a section is sixty-four voxels and
	// a mapblock sixteen
	int m_chunk_blocks = 4;

	// Where what this made goes for the module to pick up, and the key it
	// goes under; null when the game asked to be told about nothing
	sp_<GennotifyStore> m_gennotify;
	// The game's own number for each decoration the manager holds; see the
	// decoration loop
	sv_<size_t> m_deco_source_of_index;

	VendoredGenerator(const Params &params, int section_size,
			sp_<GennotifyStore> gennotify = nullptr)
	{
		// A mapgen writes air and reads back what it wrote, and it does that
		// through the constants in mapnode.h rather than through a name. So
		// the three the module reserves have to be those three numbers.
		check_reserved_id(params, "air", CONTENT_AIR);
		check_reserved_id(params, "ignore", CONTENT_IGNORE);
		check_reserved_id(params, "unknown", CONTENT_UNKNOWN);
		for(const auto &pair : params.content_ids){
			ContentFeatures f;
			f.name = pair.first;
			f.param_type = CPT_LIGHT;
			auto it = params.node_props.find(pair.second);
			if(it != params.node_props.end()){
				// What the game says about the node, which is what decides
				// what a cave carves through and what a liquid is
				const Params::NodeProps &p = it->second;
				f.walkable = p.walkable;
				f.is_ground_content = p.is_ground_content;
				f.floodable = p.floodable;
				f.light_propagates = p.light_propagates;
				f.sunlight_propagates = p.sunlight_propagates;
				f.liquid_type = (LiquidType)p.liquid_type;
				f.drawtype = drawtype_of(p.drawtype);
				f.param_type = p.param_type_light ? CPT_LIGHT : CPT_NONE;
			} else {
				// A name with no id of its own -- an alias, or a node the
				// game never registered -- and then this is what a solid
				// node looks like
				f.walkable = (pair.first != "air" && pair.first != "ignore");
				f.is_ground_content = f.walkable;
				f.light_propagates = !f.walkable;
				f.sunlight_propagates = !f.walkable;
				f.drawtype = f.walkable ? NDT_NORMAL : NDT_AIRLIKE;
			}
			m_ndef.set_content(pair.first, (content_t)pair.second, f);
		}
		m_chunk_blocks = section_size / MAP_BLOCKSIZE;
		if(m_chunk_blocks < 1)
			m_chunk_blocks = 1;

		// The managers ask the server for the node definitions, and they
		// ask while they are being built
		m_server = Server(&m_ndef);
		m_emerge = new EmergeParams();
		m_emerge->ndef = &m_ndef;
		m_emerge->biomemgr = new BiomeManager(&m_server);
		m_emerge->oremgr = new OreManager(&m_server);
		m_emerge->decomgr = new DecorationManager(&m_server);
		m_emerge->schemmgr = new SchematicManager(&m_server);

		// What the game asked to be told about. The flag words are Luanti's
		// own and so is the table they are read against, so nothing here
		// repeats the enum. A mapgen records nothing when this is zero,
		// which is what it costs a game that never asks.
		m_emerge->gen_notify_on = readFlagString(params.gen_notify_flags,
				flagdesc_gennotify, nullptr);
		if(m_emerge->gen_notify_on != 0)
			m_gennotify = gennotify;

		// The biomes the game registered, which is what a world is made of:
		// without them every mapgen builds out of the default biome the
		// manager makes for itself, and that is stone all the way up. The
		// node names are already the ids they mean -- the module resolved
		// them -- so these are not pended for resolution.
		for(const Params::Biome &src : params.biomes){
			Biome *b = new Biome();
			b->name = src.name;
			b->c_top = (content_t)src.c_top;
			b->c_filler = (content_t)src.c_filler;
			b->c_stone = (content_t)src.c_stone;
			b->c_water_top = (content_t)src.c_water_top;
			b->c_water = (content_t)src.c_water;
			b->c_river_water = (content_t)src.c_river_water;
			b->c_riverbed = (content_t)src.c_riverbed;
			b->c_dust = (content_t)src.c_dust;
			b->c_dungeon = (content_t)src.c_dungeon;
			b->c_dungeon_alt = (content_t)src.c_dungeon_alt;
			b->c_dungeon_stair = (content_t)src.c_dungeon_stair;
			// One entry always, because a cave that floods reads the first
			// of these without looking at how many there are; ignore is
			// what "this biome has no cave liquid of its own" means
			b->c_cave_liquid.push_back(CONTENT_IGNORE);
			b->depth_top = (s16)src.depth_top;
			b->depth_filler = (s16)src.depth_filler;
			b->depth_water_top = (s16)src.depth_water_top;
			b->depth_riverbed = (s16)src.depth_riverbed;
			b->min_pos.Y = (s16)src.y_min;
			b->max_pos.Y = (s16)src.y_max;
			b->heat_point = src.heat_point;
			b->humidity_point = src.humidity_point;
			b->vertical_blend = (s16)src.vertical_blend;
			b->weight = src.weight;
			// A biome that is already resolved says so, or the manager
			// waits for a resolution that never comes
			b->reset(true);
			m_emerge->biomemgr->add(b);
		}
		log_v(MODULE, "%zu biomes", params.biomes.size());

		// And the ores, which are the same crossing one layer down: a
		// mapgen asks its OreManager for them after it has made the
		// terrain, and without any the world is whatever the biomes said
		// and nothing else in it. The biome names are looked up here
		// because a biome's number is the order it was added in, which is
		// the loop above.
		size_t ores_added = 0;
		for(const Params::Ore &src : params.ores){
			OreType type;
			if(!ore_type_of(src.type, type)){
				log_w(MODULE, "Ore \"%s\": unknown ore_type \"%s\"",
						cs(src.name), cs(src.type));
				continue;
			}
			if(src.clust_scarcity <= 0 || src.clust_num_ores <= 0){
				log_w(MODULE, "Ore \"%s\": clust_scarcity and "
						"clust_num_ores have to be more than zero",
						cs(src.name));
				continue;
			}
			Ore *o = m_emerge->oremgr->create(type);
			if(o == nullptr)
				continue;
			o->name = src.name;
			o->c_ore = (content_t)src.c_ore;
			for(uint32_t id : src.c_wherein)
				o->c_wherein.push_back((content_t)id);
			o->clust_scarcity = (u32)src.clust_scarcity;
			o->clust_num_ores = (s16)src.clust_num_ores;
			o->clust_size = (s16)src.clust_size;
			o->y_min = (s16)src.y_min;
			o->y_max = (s16)src.y_max;
			o->ore_param2 = (u8)src.ore_param2;
			o->nthresh = src.nthresh;
			o->flags = readFlagString(src.flags, flagdesc_ore, nullptr);
			if(src.np.given){
				read_noise_params(src.np, o->np);
				o->flags |= OREFLAG_USE_NOISE;
			} else if(o->needs_noise){
				log_w(MODULE, "Ore \"%s\" is a %s and has no noise_params; "
						"the defaults are used", cs(src.name),
						cs(src.type));
			}
			for(const ss_ &biome_name : src.biomes){
				ObjDef *b = m_emerge->biomemgr->getByName(biome_name);
				if(b == nullptr){
					log_w(MODULE, "Ore \"%s\": no biome \"%s\"",
							cs(src.name), cs(biome_name));
					continue;
				}
				o->biomes.insert((biome_t)b->index);
			}
			switch(type){
			case ORE_SHEET: {
				OreSheet *os = (OreSheet *)o;
				os->column_height_min = (u16)src.column_height_min;
				os->column_height_max = (u16)(src.column_height_max > 0 ?
						src.column_height_max : src.clust_size);
				os->column_midpoint_factor = src.column_midpoint_factor;
				break;
			}
			case ORE_PUFF: {
				OrePuff *op = (OrePuff *)o;
				read_noise_params(src.np_puff_top, op->np_puff_top);
				read_noise_params(src.np_puff_bottom, op->np_puff_bottom);
				break;
			}
			case ORE_VEIN: {
				OreVein *ov = (OreVein *)o;
				ov->random_factor = src.random_factor;
				break;
			}
			case ORE_STRATUM: {
				OreStratum *os = (OreStratum *)o;
				if(src.np_stratum_thickness.given){
					read_noise_params(src.np_stratum_thickness,
							os->np_stratum_thickness);
					o->flags |= OREFLAG_USE_NOISE2;
				}
				os->stratum_thickness = (u16)src.stratum_thickness;
				break;
			}
			default:
				break;
			}
			// Already resolved, like the biomes above
			o->reset(true);
			m_emerge->oremgr->add(o);
			ores_added++;
		}
		if(!params.ores.empty())
			log_v(MODULE, "%zu ores", ores_added);

		// And the decorations, which are what a world has growing on it.
		// A schematic comes either as a .mts file the vendored reader opens
		// or as the arrays a mod wrote in Lua; either way what it holds are
		// this game's own ids, so nothing is pended for resolution.
		size_t decos_added = 0;
		// Which decoration of the game's the manager's own numbering means.
		// They are not the same list: one that cannot be built is left out
		// here and everything after it shifts, while the game still knows
		// it by the number it registered it in. gennotify reports the
		// manager's number, so this is what turns it back.
		size_t source_i = 0;
		for(const Params::Decoration &src : params.decorations){
			const size_t this_source = source_i++;
			DecorationType type;
			if(!deco_type_of(src.type, type)){
				log_w(MODULE, "Decoration \"%s\": unknown deco_type \"%s\"",
						cs(src.name), cs(src.type));
				continue;
			}
			if(src.sidelen <= 0){
				log_w(MODULE, "Decoration \"%s\": sidelen has to be more "
						"than zero", cs(src.name));
				continue;
			}
			Decoration *d = m_emerge->decomgr->create(type);
			if(d == nullptr)
				continue;
			d->name = src.name;
			for(uint32_t id : src.c_place_on)
				d->c_place_on.push_back((content_t)id);
			d->sidelen = (s16)src.sidelen;
			d->fill_ratio = src.fill_ratio;
			d->y_min = (s16)src.y_min;
			d->y_max = (s16)src.y_max;
			d->nspawnby = (s16)src.nspawnby;
			d->place_offset_y = (s16)src.place_offset_y;
			d->check_offset = (s16)src.check_offset;
			for(uint32_t id : src.c_spawnby)
				d->c_spawnby.push_back((content_t)id);
			d->flags = readFlagString(src.flags, flagdesc_deco, nullptr);
			if(src.np.given){
				read_noise_params(src.np, d->np);
				d->flags |= DECO_USE_NOISE;
			}
			for(const ss_ &biome_name : src.biomes){
				ObjDef *b = m_emerge->biomemgr->getByName(biome_name);
				if(b == nullptr){
					log_w(MODULE, "Decoration \"%s\": no biome \"%s\"",
							cs(src.name), cs(biome_name));
					continue;
				}
				d->biomes.insert((biome_t)b->index);
			}
			bool ok = true;
			if(type == DECO_SIMPLE){
				DecoSimple *ds = (DecoSimple *)d;
				for(uint32_t id : src.c_decos)
					ds->c_decos.push_back((content_t)id);
				ds->deco_height = (s16)src.deco_height;
				ds->deco_height_max = (s16)src.deco_height_max;
				ds->deco_param2 = (u8)src.deco_param2;
				ds->deco_param2_max = (u8)src.deco_param2_max;
				if(ds->c_decos.empty() || ds->deco_height <= 0){
					log_w(MODULE, "Decoration \"%s\": nothing to place, or "
							"a height of none", cs(src.name));
					ok = false;
				}
			} else if(type == DECO_SCHEMATIC){
				DecoSchematic *dsch = (DecoSchematic *)d;
				dsch->rotation = rotation_of(src.rotation);
				dsch->schematic = make_schematic(src.schematic, src.name);
				if(dsch->schematic == nullptr)
					ok = false;
			} else {
				// An L-system tree, out of the tree generator's own
				// definition: the same one core.spawn_tree() takes, with
				// its nodes already resolved to ids
				DecoLSystem *dl = (DecoLSystem *)d;
				const Params::Decoration::LTree &t = src.ltree;
				if(!t.given || t.axiom.empty()){
					log_w(MODULE, "Decoration \"%s\": an lsystem decoration "
							"with no treedef", cs(src.name));
					ok = false;
				} else {
					auto def = std::make_shared<treegen::TreeDef>();
					def->initial_axiom = t.axiom;
					def->rules_a = t.rules_a;
					def->rules_b = t.rules_b;
					def->rules_c = t.rules_c;
					def->rules_d = t.rules_d;
					def->trunknode = MapNode((content_t)t.c_trunk);
					def->leavesnode = MapNode((content_t)t.c_leaves);
					def->leaves2node = MapNode((content_t)t.c_leaves2);
					def->fruitnode = MapNode((content_t)t.c_fruit);
					def->leaves2_chance = t.leaves2_chance;
					def->angle = t.angle;
					def->iterations = t.iterations;
					def->iterations_random_level = t.random_level;
					def->trunk_type = t.trunk_type;
					def->thin_branches = t.thin_branches;
					def->fruit_chance = t.fruit_chance;
					def->seed = t.seed;
					def->explicit_seed = t.explicit_seed;
					dl->tree_def = def;
				}
			}
			if(!ok){
				delete d;
				continue;
			}
			d->reset(true);
			m_emerge->decomgr->add(d);
			m_deco_source_of_index.push_back(this_source);
			decos_added++;
		}
		if(!params.decorations.empty())
			log_v(MODULE, "%zu decorations", decos_added);

		// The decorations a mod asked to hear about, by the manager's
		// numbering, which is what the notifier compares against
		for(uint32_t id : params.gen_notify_deco_ids){
			for(size_t i = 0; i < m_deco_source_of_index.size(); i++){
				if(m_deco_source_of_index[i] != (size_t)id)
					continue;
				m_emerge->m_no_deco_ids.insert((u32)i);
				break;
			}
		}

		// The managers registered their node names while they were built;
		// now that they are, those can be looked up
		m_ndef.resolvePending();

		const MapgenType type = Mapgen::getMapgenType(params.mgname);
		m_params = Mapgen::createMapgenParams(type);
		m_params->mgtype = type;
		m_params->chunksize = v3s16(m_chunk_blocks);
		m_params->seed = (u64)params.seed;
		m_params->water_level = (s16)params.water_level;
		// Which of the things a mapgen makes it is told to make. A world
		// that names none gets all of them, which is Luanti's own default:
		// without them a world is bare terrain in the dark -- no caves, no
		// ores, no decorations, and no light, because the light is one of
		// the flags.
		m_params->flags = MG_CAVES | MG_DUNGEONS | MG_LIGHT |
				MG_DECORATIONS | MG_BIOMES | MG_ORES;
		if(!params.mg_flags.empty()){
			u32 mask = 0;
			const u32 named = readFlagString(params.mg_flags, flagdesc_mapgen,
					&mask);
			m_params->flags = (m_params->flags & ~mask) | named;
			log_v(MODULE, "mg_flags \"%s\" -> %i",
					cs(params.mg_flags), (int)m_params->flags);
		}

		// The biomes a mapgen asks about as it goes. Luanti's own
		// EmergeManager makes this the same way, out of the parameters the
		// world was made with.
		m_bparams = BiomeManager::createBiomeParams(BIOMEGEN_ORIGINAL);
		if(m_bparams){
			m_bparams->seed = m_params->seed;
			m_emerge->biomegen = m_emerge->biomemgr->createBiomeGen(
					BIOMEGEN_ORIGINAL, m_bparams,
					v3s16((s16)(m_chunk_blocks * MAP_BLOCKSIZE)));
		}

		m_mapgen = Mapgen::createMapgen(type, m_params, m_emerge);
		// And the mapgen's own names, which it registers as it is built
		m_ndef.resolvePending();
	}

	~VendoredGenerator()
	{
		// The mapgen owns the EmergeParams it was built with -- Luanti's
		// own Mapgen destructor deletes it -- and the EmergeParams owns the
		// managers and the biome generator. So deleting the mapgen deletes
		// all of them, and there is something left here to delete only if
		// there never was a mapgen.
		if(m_mapgen)
			delete m_mapgen;
		else
			delete m_emerge;
		delete m_bparams;
		delete m_params;
	}

	// A schematic, out of a .mts file or out of the arrays a mod wrote in
	// Lua. It belongs to the SchematicManager, which the EmergeParams owns,
	// so it is registered there rather than deleted here.
	Schematic *make_schematic(const luanti_mapgen::Params::Schematic &src,
			const ss_ &deco_name)
	{
		if(!src.given){
			log_w(MODULE, "Decoration \"%s\": no schematic",
					cs(deco_name));
			return nullptr;
		}
		Schematic *sch = SchematicManager::create(SCHEMATIC_NORMAL);
		sch->name = deco_name;
		if(!src.file.empty()){
			StringMap replace;
			for(const auto &pair : src.replacements)
				replace[pair.first] = pair.second;
			if(!sch->loadSchematicFromFile(src.file, &m_ndef,
					replace.empty() ? nullptr : &replace)){
				log_w(MODULE, "Decoration \"%s\": cannot read schematic %s",
						cs(deco_name), cs(src.file));
				delete sch;
				return nullptr;
			}
			m_ndef.resolvePending();
			m_emerge->schemmgr->add(sch);
			return sch;
		}
		const size_t n = (size_t)src.size_x * src.size_y * src.size_z;
		// A schematic of no size at all is a real thing to register: a mod
		// that builds its own structure registers an empty one for the
		// handle and the gennotify, and VoxeLibre's mcl_structures does it
		// two dozen times. It places nothing, which is what it is for.
		if(n == 0 && src.ids.empty()){
			sch->size = v3s16((s16)src.size_x, (s16)src.size_y,
					(s16)src.size_z);
			sch->schemdata = new MapNode[1];
			sch->schemdata[0] = MapNode(CONTENT_AIR);
			sch->slice_probs = new u8[1];
			sch->slice_probs[0] = MTSCHEM_PROB_ALWAYS;
			// Through the resolver even with nothing to resolve, because
			// that is what gives it the node definitions it is asked for
			// when it is placed
			sch->reset();
			sch->m_nnlistsizes.push_back(0);
			m_ndef.pendNodeResolve(sch);
			m_ndef.resolvePending();
			m_emerge->schemmgr->add(sch);
			return sch;
		}
		if(n == 0 || src.ids.size() != n){
			log_w(MODULE, "Decoration \"%s\": a schematic of %ix%ix%i with "
					"%zu nodes in it", cs(deco_name), (int)src.size_x,
					(int)src.size_y, (int)src.size_z, src.ids.size());
			delete sch;
			return nullptr;
		}
		sch->size = v3s16((s16)src.size_x, (s16)src.size_y, (s16)src.size_z);
		sch->schemdata = new MapNode[n];
		// The names first, in the condensed form a .mts file uses: a node's
		// content is an index into them until the resolver unfolds it
		sch->reset();
		for(const ss_ &name : src.node_names)
			sch->m_nodenames.push_back(name);
		sch->m_nnlistsizes.push_back(sch->m_nodenames.size());
		for(size_t i = 0; i < n; i++){
			MapNode node((content_t)src.ids[i]);
			// param1 is the probability a node is placed at all, and the
			// high bit is Luanti's "place me even over something"
			node.param1 = (u8)(i < src.param1.size() ?
					src.param1[i] : MTSCHEM_PROB_ALWAYS);
			node.param2 = (u8)(i < src.param2.size() ? src.param2[i] : 0);
			sch->schemdata[i] = node;
		}
		sch->slice_probs = new u8[src.size_y];
		for(int32_t y = 0; y < src.size_y; y++){
			sch->slice_probs[y] = (u8)((size_t)y < src.yslice_prob.size() ?
					src.yslice_prob[y] : MTSCHEM_PROB_ALWAYS);
		}
		m_ndef.pendNodeResolve(sch);
		m_ndef.resolvePending();
		m_emerge->schemmgr->add(sch);
		return sch;
	}

	static void check_reserved_id(const Params &params, const ss_ &name,
			content_t want)
	{
		auto it = params.content_ids.find(name);
		if(it == params.content_ids.end())
			throw Exception("luanti_mapgen: the game has no \""+name+"\"");
		if(it->second != (uint32_t)want){
			throw Exception("luanti_mapgen: \""+name+"\" is id "+
					itos(it->second)+" and the vendored mapgens are built "
					"for "+itos((int)want)+"; see CONTENT_AIR in "
					"vendor/mapnode.h");
		}
	}

	pv::Vector3DInt32 get_padding_voxels()
	{
		return pv::Vector3DInt32(PADDING, PADDING, PADDING);
	}

	// "decoration#<n>" as the game knows it: what the notifier writes is
	// the manager's own numbering, and a decoration it could not build is
	// not in that. Anything else passes through.
	ss_ deco_name_of(const ss_ &name)
	{
		static const ss_ prefix = "decoration#";
		if(name.compare(0, prefix.size(), prefix) != 0)
			return name;
		const size_t index = (size_t)atoi(name.c_str() + prefix.size());
		if(index >= m_deco_source_of_index.size())
			return name;
		return prefix + itos(m_deco_source_of_index[index]);
	}

	// Which biome the noise puts at a point, by the manager's own index --
	// which is the order the biomes were added in, and that is the order
	// they crossed in. Luanti's own l_get_biome_data asks the biome
	// generator exactly this way.
	bool biome_at(int x, int y, int z, size_t &index_out, float &heat_out,
			float &humidity_out)
	{
		if(m_emerge == nullptr || m_emerge->biomegen == nullptr)
			return false;
		if(m_emerge->biomegen->getType() != BIOMEGEN_ORIGINAL)
			return false;
		const BiomeGenOriginal *bg =
				(const BiomeGenOriginal*)m_emerge->biomegen;
		const v3s16 p((s16)x, (s16)y, (s16)z);
		Biome *b = bg->calcBiomeAtPoint(p);
		if(b == nullptr)
			return false;
		index_out = (size_t)b->index;
		heat_out = bg->calcHeatAtPoint(p);
		humidity_out = bg->calcHumidityAtPoint(p);
		return true;
	}

	// Out of the mapgen's noise, touching no map and generating nothing.
	// Luanti's own spawn search asks this first and only then looks at the
	// map; MAX_MAP_GENERATION_LIMIT is how a mapgen says "not here".
	bool spawn_level(int x, int z, int &level_out)
	{
		if(!m_mapgen)
			return false;
		const int level = m_mapgen->getSpawnLevelAtPoint(
				v2s16((s16)x, (s16)z));
		if(level >= MAX_MAP_GENERATION_LIMIT ||
				level <= -MAX_MAP_GENERATION_LIMIT)
			return false;
		level_out = level;
		return true;
	}

	void generate(main_context::SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			interface::VoxelVolume &volume)
	{
		if(!m_mapgen)
			return;
		// The section in mapblocks, which is what a mapgen counts in
		const v3s16 blockpos_min(
				(s16)(section_p.getX() * m_chunk_blocks),
				(s16)(section_p.getY() * m_chunk_blocks),
				(s16)(section_p.getZ() * m_chunk_blocks));
		const v3s16 blockpos_max = blockpos_min +
				v3s16((s16)(m_chunk_blocks - 1));
		const v3s16 full_min = (blockpos_min - 1) * MAP_BLOCKSIZE;
		const v3s16 full_max = (blockpos_max + 2) * MAP_BLOCKSIZE -
				v3s16(1);

		BlockMakeData data;
		data.seed = m_params->seed;
		data.blockpos_min = blockpos_min;
		data.blockpos_max = blockpos_max;
		data.nodedef = &m_ndef;
		data.vmanip = new MMVManip();
		data.vmanip->addArea(VoxelArea(full_min, full_max));
		// Every voxel of it is "ignore" and is data rather than a hole,
		// which is what an emerged area from an empty map looks like and
		// what makes the mapgen's writes stick
		data.vmanip->emergeAll();

		m_mapgen->makeChunk(&data);

		// What it made and was asked to report, left where the module can
		// pick it up when it runs the game's on_generated over this section
		if(m_gennotify){
			std::map<std::string, std::vector<v3s16>> events;
			m_mapgen->gennotify.getEvents(events);
			m_mapgen->gennotify.clearEvents();
			sv_<GennotifyEvent> out;
			for(const auto &pair : events){
				const ss_ name = deco_name_of(pair.first);
				for(const v3s16 &p : pair.second){
					GennotifyEvent e;
					e.name = name;
					e.x = p.X; e.y = p.Y; e.z = p.Z;
					out.push_back(e);
				}
			}
			m_gennotify->put(GennotifyStore::key_of(section_p.getX(),
					section_p.getY(), section_p.getZ()), std::move(out));
		}

		// And into the volume, which is the same box in the same order:
		// what a MapNode holds is what VoxelFormat::luanti() binds
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		size_t written = 0;
		const pv::Region &region = volume.getEnclosingRegion();
		const pv::Vector3DInt32 lc = region.getLowerCorner();
		const pv::Vector3DInt32 uc = region.getUpperCorner();
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t y = lc.getY(); y <= uc.getY(); y++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			const v3s16 p((s16)x, (s16)y, (s16)z);
			if(!data.vmanip->m_area.contains(p))
				continue;
			const MapNode n = data.vmanip->getNodeNoExNoEmerge(p);
			if(n.getContent() == CONTENT_IGNORE)
				continue;
			uint32_t word = 0;
			f.id.set(word, n.getContent());
			f.light_sky.set(word, n.param1 & 0x0f);
			f.light_lamp.set(word, (n.param1 >> 4) & 0x0f);
			f.param.set(word, n.param2);
			volume.setVoxelAt(x, y, z, interface::VoxelInstance(word));
			written++;
		}
		if(m_logged < 3){
			m_logged++;
			log_v(MODULE, "section (%i, %i, %i): %zu voxels",
					(int)section_p.getX(), (int)section_p.getY(),
					(int)section_p.getZ(), written);
		}
	}

	int m_logged = 0;
};

struct Module: public interface::Module, public luanti_mapgen::Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		delete m_query;
	}

	void init()
	{
		check_voxel_manipulator();
		check_generator_lifetime();
	}

	// A generator built and thrown away, which is what a world that is
	// opened and closed does. It is here because the ownership inside a
	// vendored mapgen is not obvious -- the Mapgen deletes the EmergeParams
	// it was built with, and that deletes the managers and the biome
	// generator -- and getting it wrong aborts in free() at shutdown rather
	// than anywhere near the mistake.
	void check_generator_lifetime()
	{
		Params params;
		params.mgname = "v7";
		params.seed = 1234;
		// The three reserved ids are the reserved ids; the rest are this
		// check's own
		params.content_ids["ignore"] = CONTENT_IGNORE;
		params.content_ids["unknown"] = CONTENT_UNKNOWN;
		params.content_ids["air"] = CONTENT_AIR;
		params.content_ids["mapgen_stone"] = 3;
		params.content_ids["mapgen_water_source"] = 4;
		params.content_ids["mapgen_river_water_source"] = 5;
		params.content_ids["mapgen_lava_source"] = 6;
		params.content_ids["mapgen_cobble"] = 7;
		delete create_generator(params);
		log_v(MODULE, "check_generator_lifetime: a v7 generator was built "
				"and deleted");
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
	}

	// A generator of its own for the questions that are asked outside
	// worldgen's thread, so that a spawn search and a generation cannot
	// touch the same Mapgen at the same time. One is kept rather than made
	// per question: a mapgen allocates its noise maps when it is built, and
	// a spawn search asks thousands of times.
	VendoredGenerator *m_query = nullptr;
	ss_ m_query_key;

	// The query generator, built on demand and kept: the noise questions --
	// where a player can spawn, which biome is where -- are asked thousands
	// of times and a mapgen allocates its noise maps when it is built.
	VendoredGenerator* query_generator(const Params &params)
	{
		const ss_ key = params.mgname+"/"+itos(params.seed)+"/"+
				itos(params.water_level);
		if(m_query == nullptr || key != m_query_key){
			delete m_query;
			// The biomes are kept, because which biome is where is one of
			// the questions; what is dropped is what a world is *decorated*
			// with -- VoxeLibre's 443 decorations read that many schematics
			// off the disk, and doing it twice for a question about noise is
			// a second of the module's thread for nothing.
			Params bare = params;
			bare.ores.clear();
			bare.decorations.clear();
			m_query = new VendoredGenerator(bare, bare.section_size);
			m_query_key = key;
		}
		return m_query;
	}

	bool spawn_level(const Params &params, int x, int z, int &level_out)
	{
		return query_generator(params)->spawn_level(x, z, level_out);
	}

	bool biome_at(const Params &params, int x, int y, int z,
			size_t &index_out, float &heat_out, float &humidity_out)
	{
		return query_generator(params)->biome_at(x, y, z, index_out,
				heat_out, humidity_out);
	}

	BiomeQuery* biome_query(const Params &params)
	{
		return query_generator(params);
	}

	// Interface

	worldgen::GeneratorInterface* create_generator(const Params &params)
	{
		log_i(MODULE, "A \"%s\" generator, seed %s, %zu node ids",
				cs(params.mgname), cs(itos(params.seed)),
				params.content_ids.size());
		// Singlenode is this module's own: what Luanti's own
		// MapgenSinglenode does is fill with one node, and doing that here
		// costs neither a NodeDefManager nor a VoxelManipulator.
		if(params.mgname == "singlenode")
			return new SinglenodeGenerator(params.singlenode_word);
		const MapgenType type = Mapgen::getMapgenType(params.mgname);
		if(type == MAPGEN_INVALID){
			log_w(MODULE, "create_generator(): no mapgen called \"%s\"; a "
					"world of one node instead", cs(params.mgname));
			return new SinglenodeGenerator(params.singlenode_word);
		}
		return new VendoredGenerator(params, (int)params.section_size,
				m_gennotify);
	}

	// What the generators have made and were asked to report; see
	// take_gennotify() in api.h
	sp_<GennotifyStore> m_gennotify = sp_<GennotifyStore>(
			new GennotifyStore());

	void take_gennotify(int section_x, int section_y, int section_z,
			sv_<GennotifyEvent> &out)
	{
		m_gennotify->take(GennotifyStore::key_of(section_x, section_y,
				section_z), out);
	}

	sv_<ss_> list_mapgens()
	{
		sv_<ss_> out{"singlenode"};
		for(int i = 0; i < (int)MAPGEN_INVALID; i++){
			const char *name = Mapgen::getMapgenName((MapgenType)i);
			if(name && ss_(name) != "singlenode")
				out.push_back(name);
		}
		return out;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_luanti_mapgen(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
