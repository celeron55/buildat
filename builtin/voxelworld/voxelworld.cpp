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
#include <Model.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Context.h>
#include <ResourceCache.h>
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
	int32_t x, y, z;
	archive(x, y, z);
	v.setX(x); v.setY(y); v.setZ(z);
}

}

// PolyVox logging helpers
// TODO: Move to a header (core/types_polyvox.h or something)
template<>
ss_ dump(const pv::Vector3DInt16 &v){
	std::ostringstream os(std::ios::binary);
	os<<"("<<v.getX()<<", "<<v.getY()<<", "<<v.getZ()<<")";
	return os.str();
}
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

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
					"network:packet_received/voxelworld:get_section"));

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
		EVENT_TYPEN("network:packet_received/voxelworld:get_section",
				on_get_section, network::Packet)
	}

	void on_start()
	{
		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();

			{
				Node *n = scene->CreateChild("Base");
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				n->SetPosition(Vector3(0.0f, 0.5f, 0.0f));

				int w = 10, h = 3, d = 10;
				ss_ data =
					"222222222211211111211111111111"
					"222222222211111111111111111111"
					"222222222211111111111111111111"
					"222222222211111111111111111111"
					"222222222211122111111112111111"
					"222233222211123111111112111111"
					"222233222211111111111111111111"
					"222222222211111111111111111111"
					"222222222211111111111111111111"
					"222222222211111111111111111111"
					;

				// Convert data to the actually usable voxel type id namespace
				// starting from VOXELTYPEID_UNDEFINED=0
				for(size_t i = 0; i < data.size(); i++){
					data[i] = data[i] - '0';
				}

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("buildat_voxel_data"), Variant(
							magic::String(data.c_str(), data.size())));
				n->SetVar(StringHash("buildat_voxel_w"), Variant(w));
				n->SetVar(StringHash("buildat_voxel_h"), Variant(h));
				n->SetVar(StringHash("buildat_voxel_d"), Variant(d));

				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::
						create_8bit_voxel_physics_model(context, w, h, d, data,
						m_voxel_reg.get()));

				RigidBody *body = n->CreateComponent<RigidBody>();
				body->SetFriction(0.75f);
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetTriangleMesh(model, 0, Vector3::ONE);
			}
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

	// TODO: How should nodes be filtered for replication?
	void on_get_section(const network::Packet &packet)
	{
		pv::Vector3DInt16 section_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(section_p);
		}
		log_v(MODULE, "C%i: on_get_section(): " PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(section_p));
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
