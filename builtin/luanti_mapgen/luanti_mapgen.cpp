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

	log_v(MODULE, "check_voxel_manipulator: the vendored one reads back, "
			"and its order is voxelworld's");
}

// One of Luanti's own mapgens, generating into the volume worldgen hands
// over. Everything it needs was given to it when the world was made: the
// node ids by name, the seed and the parameters. Nothing here touches a
// module -- this runs in worldgen's thread.
struct VendoredGenerator: public worldgen::GeneratorInterface
{
	// Luanti's mapgens write a chunk plus one mapblock of padding around
	// it, which is where a tree at the edge or a cave's mouth lands
	static const int PADDING = MAP_BLOCKSIZE;

	NodeDefManager m_ndef;
	EmergeParams m_emerge;
	BiomeManager *m_biomemgr = nullptr;
	OreManager *m_oremgr = nullptr;
	DecorationManager *m_decomgr = nullptr;
	SchematicManager *m_schemmgr = nullptr;
	Server m_server;
	MapgenParams *m_params = nullptr;
	BiomeParams *m_bparams = nullptr;
	Mapgen *m_mapgen = nullptr;
	// How many mapblocks a section is; a section is sixty-four voxels and
	// a mapblock sixteen
	int m_chunk_blocks = 4;

	VendoredGenerator(const Params &params, int section_size)
	{
		for(const auto &pair : params.content_ids){
			ContentFeatures f;
			f.name = pair.first;
			// What a mapgen asks about a node; the game's own answers are
			// not sent across yet, so these are what a solid node is
			f.walkable = (pair.first != "air" && pair.first != "ignore");
			f.is_ground_content = f.walkable;
			f.param_type = CPT_LIGHT;
			f.light_propagates = !f.walkable;
			f.sunlight_propagates = !f.walkable;
			m_ndef.set_content(pair.first, (content_t)pair.second, f);
		}
		m_chunk_blocks = section_size / MAP_BLOCKSIZE;
		if(m_chunk_blocks < 1)
			m_chunk_blocks = 1;

		// The managers ask the server for the node definitions, and they
		// ask while they are being built
		m_server = Server(&m_ndef);
		m_biomemgr = new BiomeManager(&m_server);
		m_oremgr = new OreManager(&m_server);
		m_decomgr = new DecorationManager(&m_server);
		m_schemmgr = new SchematicManager(&m_server);
		m_emerge.ndef = &m_ndef;
		m_emerge.biomemgr = m_biomemgr;
		m_emerge.oremgr = m_oremgr;
		m_emerge.decomgr = m_decomgr;
		m_emerge.schemmgr = m_schemmgr;

		// The managers registered their node names while they were built;
		// now that they are, those can be looked up
		m_ndef.resolvePending();

		const MapgenType type = Mapgen::getMapgenType(params.mgname);
		m_params = Mapgen::createMapgenParams(type);
		m_params->mgtype = type;
		m_params->chunksize = v3s16(m_chunk_blocks);
		m_params->seed = (u64)params.seed;
		m_params->water_level = (s16)params.water_level;
		// Luanti reads these out of mg_flags, whose default is all of them.
		// The settings here answer nothing, so the default is spelled out:
		// without it a world is bare terrain in the dark -- no caves, no
		// ores, no decorations, and no light, because the light is one of
		// the flags.
		m_params->flags = MG_CAVES | MG_DUNGEONS | MG_LIGHT |
				MG_DECORATIONS | MG_BIOMES | MG_ORES;

		// The biomes a mapgen asks about as it goes. Luanti's own
		// EmergeManager makes this the same way, out of the parameters the
		// world was made with.
		m_bparams = BiomeManager::createBiomeParams(BIOMEGEN_ORIGINAL);
		if(m_bparams){
			m_bparams->seed = m_params->seed;
			m_emerge.biomegen = m_biomemgr->createBiomeGen(
					BIOMEGEN_ORIGINAL, m_bparams,
					v3s16((s16)(m_chunk_blocks * MAP_BLOCKSIZE)));
		}

		m_mapgen = Mapgen::createMapgen(type, m_params, &m_emerge);
		// And the mapgen's own names, which it registers as it is built
		m_ndef.resolvePending();
	}

	~VendoredGenerator()
	{
		// The mapgen deletes the biome generator it was given; see
		// MapgenBasic's destructor
		delete m_mapgen;
		delete m_bparams;
		delete m_params;
		delete m_biomemgr;
		delete m_oremgr;
		delete m_decomgr;
		delete m_schemmgr;
	}

	pv::Vector3DInt32 get_padding_voxels()
	{
		return pv::Vector3DInt32(PADDING, PADDING, PADDING);
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

	~Module(){}

	void init()
	{
		check_voxel_manipulator();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
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
		return new VendoredGenerator(params, (int)params.section_size);
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
