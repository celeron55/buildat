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
#include "interface/voxel_volume.h"
#include <PolyVoxCore/RawVolume.h>
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
#include <Light.h>
#include <Geometry.h>
#pragma GCC diagnostic pop
#include <deque>
#include <algorithm>

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;

namespace std {

template<> struct hash<pv::Vector<2u, int16_t>>{
	std::size_t operator()(const pv::Vector<2u, int16_t> &v) const {
		return ((std::hash<int16_t>() (v.getX()) << 0) ^
				   (std::hash<int16_t>() (v.getY()) << 1));
	}
};

template<> struct hash<pv::Vector<3u, int16_t>>{
	std::size_t operator()(const pv::Vector<3u, int16_t> &v) const {
		return ((std::hash<int16_t>() (v.getX()) << 0) ^
				   (std::hash<int16_t>() (v.getY()) << 1) ^
				   (std::hash<int16_t>() (v.getZ()) << 2));
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
template<>
ss_ dump(const pv::Vector3DInt32 &v){
	std::ostringstream os(std::ios::binary);
	os<<"("<<v.getX()<<", "<<v.getY()<<", "<<v.getZ()<<")";
	return os.str();
}
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

// TODO: Move to a header (core/numeric.h or something)
static inline int container_coord(int x, int d)
{
	return (x>=0 ? x : x-d+1) / d;
}
static inline pv::Vector3DInt32 container_coord(
		const pv::Vector3DInt32 &p, const pv::Vector3DInt32 &d)
{
	return pv::Vector3DInt32(
			container_coord(p.getX(), d.getX()),
			container_coord(p.getY(), d.getY()),
			container_coord(p.getZ(), d.getZ()));
}
static inline pv::Vector3DInt32 container_coord(
		const pv::Vector3DInt32 &p, const pv::Vector3DInt16 &d)
{
	return pv::Vector3DInt32(
			container_coord(p.getX(), d.getX()),
			container_coord(p.getY(), d.getY()),
			container_coord(p.getZ(), d.getZ()));
}
static inline pv::Vector3DInt16 container_coord16(
		const pv::Vector3DInt32 &p, const pv::Vector3DInt16 &d)
{
	return pv::Vector3DInt16(
			container_coord(p.getX(), d.getX()),
			container_coord(p.getY(), d.getY()),
			container_coord(p.getZ(), d.getZ()));
}

namespace voxelworld {

struct JournalEntry
{
	VoxelInstance v;
	pv::Vector3DInt32 p; // Global position

	JournalEntry(const VoxelInstance &v, const pv::Vector3DInt32 &p): v(v), p(p){}
};

struct Section
{
	pv::Vector3DInt16 section_p;// Position in sections
	pv::Vector3DInt16 chunk_size;
	pv::Region contained_chunks;// Position and size in chunks
	// Static voxel nodes (each contains one chunk); Initialized to 0.
	sp_<pv::RawVolume<int32_t>> node_ids;
	size_t num_chunks = 0;

	// Chunk write journals (push_back(), pop_front()) (z*h*w + y*w + x)
	sv_<std::deque<JournalEntry>> write_journals;

	// TODO: Specify what exactly do these mean and how they are used
	bool loaded = false;
	bool save_enabled = false;
	bool generated = false;

	Section(): // Needed for containers
		chunk_size(0, 0, 0) // This is used to detect uninitialized instance
	{}
	Section(pv::Vector3DInt16 section_p,
			pv::Vector3DInt16 chunk_size,
			pv::Region contained_chunks):
		section_p(section_p),
		chunk_size(chunk_size),
		contained_chunks(contained_chunks),
		node_ids(new pv::RawVolume<int32_t>(contained_chunks)),
		num_chunks(contained_chunks.getWidthInVoxels() *
				contained_chunks.getHeightInVoxels() *
				contained_chunks.getDepthInVoxels())
	{
		write_journals.resize(num_chunks);
	}

	size_t get_chunk_i(const pv::Vector3DInt32 &chunk_p); // global chunk_p
	pv::Vector3DInt32 get_chunk_p(size_t chunk_p);
};

size_t Section::get_chunk_i(const pv::Vector3DInt32 &chunk_p) // global chunk_p
{
	auto &lc = contained_chunks.getLowerCorner();
	pv::Vector3DInt32 local_p = chunk_p - lc;
	int32_t w = contained_chunks.getWidthInVoxels();
	int32_t h = contained_chunks.getHeightInVoxels();
	size_t i = local_p.getZ() * h * w + local_p.getY() * w + local_p.getX();
	if(i >= num_chunks)
		throw Exception(ss_()+"get_chunk_i: Section "+cs(section_p)+
				" does not contain chunk"+cs(chunk_p));
	return i;
}

pv::Vector3DInt32 Section::get_chunk_p(size_t chunk_i)
{
	int32_t w = contained_chunks.getWidthInVoxels();
	int32_t h = contained_chunks.getHeightInVoxels();
	pv::Vector3DInt32 p;
	p.setZ(chunk_i / h / w);
	p.setY(chunk_i / w - p.getZ() * h);
	p.setX(chunk_i - p.getZ() * h * w - p.getY() * w);
	return contained_chunks.getLowerCorner() + p;
}

struct Module: public interface::Module, public voxelworld::Interface
{
	interface::Server *m_server;

	// Accessing any of these outside of Server::access_scene is disallowed
	sp_<interface::TextureAtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;
	sp_<interface::BlockRegistry> m_block_reg;

	// One node holds one chunk of voxels (eg. 24x24x24)
	pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(32, 32, 32);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(24, 24, 24);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(16, 16, 16);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(8, 8, 8);

	// The world is loaded and unloaded by sections (eg. 2x2x2)
	pv::Vector3DInt16 m_section_size_chunks = pv::Vector3DInt16(2, 2, 2);

	// Sections (this(y,z)=sector, sector(x)=section)
	sm_<pv::Vector<2, int16_t>, sm_<int16_t, Section>> m_sections;
	// Cache of last used sections (add to end, remove from beginning)
	std::deque<Section*> m_last_used_sections;

	// Set of sections that have stuff in their journals
	// (as a sorted array in descending order)
	std::vector<Section*> m_section_journals_dirty;

	Module(interface::Server *server):
		interface::Module("voxelworld"),
		m_server(server)
	{
		m_voxel_reg.reset(interface::createVoxelRegistry());
		m_block_reg.reset(interface::createBlockRegistry(m_voxel_reg.get()));
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
		});

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
		pv::Region region(-3, -1, -3, 3, 1, 3);
		//pv::Region region(-8, -1, -8, 8, 1, 8);
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					load_or_generate_section(pv::Vector3DInt16(x, y, z));
				}
			}
		}
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
	// TODO: Generally the client wants roughly one section, but isn't
	//       positioned at the middle of a section
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

