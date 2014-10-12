// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "voxelworld/api.h"
#include "network/api.h"
#include "client_file/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/block.h"
#include <PolyVoxCore/SimpleVolume.h>
#include <cereal/archives/portable_binary.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Node.h>
#include <Scene.h>
//#include <MemoryBuffer.h>
#pragma GCC diagnostic pop
#include <deque>

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;

namespace std {

template<> struct hash<pv::Vector<2u, int16_t>>{
	std::size_t operator()(const pv::Vector<2u, int16_t> &v) const {
		return ((std::hash<int16_t>() (v.getX()) << 0) ^
				   (std::hash<int16_t>() (v.getY()) << 1));
	}
};

}

namespace cereal {

template<class Archive>
void save(Archive &archive, const pv::Vector3DInt16 &v){
	archive((int32_t)v.getX(), (int32_t)v.getY(), (int32_t)v.getZ());
}
template<class Archive>
void load(Archive &archive, pv::Vector3DInt16 &v){
	int16_t x, y, z;
	archive((int32_t)x, (int32_t)y, (int32_t)z);
	v.setX(x); v.setY(y); v.setZ(z);
}

}

namespace voxelworld {

struct Section
{
	pv::Vector3DInt16 chunk_size;
	pv::Region contained_chunks;// Position and size in chunks
	pv::Vector3DInt16 section_p;// Position in sections
	// Static voxel nodes (each contains one chunk); Initialized to 0.
	pv::SimpleVolume<int32_t> node_ids;

	bool save_enabled = false;
	bool generated = false;

	Section(pv::Vector3DInt16 chunk_size, pv::Region contained_chunks,
			pv::Vector3DInt16 section_p):
		chunk_size(chunk_size),
		contained_chunks(contained_chunks),
		section_p(section_p),
		node_ids(contained_chunks)
	{}
};

struct Module: public interface::Module, public voxelworld::Interface
{
	interface::Server *m_server;

	// Accessing any of these outside of Server::access_scene is disallowed
	sp_<interface::TextureAtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;
	sp_<interface::BlockRegistry> m_block_reg;

	// One node holds one chunk of voxels (eg. 32x32x32)
	pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(32, 32, 32);
	// The world is loaded and unloaded by sections (eg. 4x4x4)
	pv::Vector3DInt16 m_section_size_chunks = pv::Vector3DInt16(4, 4, 4);

	// Sections (first (y,z), then x)
	sm_<pv::Vector<2, int16_t>, sm_<int16_t, Section>> m_sections;
	// Cache of last used sections (add to end, remove from beginning)
	//std::deque<Section*> m_last_used_sections;

	Module(interface::Server *server):
		interface::Module("voxelworld"),
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
		m_server->sub_event(this, Event::t(
					"network:packet_received/voxelworld:camera_position"));

		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();
			m_atlas_reg.reset(interface::createTextureAtlasRegistry(context));
			m_voxel_reg.reset(interface::createVoxelRegistry(m_atlas_reg.get()));
			m_block_reg.reset(interface::createBlockRegistry(m_voxel_reg.get()));
			// Add some test stuff
			// TODO: Remove
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "air";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "";
					seg.total_segments = magic::IntVector2(0, 0);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
				m_voxel_reg->add_voxel(vdef);	// id 1
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "rock";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/rock.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				m_voxel_reg->add_voxel(vdef);	// id 2
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "dirt";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/dirt.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				m_voxel_reg->add_voxel(vdef);	// id 3
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "grass";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/grass.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				m_voxel_reg->add_voxel(vdef);	// id 4
			}
		});
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
		EVENT_TYPEN("network:packet_received/voxelworld:camera_position",
				on_camera_position, network::Packet)
	}

	void on_start()
	{
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

	void on_client_disconnected(const network::OldClient &old_client)
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
					"require(\"buildat/module/voxelworld\").init()");
		});
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_chunk_size_voxels);
			ar(m_section_size_chunks);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "voxelworld:init", os.str());
		});
	}

	void on_camera_position(const network::Packet &packet)
	{
		double px, py, pz;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(px, py, pz);
		}
		log_v(MODULE, "Camera position of C%i: (%f, %f, %f)",
				packet.sender, px, py, pz);
	}

	// Interface

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_voxelworld(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
