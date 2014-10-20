// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "ground_plane_lighting/api.h"
// TODO: Clean up
#include "network/api.h"
#include "client_file/api.h"
#include "voxelworld/api.h"
#include "replicate/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/block.h"
#include "interface/voxel_volume.h"
#include <PolyVoxCore/RawVolume.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Node.h>
#pragma GCC diagnostic pop

// TODO: Clean up
using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;

// TODO: Move to a header (core/types_polyvox.h or something)
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

namespace ground_plane_lighting {

// Y-seethrough commit hook
struct YstCommitHook: public voxelworld::CommitHook
{
	static constexpr const char *MODULE = "YstCommitHook";
	ss_ m_yst_data;

	void in_thread(voxelworld::Interface *ivoxelworld,
			const pv::Vector3DInt32 &chunk_p,
			sp_<pv::RawVolume<VoxelInstance>> volume)
	{
		interface::VoxelRegistry *voxel_reg = ivoxelworld->get_voxel_reg();
		const auto &chunk_size_voxels = ivoxelworld->get_chunk_size_voxels();
		int w = chunk_size_voxels.getX();
		int h = chunk_size_voxels.getY();
		int d = chunk_size_voxels.getZ();
		pv::Region yst_region(0, 0, 0, w, 0, d);
		// Y-seethrough (value: Lowest Y where light can go)
		// If chunk above does not pass light to this chunk, value=d+1
		up_<pv::RawVolume<uint8_t>> yst_volume(
				new pv::RawVolume<uint8_t>(yst_region));
		auto lc = yst_region.getLowerCorner();
		auto uc = yst_region.getUpperCorner();
		for(int z = 0; z < d; z++){
			for(int x = 0; x <= w; x++){
				// TODO: Read initial value from the chunk above

				int y;
				for(y = d; y >= 0; y--){
					VoxelInstance v = volume->getVoxelAt(x+1, y+1, z+1);
					const auto *def = voxel_reg->get_cached(v);
					if(!def)
						throw Exception(ss_()+"Undefined voxel: "+itos(v.getId()));
					bool light_passes = (!def || !def->physically_solid);
					if(!light_passes)
						break;
				}
				y++;
				yst_volume->setVoxelAt(x, 0, z, y);
			}
		}
		m_yst_data = interface::serialize_volume_compressed(*yst_volume);
	}

	void in_scene(voxelworld::Interface *ivoxelworld,
			const pv::Vector3DInt32 &chunk_p, magic::Node *n)
	{
		if(m_yst_data.empty()){
			// Can happen if in_thread() fails
			log_w(MODULE, "Commit hook in_scene executed without in_thread");
			return;
		}
		n->SetVar(StringHash("gpl_voxel_yst_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)m_yst_data.c_str(),
							m_yst_data.size())));
		m_yst_data.clear();
	}
};

struct Module: public interface::Module, public ground_plane_lighting::Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("ground_plane_lighting"),
		m_server(server)
	{
	}

	~Module()
	{
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			ivoxelworld->add_commit_hook(
					up_<YstCommitHook>(new YstCommitHook()));
		});
	}

	void on_unload()
	{
	}

	void on_continue()
	{
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		int peer = event.recipient;
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:run_script",
					"require(\"buildat/module/ground_plane_lighting\")");
		});
	}

	// Interface

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_ground_plane_lighting(
			interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
