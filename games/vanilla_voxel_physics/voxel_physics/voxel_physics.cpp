// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// vanilla with voxel physics ([VOXEL_PHYSICS_SAMPLE]): what this game adds
// to games/vanilla, which it is a variant of ([GAME_BASE]). So far the
// plane the sim keeps its per-voxel state in; the sim itself is next.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "luanti/api.h"
#include "voxelworld/api.h"
#define MODULE "voxel_physics"

using interface::Event;

namespace voxel_physics {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
	}

	// The world exists and the luanti module has set its format: the
	// state plane goes on beside it, and every chunk takes it on the
	// first time the sim writes into it
	void on_game_loaded(const luanti::GameLoaded &event)
	{
		voxelworld::access(m_server, event.scene,
				[&](voxelworld::Instance *world){
			int i = world->get_voxel_reg()->add_plane("voxel_physics:state", 8);
			log_i(MODULE, "voxel_physics:state is plane %i: %s", i,
					cs(world->get_voxel_reg()->get_format().dump()));
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_voxel_physics(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