	// Get section if exists
	Section* get_section(const pv::Vector3DInt16 &section_p)
	{
		// Check cache
		for(Section *section : m_last_used_sections){
			if(section->section_p == section_p)
				return section;
		}
		// Not in cache
		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return nullptr;
		sm_<int16_t, Section> &sector = sector_it->second;
		auto section_it = sector.find(section_p.getX());
		if(section_it == sector.end())
			return nullptr;
		Section &section = section_it->second;
		// Add to cache and return
		m_last_used_sections.push_back(&section);
		if(m_last_used_sections.size() > 2) // 2 is maybe optimal-ish
			m_last_used_sections.pop_front();
		return &section;
	}

	// Get a section; allocate it if it doesn't exist yet
	Section& force_get_section(const pv::Vector3DInt16 &section_p)
	{
		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		sm_<int16_t, Section> &sector = m_sections[p_yz];
		Section &section = sector[section_p.getX()];
		if(section.chunk_size.getX() == 0){
			// Initialize newly created section properly
			pv::Region contained_chunks(
					section_p.getX() * m_section_size_chunks.getX(),
					section_p.getY() * m_section_size_chunks.getY(),
					section_p.getZ() * m_section_size_chunks.getZ(),
					(section_p.getX()+1) * m_section_size_chunks.getX() - 1,
					(section_p.getY()+1) * m_section_size_chunks.getY() - 1,
					(section_p.getZ()+1) * m_section_size_chunks.getZ() - 1
			);
			section = Section(section_p, m_chunk_size_voxels, contained_chunks);
		}
		return section;
	}

