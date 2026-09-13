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
#include "vendor/log.cpp"
#include "vendor/nodedef.cpp"
#include "vendor/voxel.cpp"

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
		if(params.mgname != "singlenode"){
			log_w(MODULE, "create_generator(): no mapgen called \"%s\" in "
					"this build; a world of one node instead",
					cs(params.mgname));
		}
		log_i(MODULE, "A \"%s\" generator, seed %s, %zu node ids",
				cs(params.mgname), cs(itos(params.seed)),
				params.content_ids.size());
		return new SinglenodeGenerator(params.singlenode_word);
	}

	sv_<ss_> list_mapgens()
	{
		return sv_<ss_>{"singlenode"};
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
