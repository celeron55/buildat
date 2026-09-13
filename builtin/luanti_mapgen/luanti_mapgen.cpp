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
#define MODULE "luanti_mapgen"

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