	void create_chunk_node(Scene *scene, Section &section, int x, int y, int z)
	{
		Context *context = scene->GetContext();

		pv::Vector3DInt16 section_p = section.section_p;
		pv::Vector3DInt32 chunk_p(
				section_p.getX() * m_section_size_chunks.getX() + x,
				section_p.getY() * m_section_size_chunks.getY() + y,
				section_p.getZ() * m_section_size_chunks.getZ() + z
		);

		Vector3 node_p(
				chunk_p.getX() * m_chunk_size_voxels.getX() +
						m_chunk_size_voxels.getX() / 2.0f,
				chunk_p.getY() * m_chunk_size_voxels.getY() +
						m_chunk_size_voxels.getY() / 2.0f,
				chunk_p.getZ() * m_chunk_size_voxels.getZ() +
						m_chunk_size_voxels.getZ() / 2.0f
		);
		log_t(MODULE, "create_chunk_node(): node_p=(%f, %f, %f)",
				node_p.x_, node_p.y_, node_p.z_);

		ss_ name = "static_"+dump(section_p)+")"+
				"_("+itos(x)+","+itos(y)+","+itos(x)+")";

		Node *n = scene->CreateChild(name.c_str());
		if(n->GetID() == 0)
			throw Exception("Can't handle static node id=0");
		section.node_ids->setVoxelAt(chunk_p, n->GetID());

		n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
		n->SetPosition(node_p);

		int w = m_chunk_size_voxels.getX();
		int h = m_chunk_size_voxels.getY();
		int d = m_chunk_size_voxels.getZ();

		// NOTE: These volumes have one extra voxel at each edge in order to
		//       make proper meshes without gaps
		pv::Region region(-1, -1, -1, w, h, d);
		pv::RawVolume<VoxelInstance> volume(region);

		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					volume.setVoxelAt(x, y, z, VoxelInstance(0));
				}
			}
		}

		ss_ data = interface::serialize_volume_compressed(volume);

		// TODO: Split data to multiple user variables if data doesn't compress
		//       to less than 500 or so bytes so that modifying a single voxel
		//       is more efficient
		n->SetVar(StringHash("buildat_voxel_data"), Variant(
				PODVector<uint8_t>((const uint8_t*)data.c_str(), data.size())));

		// There are no collision shapes initially, but add the rigid body now
		RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
		body->SetFriction(0.75f);
	}

	void create_section(Section &section)
	{
		m_server->access_scene([&](Scene *scene)
		{
			auto lc = section.contained_chunks.getLowerCorner();
			auto uc = section.contained_chunks.getUpperCorner();
			for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
				for(int y = 0; y <= uc.getY() - lc.getY(); y++){
					for(int x = 0; x <= uc.getX() - lc.getX(); x++){
						create_chunk_node(scene, section, x, y, z);
					}
				}
			}
		});
	}

	// Somehow get the section's static nodes and possible other nodes, either
	// by loading from disk or by creating new ones
	void load_section(Section &section)
	{
		if(section.loaded)
			return;
		section.loaded = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_v(MODULE, "Loading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		// TODO: If found on disk, load nodes from there
		// TODO: If not found on disk, create new static nodes
		// Always create new nodes for now
		create_section(section);
	}

	// Generate the section; requires static nodes to already exist
	void generate_section(Section &section)
	{
		if(section.generated)
			return;
		section.generated = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_v(MODULE, "Generating section " PV3I_FORMAT, PV3I_PARAMS(section_p));
		m_server->emit_event("voxelworld:generation_request",
				new GenerationRequest(section_p));
	}

	// Interface

	void load_or_generate_section(const pv::Vector3DInt16 &section_p)
	{
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
		if(!section.generated)
			generate_section(section);
	}

	pv::Region get_section_region(const pv::Vector3DInt16 &section_p)
	{
		pv::Vector3DInt32 p0 = pv::Vector3DInt32(
				section_p.getX() * m_section_size_chunks.getX() *
						m_chunk_size_voxels.getX(),
				section_p.getY() * m_section_size_chunks.getY() *
						m_chunk_size_voxels.getY(),
				section_p.getZ() * m_section_size_chunks.getZ() *
						m_chunk_size_voxels.getZ()
		);
		pv::Vector3DInt32 p1 = p0 + pv::Vector3DInt32(
				m_section_size_chunks.getX() * m_chunk_size_voxels.getX() - 1,
				m_section_size_chunks.getY() * m_chunk_size_voxels.getY() - 1,
				m_section_size_chunks.getZ() * m_chunk_size_voxels.getZ() - 1
		);
		return pv::Region(p0, p1);
	}

	void set_voxel_direct(const pv::Vector3DInt32 &p,
			const interface::VoxelInstance &v)
	{
		log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No section "
					" " PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}
		int32_t node_id = section->node_ids->getVoxelAt(chunk_p);
		if(node_id == 0){
			log_w(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: No node for "
					"chunk " PV3I_FORMAT " in section " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return;
		}

		// Have to commit first so that this modification doesn't get
		// overwritten by some older one
		// TODO: Commit only the modifications that affect this voxel
		commit();

		// Lol this is extremely wasteful
		m_server->access_scene([&](Scene *scene)
		{
			Node *n = scene->GetNode(node_id);
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			const PODVector<unsigned char> &buf = var.GetBuffer();
			ss_ data((const char*)&buf[0], buf.Size());
			up_<pv::RawVolume<VoxelInstance>> volume =
					interface::deserialize_volume(data);

			// NOTE: +1 offset needed for mesh generation
			pv::Vector3DInt32 voxel_p(
					p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX() + 1,
					p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY() + 1,
					p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ() + 1
			);
			log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: "
					"Chunk " PV3I_FORMAT " in section " PV3I_FORMAT
					"; internal position " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p), PV3I_PARAMS(voxel_p));
			volume->setVoxelAt(voxel_p, v);

			ss_ new_data = interface::serialize_volume_compressed(*volume);

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
							new_data.size())));
		});
	}

	void set_voxel(const pv::Vector3DInt32 &p, const interface::VoxelInstance &v)
	{
		log_t(MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_w(MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i: No section "
					" " PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}

		// Append to journal
		size_t chunk_i = section->get_chunk_i(chunk_p);
		section->write_journals[chunk_i].push_back(JournalEntry(v, p));

		// Set journal dirty flag
		auto dirty_it = std::lower_bound(m_section_journals_dirty.begin(),
				m_section_journals_dirty.end(), section,
				std::greater<Section*>()); // position in descending order
		if(dirty_it == m_section_journals_dirty.end() || *dirty_it != section)
			m_section_journals_dirty.insert(dirty_it, section);
	}

	void commit_chunk_journal(Section *section, size_t chunk_i)
	{
		pv::Vector3DInt32 chunk_p = section->get_chunk_p(chunk_i);

		int32_t node_id = section->node_ids->getVoxelAt(chunk_p);
		if(node_id == 0){
			log_w(MODULE, "commit_chunk_journal() chunk_i=%zu: "
					"No node found for chunk " PV3I_FORMAT
					" in section " PV3I_FORMAT,
					chunk_i, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section->section_p));
			return;
		}

		auto &write_journal = section->write_journals[chunk_i];

		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();

			Node *n = scene->GetNode(node_id);
			if(!n){
				log_w(MODULE, "commit_chunk_journal(): Node %i not found",
						node_id);
				return;
			}
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			const PODVector<unsigned char> &buf = var.GetBuffer();
			ss_ data((const char*)&buf[0], buf.Size());
			up_<pv::RawVolume<VoxelInstance>> volume =
					interface::deserialize_volume(data);

			for(const JournalEntry &entry : write_journal){
				const pv::Vector3DInt32 &p = entry.p;
				const interface::VoxelInstance &v = entry.v;
				// NOTE: +1 offset needed for mesh generation
				pv::Vector3DInt32 voxel_p(
						p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX() + 1,
						p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY() + 1,
						p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ() + 1
				);
				volume->setVoxelAt(voxel_p, v);
			}

			ss_ new_data = interface::serialize_volume_compressed(*volume);

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
							new_data.size())));

			// Update collision shape

			interface::set_voxel_physics_boxes(n, context, *volume,
					m_voxel_reg.get());
		});
	}

	void commit()
	{
		log_v(MODULE, "commit(): %zu section journals dirty",
				m_section_journals_dirty.size());
		for(Section *section : m_section_journals_dirty){
			for(size_t i = 0; i < section->write_journals.size(); i++){
				commit_chunk_journal(section, i);
			}
		}
		m_section_journals_dirty.clear();
	}

	VoxelInstance get_voxel(const pv::Vector3DInt32 &p)
	{
		// TODO
		// TODO: Check journal first
		return VoxelInstance(0);
	}

	interface::VoxelRegistry* get_voxel_reg()
	{
		return m_voxel_reg.get();
	}

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
