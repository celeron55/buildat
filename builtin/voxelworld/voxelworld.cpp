// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "voxelworld/api.h"
#include "network/api.h"
#include "client_file/api.h"
#include "replicate/api.h"
#include "main_context/api.h"
#include "core/log.h"
#include <chrono>
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/block.h"
#include "interface/voxel_volume.h"
#include "interface/polyvox_numeric.h"
#include "interface/polyvox_cereal.h"
#include "interface/polyvox_std.h"
#include "interface/os.h"
#include <PolyVoxCore/RawVolume.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <Node.h>
#include <Scene.h>
#include <Model.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <Context.h>
#include <ResourceCache.h>
#include <Light.h>
#include <Geometry.h>
#include <Zone.h>
#include <deque>
#include <algorithm>
#define MODULE "voxelworld"

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;
using interface::container_coord;
using interface::container_coord16;

namespace voxelworld {

struct ChunkBuffer
{
	pv::Vector3DInt32 chunk_p; // For logging
	up_<pv::RawVolume<VoxelInstance>> volume;
	bool dirty = false; // If false, buffer has only been read from so far
	int64_t last_accessed_us = 0;

	ChunkBuffer(){}
	void timer_reset(const pv::Vector3DInt32 &chunk_p_){
		chunk_p = chunk_p_;
		last_accessed_us = interface::os::time_us();
	}
	bool unload_if_old(int64_t timeout_us){ // True if not loaded
		if(!volume)
			return true;
		if(interface::os::time_us() < last_accessed_us + timeout_us)
			return false;
		log_t(MODULE, "Unloading chunk " PV3I_FORMAT, PV3I_PARAMS(chunk_p));
		volume.reset();
		dirty = false;
		return true;
	}
};

struct Section
{
	SceneReference m_scene_ref;
	pv::Vector3DInt16 section_p; // Position in sections
	pv::Vector3DInt16 chunk_size;
	pv::Region contained_chunks; // Position and size in chunks
	// Static voxel nodes (each contains one chunk); Initialized to 0.
	sp_<pv::RawVolume<uint32_t>> node_ids;
	size_t num_chunks = 0;
	// Cache these for speed
	int w_chunks = 0;
	int h_chunks = 0;
	int d_chunks = 0;

	// Chunk buffers (index using get_chunk_i())
	sv_<ChunkBuffer> chunk_buffers;

	// TODO: Specify what exactly do these mean and how they are used
	bool loaded = false;
	bool save_enabled = false;
	bool generated = false;

	Section(): // Needed for containers
		chunk_size(0, 0, 0) // This is used to detect uninitialized instance
	{}
	Section(SceneReference scene_ref,
			pv::Vector3DInt16 section_p,
			pv::Vector3DInt16 chunk_size,
			pv::Region contained_chunks):
		m_scene_ref(scene_ref),
		section_p(section_p),
		chunk_size(chunk_size),
		contained_chunks(contained_chunks),
		node_ids(new pv::RawVolume<uint32_t>(contained_chunks)),
		num_chunks(contained_chunks.getWidthInVoxels() *
				contained_chunks.getHeightInVoxels() *
				contained_chunks.getDepthInVoxels())
	{
		chunk_buffers.resize(num_chunks);
		// Cache these for speed
		w_chunks = contained_chunks.getWidthInVoxels();
		h_chunks = contained_chunks.getHeightInVoxels();
		d_chunks = contained_chunks.getDepthInVoxels();
	}

	size_t get_chunk_i(const pv::Vector3DInt32 &chunk_p); // global chunk_p
	pv::Vector3DInt32 get_chunk_p(size_t chunk_p);

	ChunkBuffer& get_buffer(const pv::Vector3DInt32 &chunk_p,
			interface::Server *server, size_t *total_buffers_loaded);
};

size_t Section::get_chunk_i(const pv::Vector3DInt32 &chunk_p) // global chunk_p
{
	auto &lc = contained_chunks.getLowerCorner();
	// NOTE: pv::Vector3DInt32 operators and getters are too slow
	int local_x = chunk_p.getX() - lc.getX();
	int local_y = chunk_p.getY() - lc.getY();
	int local_z = chunk_p.getZ() - lc.getZ();
	const int &w = w_chunks;
	const int &h = h_chunks;
	size_t i = local_z * h * w + local_y * w + local_x;
	if(i >= num_chunks) // NOTE: This is not accurate but it is safe and fast
		throw Exception(ss_()+"get_chunk_i: Section "+cs(section_p)+
				" does not contain chunk"+cs(chunk_p));
	return i;
}

pv::Vector3DInt32 Section::get_chunk_p(size_t chunk_i)
{
	const int &w = w_chunks;
	const int &h = h_chunks;
	pv::Vector3DInt32 p;
	p.setZ(chunk_i / h / w);
	p.setY(chunk_i / w - p.getZ() * h);
	p.setX(chunk_i - p.getZ() * h * w - p.getY() * w);
	return contained_chunks.getLowerCorner() + p;
}

ChunkBuffer& Section::get_buffer(const pv::Vector3DInt32 &chunk_p,
		interface::Server *server, size_t *total_buffers_loaded)
{
	size_t chunk_i = get_chunk_i(chunk_p);
	ChunkBuffer &buf = chunk_buffers[chunk_i];
	buf.timer_reset(chunk_p);
	// If loaded, return right away
	if(buf.volume)
		return buf;
	// Not loaded.
	// Get the static voxel node from the scene and read the volume from it
	int32_t node_id = node_ids->getVoxelAt(chunk_p);
	if(node_id == 0){
		log_w(MODULE, "Section::get_buffer(): No node found for chunk "
				PV3I_FORMAT " in section " PV3I_FORMAT,
				PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
		return buf;
	}
	log_t(MODULE, "Loading chunk " PV3I_FORMAT " (node %i)",
			PV3I_PARAMS(chunk_p), node_id);

	main_context::access(server, [&](main_context::Interface *imc)
	{
		Scene *scene = imc->check_scene(m_scene_ref);
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE,
					"Section::get_buffer(): Node %i not found in scene "
					"for chunk " PV3I_FORMAT " in section " PV3I_FORMAT,
					node_id, PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
			return;
		}
		const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
		const PODVector<unsigned char> &rawbuf = var.GetBuffer();
		ss_ data((const char*)&rawbuf[0], rawbuf.Size());
		buf.volume = interface::deserialize_volume(data);
		if(!buf.volume){
			log_w(MODULE,
					"Section::get_buffer(): Voxel volume could not be "
					"loaded from node %i for chunk "
					PV3I_FORMAT " in section " PV3I_FORMAT,
					node_id, PV3I_PARAMS(chunk_p), PV3I_PARAMS(section_p));
			return;
		}
	});
	(*total_buffers_loaded)++;
	return buf;
}

struct QueuedNodePhysicsUpdate
{
	uint node_id = 0;
	// TODO bool is_static_chunk = false;
	// TODO pv::Vector3DInt32 chunk_p; // Only set if is_static_chunk == true

	QueuedNodePhysicsUpdate(const uint &node_id):
		node_id(node_id){}
	bool operator>(const QueuedNodePhysicsUpdate &other) const {
		return node_id > other.node_id;
	}
};

// Skylight neighbour offsets. The last pair is +Y and -Y; LIGHT_DOWN is
// straight down, the one direction light falls through without losing any.
static const int LIGHT_OFF[6][3] = {
	{1,0,0}, {-1,0,0}, {0,0,1}, {0,0,-1}, {0,1,0}, {0,-1,0}
};
static const size_t LIGHT_DOWN = 5;

struct CInstance: public voxelworld::Instance
{
	interface::Server *m_server;

	SceneReference m_scene_ref;

	// Clients that are ready to receive things (by peer id)
	set_<int> m_clients_initialized;

	// Accessing any of these outside of Server::access_scene is disallowed
	sp_<interface::AtlasRegistry> m_atlas_reg;
	sp_<interface::VoxelRegistry> m_voxel_reg;
	sp_<interface::BlockRegistry> m_block_reg;

	sv_<up_<CommitHook>> m_commit_hooks;

	// One node holds one chunk of voxels (eg. 24x24x24)
	pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(32, 32, 32);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(24, 24, 24);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(16, 16, 16);
	//pv::Vector3DInt16 m_chunk_size_voxels = pv::Vector3DInt16(8, 8, 8);

	// The world is loaded and unloaded by sections (eg. 2x2x2)
	pv::Vector3DInt16 m_section_size_chunks = pv::Vector3DInt16(2, 2, 2);

	int64_t m_buffer_unload_timeout = 5000000;
	size_t m_max_buffers_loaded = 50;

	// Sections (this(y,z)=sector, sector(x)=section)
	sm_<pv::Vector<2, int16_t>, sm_<int16_t, Section>> m_sections;
	// Cache of last used sections (add to end, remove from beginning)
	std::deque<Section*> m_last_used_sections;

	// Set of sections that have buffers allocated
	// (as a sorted array in descending order)
	std::vector<Section*> m_sections_with_loaded_buffers;
	size_t m_total_buffers_loaded = 0;
	size_t m_total_buffers_dirty = 0;

	// Set of nodes by node_id that need set_voxel_physics_boxes()
	// (as a sorted array in descending node_id order)
	std::vector<QueuedNodePhysicsUpdate> m_nodes_needing_physics_update;

	// Skylight. Off unless the world asks for it; see api.h.
	bool m_skylight_enabled = false;
	bool m_physics_enabled;
	// The world region in sections, so that the top of it can be found. Light
	// enters from above that; everything outside is a barrier.
	pv::Region m_section_region;
	// Voxels that started or stopped transmitting light since the last commit,
	// with what they were before, because the new voxel has already replaced
	// the old light value by the time this is looked at.
	struct SkylightSeed
	{
		pv::Vector3DInt32 p;
		uint8_t old_level;
		bool was_transparent;
	};
	std::vector<SkylightSeed> m_skylight_seeds;

	CInstance(interface::Server *server, SceneReference scene_ref,
			const pv::Region &region, bool physics_enabled):
		m_server(server),
		m_scene_ref(scene_ref),
		m_section_region(region),
		m_physics_enabled(physics_enabled)
	{
		m_voxel_reg.reset(interface::createVoxelRegistry());
		m_block_reg.reset(interface::createBlockRegistry(m_voxel_reg.get()));

		main_context::access(m_server, [&](main_context::Interface *imc){
			Context *context = imc->get_context();

			m_atlas_reg.reset(interface::createAtlasRegistry(context));
		});

		// TODO: Load from disk or something

		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					load_or_generate_section(pv::Vector3DInt16(x, y, z));
				}
			}
		}

		// Find peers that already are on the scene and iniitalize them
		sv_<replicate::PeerId> peers;
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			peers = ireplicate->find_peers_on_scene(m_scene_ref);
		});
		ss_ peers_s = dump(peers);
		log_v(MODULE, "Existing peers on scene: %s", cs(peers_s));
		for(auto &peer : peers){
			initialize_peer(peer);
		}
	}

	~CInstance()
	{
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene);
		EVENT_TYPEN("replicate:peer_left_scene", on_peer_left_scene,
				replicate::PeerLeftScene);
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		/*EVENT_TYPEN("network:packet_received/voxelworld:get_section",
				on_get_section, network::Packet)*/
	}

	void on_tick(const interface::TickEvent &event)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->find_scene(m_scene_ref);
			if(!scene){
				// Scene was deleted; hope that Module deletes us at some point
				return;
			}

			Context *context = imc->get_context();

			// Update node collision boxes
			if(!m_nodes_needing_physics_update.empty()){
				log_v(MODULE, "Updating physics of %zu nodes",
						m_nodes_needing_physics_update.size());
			}
			for(QueuedNodePhysicsUpdate &update: m_nodes_needing_physics_update){
				uint node_id = update.node_id;
				Node *n = scene->GetNode(node_id);
				if(!n){
					log_w(MODULE, "on_tick(): Node physics update: "
							"Node %i not found", node_id);
					continue;
				}
				// Get volume
				const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
				const PODVector<unsigned char> &rawbuf = var.GetBuffer();
				ss_ data((const char*)&rawbuf[0], rawbuf.Size());
				up_<pv::RawVolume<VoxelInstance>> volume =
						interface::deserialize_volume(data);
				// Update collision shape
				interface::mesh::set_voxel_physics_boxes(n, context, *volume,
						m_voxel_reg.get());
			}
			m_nodes_needing_physics_update.clear();
		});

		// Unload stuff if needed
		maintain_maximum_buffer_limit();

		// Send updated voxel registry if needed
		send_voxel_registry_if_dirty();
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
		initialize_peer(event.peer);
	}

	void on_peer_left_scene(const replicate::PeerLeftScene &event)
	{
		m_clients_initialized.erase(event.peer);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
	}

	// TODO: How should nodes be filtered for replication?
	// TODO: Generally the client wants roughly one section, but isn't
	//       positioned at the middle of a section
	/*void on_get_section(const network::Packet &packet)
	{
		pv::Vector3DInt16 section_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(section_p);
		}
		log_v(MODULE, "C%i: on_get_section(): " PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(section_p));
	}*/

	void initialize_peer(replicate::PeerId peer)
	{
		log_v(MODULE, "Initializing peer %i", peer);
		// Load the client-side module (can be called multiple times)
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:run_script",
					"require(\"buildat/module/voxelworld\")");
		});
		// Send initialization data and tell the client that it is now ready
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_chunk_size_voxels);
			ar(m_section_size_chunks);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "voxelworld:init", os.str());
			inetwork->send(peer, "voxelworld:voxel_registry",
					m_voxel_reg->serialize());
			inetwork->send(peer, "voxelworld:ready", "");
		});
		m_clients_initialized.insert(peer);
	}

	void unload_node(Scene *scene, uint node_id)
	{
		log_d(MODULE, "Unloading node %i", node_id);
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE, "Cannot unload node %i: Not found in scene", node_id);
			return;
		}
		// Remove RigidBody first to speed up removal of CollisionShapes
		RigidBody *body = n->GetComponent<RigidBody>();
		if(body)
			n->RemoveComponent(body);
		// Remove everything else
		n->RemoveAllComponents();
		n->Remove();
	}

	void send_voxel_registry_if_dirty()
	{
		// Send updated voxel registry if needed
		// NOTE: This probably really only supports additions
		if(m_voxel_reg->is_dirty()){
			m_voxel_reg->clear_dirty();
			log_v(MODULE, "Sending updated voxel registry to peers");

			ss_ voxel_reg_data = m_voxel_reg->serialize();

			network::access(m_server, [&](network::Interface *inetwork){
				for(auto &peer: m_clients_initialized){
					inetwork->send(peer, "voxelworld:voxel_registry",
							voxel_reg_data);
				}
			});
		}
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
			section = Section(m_scene_ref, section_p, m_chunk_size_voxels,
					contained_chunks);
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
				m_chunk_size_voxels.getX() / 2.0f - 0.5f,
				chunk_p.getY() * m_chunk_size_voxels.getY() +
				m_chunk_size_voxels.getY() / 2.0f - 0.5f,
				chunk_p.getZ() * m_chunk_size_voxels.getZ() +
				m_chunk_size_voxels.getZ() / 2.0f - 0.5f
		);

		ss_ name = "static_"+dump(chunk_p);

		log_t(MODULE, "create_chunk_node(): node_p=(%f, %f, %f), name=\"%s\"",
				node_p.x_, node_p.y_, node_p.z_, cs(name));

		Node *n = scene->CreateChild(name.c_str());
		if(n->GetID() == 0)
			throw Exception("Can't handle static node id=0");
		section.node_ids->setVoxelAt(chunk_p, n->GetID());

		// Distinguish static voxel nodes from others
		n->SetVar(StringHash("buildat_static"), Variant(true));

		int w = m_chunk_size_voxels.getX();
		int h = m_chunk_size_voxels.getY();
		int d = m_chunk_size_voxels.getZ();

		// This makes sure the node will be found when searched from the octree,
		// both on the server and the client
		Zone *node_zone = n->CreateComponent<Zone>();
		node_zone->SetPriority(-1000);
		node_zone->SetBoundingBox(BoundingBox(
				Vector3(-w/2, -h/2, -d/2), Vector3(w/2, h/2, d/2)));

		n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
		n->SetPosition(node_p);

		// NOTE: These volumes have one extra voxel at each edge in order to
		//       make proper meshes without gaps
		// TODO: Is this needed anymore?
		pv::Region region(-1, -1, -1, w, h, d);
		sp_<pv::RawVolume<VoxelInstance>> volume(
				new pv::RawVolume<VoxelInstance>(region));

		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					volume->setVoxelAt(x, y, z, VoxelInstance(0));
				}
			}
		}

		run_commit_hooks_in_thread(chunk_p, *volume);

		ss_ data = interface::serialize_volume_compressed(*volume);
		n->SetVar(StringHash("buildat_voxel_data"), Variant(
				PODVector<uint8_t>((const uint8_t*)data.c_str(), data.size())));

		run_commit_hooks_in_scene(chunk_p, n);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, n->GetID(), true, chunk_p));

		// There are no collision shapes initially, but add the rigid body now
		if(m_physics_enabled){
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetFriction(0.75f);
		}
	}

	void create_section(Section &section)
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
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
		log_d(MODULE, "Loading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

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
		log_v(MODULE, "Section will be generated: " PV3I_FORMAT,
				PV3I_PARAMS(section_p));
		m_server->emit_event("voxelworld:generation_request",
				new GenerationRequest(m_scene_ref, section_p));
	}

	void mark_node_for_physics_update(uint node_id)
	{
		if(!m_physics_enabled)
			return;
		QueuedNodePhysicsUpdate update(node_id);
		auto it = std::lower_bound(m_nodes_needing_physics_update.begin(),
				m_nodes_needing_physics_update.end(), update,
				std::greater<QueuedNodePhysicsUpdate>());
		if(it == m_nodes_needing_physics_update.end()){
			m_nodes_needing_physics_update.insert(it, update);
		} else if(it->node_id != node_id){
			m_nodes_needing_physics_update.insert(it, update);
		} else {
			*it = update;
		}
	}

	// Should be called before the volume is serialized so that the hook can
	// modify the volume
	void run_commit_hooks_in_thread(
			const pv::Vector3DInt32 &chunk_p,
			pv::RawVolume<VoxelInstance> &volume)
	{
		for(up_<CommitHook> &hook : m_commit_hooks)
			hook->in_thread(this, chunk_p, volume);
	}

	void run_commit_hooks_in_scene(
			const pv::Vector3DInt32 &chunk_p, Node *n)
	{
		for(up_<CommitHook> &hook : m_commit_hooks)
			hook->in_scene(this, chunk_p, n);
	}

	void unload_old_buffers(int64_t unload_timeout, size_t max_buffers)
	{
		// Swap out the current set
		std::vector<Section*> sections_with_loaded_buffers;
		sections_with_loaded_buffers.swap(m_sections_with_loaded_buffers);
		// Allocate a new set to put back stuff that is still loaded
		m_sections_with_loaded_buffers.reserve(
				sections_with_loaded_buffers.size());
		// Go through the swapped set, putting back sections that are still loaded
		m_total_buffers_loaded = 0;
		m_total_buffers_dirty = 0;
		for(Section *section : sections_with_loaded_buffers){
			size_t num_loaded = 0;
			for(size_t i = 0; i < section->chunk_buffers.size(); i++){
				ChunkBuffer &chunk_buffer = section->chunk_buffers[i];
				bool unloaded = chunk_buffer.unload_if_old(unload_timeout);
				if(!unloaded){
					num_loaded++;
					m_total_buffers_loaded++;
					if(chunk_buffer.dirty)
						m_total_buffers_dirty++;
				}
			}
			if(num_loaded > 0)
				m_sections_with_loaded_buffers.push_back(section);
		}
		// Call recursively if too many buffers are still loaded
		if(unload_timeout > 1000 && m_total_buffers_loaded > max_buffers)
			unload_old_buffers(unload_timeout / 4, max_buffers);
	}

	void maintain_maximum_buffer_limit()
	{
		if(m_total_buffers_loaded > m_max_buffers_loaded)
			unload_old_buffers(m_buffer_unload_timeout, m_max_buffers_loaded);
	}

	// Interface

	interface::VoxelRegistry* get_voxel_reg()
	{
		return m_voxel_reg.get();
	}

	// Which bits of a voxel the sky light is in, which is the game's to
	// decide; see VoxelFormat in interface/voxel.h. A game sets its format
	// through get_voxel_reg()->set_format() before it generates anything,
	// so this is read rather than cached.
	const interface::VoxelField& sky_field()
	{
		return m_voxel_reg->get_format().light_sky;
	}

	uint8_t sky_max()
	{
		return (uint8_t)sky_field().mask();
	}

	uint8_t get_sky(const VoxelInstance &v)
	{
		return (uint8_t)sky_field().get(v.data);
	}

	void set_sky(VoxelInstance &v, uint8_t level)
	{
		sky_field().set(v.data, level);
	}

	void add_commit_hook(up_<CommitHook> hook)
	{
		m_commit_hooks.push_back(std::move(hook));
	}

	pv::Vector3DInt16 get_section_size_voxels()
	{
		return pv::Vector3DInt16(
				m_section_size_chunks.getX() * m_chunk_size_voxels.getX(),
				m_section_size_chunks.getY() * m_chunk_size_voxels.getY(),
				m_section_size_chunks.getZ() * m_chunk_size_voxels.getZ()
		);
	}

	pv::Region get_section_region_voxels(const pv::Vector3DInt16 &section_p)
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

	const pv::Vector3DInt16& get_chunk_size_voxels()
	{
		return m_chunk_size_voxels;
	}

	pv::Region get_chunk_region_voxels(const pv::Vector3DInt32 &chunk_p)
	{
		pv::Vector3DInt32 p0 = pv::Vector3DInt32(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		pv::Vector3DInt32 p1 = p0 + pv::Vector3DInt32(
				m_chunk_size_voxels.getX() - 1,
				m_chunk_size_voxels.getY() - 1,
				m_chunk_size_voxels.getZ() - 1
		);
		return pv::Region(p0, p1);
	}

	void load_or_generate_section(const pv::Vector3DInt16 &section_p)
	{
		Section &section = force_get_section(section_p);
		if(!section.loaded)
			load_section(section);
		if(!section.generated)
			generate_section(section);
	}

	void unload_section(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		if(!section || !section->loaded)
			return;

		log_v(MODULE, "Unloading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		for(ChunkBuffer &buf : section->chunk_buffers){
			if(!buf.volume)
				continue;
			m_total_buffers_loaded--;
			if(buf.dirty)
				m_total_buffers_dirty--;
			buf.volume.reset();
			buf.dirty = false;
		}

		m_last_used_sections.erase(
				std::remove(m_last_used_sections.begin(),
				m_last_used_sections.end(), section),
				m_last_used_sections.end());
		m_sections_with_loaded_buffers.erase(
				std::remove(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section),
				m_sections_with_loaded_buffers.end());

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section->contained_chunks.getLowerCorner();
			auto uc = section->contained_chunks.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						uint id = section->node_ids->getVoxelAt(x, y, z);
						if(id)
							unload_node(scene, id);
					}
				}
			}
		});

		pv::Vector<2, int16_t> p_yz(section_p.getY(), section_p.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return;
		sector_it->second.erase(section_p.getX());
		if(sector_it->second.empty())
			m_sections.erase(sector_it);
	}

	bool is_section_loaded(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		return section && section->loaded;
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
		// TODO: Commit only the current chunk
		commit();

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			Node *n = scene->GetNode(node_id);
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			const PODVector<unsigned char> &buf = var.GetBuffer();
			ss_ data((const char*)&buf[0], buf.Size());
			up_<pv::RawVolume<VoxelInstance>> volume =
					interface::deserialize_volume(data);

			pv::Vector3DInt32 voxel_p(
					p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
					p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
					p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
			);
			log_t(MODULE, "set_voxel_direct() p=" PV3I_FORMAT ", v=%i: "
					"Chunk " PV3I_FORMAT " in section " PV3I_FORMAT
					"; internal position " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p), PV3I_PARAMS(voxel_p));
			volume->setVoxelAt(voxel_p, v);

			run_commit_hooks_in_thread(chunk_p, *volume);

			ss_ new_data = interface::serialize_volume_compressed(*volume);

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
					new_data.size())));

			run_commit_hooks_in_scene(chunk_p, n);
		});

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, node_id, true, chunk_p));
	}

	void set_voxel(const pv::Vector3DInt32 &p, const interface::VoxelInstance &v,
			bool disable_warnings)
	{
		// Don't log here; this is a too busy place for even ignored log calls
		/*log_t(MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i",
				PV3I_PARAMS(p), v.data);*/
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i: No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), v.data, PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return;
		}

		// Unload stuff if needed
		maintain_maximum_buffer_limit();

		// Set in buffer
		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "set_voxel() p=" PV3I_FORMAT ", v=%i: Couldn't get "
					"buffer volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, PV3I_PARAMS(p), v.data, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return;
		}
		pv::Vector3DInt32 voxel_p(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		VoxelInstance nv = v;
		if(m_skylight_enabled){
			VoxelInstance old = buf.volume->getVoxelAt(voxel_p);
			bool old_transparent = voxel_transmits_light(old);
			if(old_transparent != voxel_transmits_light(v)){
				m_skylight_seeds.push_back(SkylightSeed{
						p, get_sky(old), old_transparent});
			}
			// Once skylight is on those bits belong to voxelworld, so they
			// are carried over from the voxel that was there; a caller writing
			// a plain voxel would otherwise wipe the light out of one whose
			// transparency did not change, and nothing would put it back
			set_sky(nv, get_sky(old));
		}

		buf.volume->setVoxelAt(voxel_p, nv);

		// Set buffer dirty
		if(!buf.dirty){
			buf.dirty = true;
			m_total_buffers_dirty++;
		}

		// Set section buffer loaded flag
		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>()); // position in descending order
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);
	}

	// See the comment on Instance::merge_volume() in api.h for what the
	// priorities are. This is chunk by chunk rather than voxel by voxel
	// through set_voxel(): a section is a quarter of a million voxels, and
	// all of this is done while holding the module.
	void merge_volume(const pv::RawVolume<VoxelInstance> &volume,
			bool create_missing_sections)
	{
		const pv::Region region = volume.getEnclosingRegion();
		auto rlc = region.getLowerCorner();
		auto ruc = region.getUpperCorner();
		pv::Vector3DInt32 chunk_lc = container_coord(rlc, m_chunk_size_voxels);
		pv::Vector3DInt32 chunk_uc = container_coord(ruc, m_chunk_size_voxels);

		size_t num_written = 0;
		for(int cz = chunk_lc.getZ(); cz <= chunk_uc.getZ(); cz++){
		for(int cy = chunk_lc.getY(); cy <= chunk_uc.getY(); cy++){
		for(int cx = chunk_lc.getX(); cx <= chunk_uc.getX(); cx++){
			pv::Vector3DInt32 chunk_p(cx, cy, cz);
			pv::Vector3DInt16 section_p =
					container_coord16(chunk_p, m_section_size_chunks);
			Section *section = get_section(section_p);
			if(section == nullptr || !section->loaded){
				if(!create_missing_sections)
					continue;
				// Created but not generated: the voxels are undefined apart
				// from what this volume writes, and generate_section() will
				// still ask for the rest when someone wants this section
				Section &new_section = force_get_section(section_p);
				if(!new_section.loaded)
					load_section(new_section);
				section = &new_section;
			}
			ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded);
			if(!buf.volume){
				log_d(MODULE, "merge_volume(): No buffer volume for chunk "
						PV3I_FORMAT, PV3I_PARAMS(chunk_p));
				continue;
			}

			pv::Region chunk_region = get_chunk_region_voxels(chunk_p);
			pv::Vector3DInt32 lc = chunk_region.getLowerCorner();
			pv::Vector3DInt32 uc = chunk_region.getUpperCorner();
			// The part of this chunk the volume actually covers
			if(lc.getX() < rlc.getX()) lc.setX(rlc.getX());
			if(lc.getY() < rlc.getY()) lc.setY(rlc.getY());
			if(lc.getZ() < rlc.getZ()) lc.setZ(rlc.getZ());
			if(uc.getX() > ruc.getX()) uc.setX(ruc.getX());
			if(uc.getY() > ruc.getY()) uc.setY(ruc.getY());
			if(uc.getZ() > ruc.getZ()) uc.setZ(ruc.getZ());

			pv::Vector3DInt32 chunk_off(
					chunk_p.getX() * m_chunk_size_voxels.getX(),
					chunk_p.getY() * m_chunk_size_voxels.getY(),
					chunk_p.getZ() * m_chunk_size_voxels.getZ());

			// Both volumes are walked by a sampler, which holds a pointer
			// into the data and moves it by one per step, rather than by
			// getVoxelAt()/setVoxelAt(), which work out the index from the
			// coordinates every time. Luanti's VoxelManipulator walks its
			// own index the same way, and for a whole section of voxels the
			// difference is the bulk of the work.
			pv::RawVolume<VoxelInstance>::Sampler src(
					const_cast<pv::RawVolume<VoxelInstance>*>(&volume));
			pv::RawVolume<VoxelInstance>::Sampler dst(buf.volume.get());

			bool chunk_written = false;
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				src.setPosition(lc.getX(), y, z);
				dst.setPosition(
						lc.getX() - chunk_off.getX(),
						y - chunk_off.getY(),
						z - chunk_off.getZ());
			for(int x = lc.getX(); x <= uc.getX(); x++,
					src.movePositiveX(), dst.movePositiveX()){
				VoxelInstance nv = src.getVoxel();
				if(nv.get_id() == interface::VOXELTYPEID_UNDEFINED)
					continue;
				VoxelInstance old = dst.getVoxel();
				bool old_undefined =
						(old.get_id() == interface::VOXELTYPEID_UNDEFINED);
				if(!old_undefined){
					// Anything already standing here wins
					if(!voxel_is_fully_empty(old))
						continue;
					// Empty stays empty unless something is put in it
					if(voxel_is_fully_empty(nv))
						continue;
				}

				if(m_skylight_enabled){
					bool old_transparent = voxel_transmits_light(old);
					if(old_transparent != voxel_transmits_light(nv)){
						m_skylight_seeds.push_back(SkylightSeed{
								pv::Vector3DInt32(x, y, z),
								get_sky(old), old_transparent});
					}
					set_sky(nv, get_sky(old));
				}

				dst.setVoxel(nv);
				chunk_written = true;
				num_written++;
			}
			}
			}

			if(chunk_written){
				if(!buf.dirty){
					buf.dirty = true;
					m_total_buffers_dirty++;
				}
				auto it = std::lower_bound(
						m_sections_with_loaded_buffers.begin(),
						m_sections_with_loaded_buffers.end(), section,
						std::greater<Section*>());
				if(it == m_sections_with_loaded_buffers.end() ||
						*it != section)
					m_sections_with_loaded_buffers.insert(it, section);
			}
		}
		}
		}

		// Buffers were loaded above; keep to the limit once, not per voxel
		maintain_maximum_buffer_limit();

		log_d(MODULE, "merge_volume(): %zu voxels written", num_written);
	}

	// Read a voxel without loading anything or touching any bookkeeping, so
	// that it is safe to call while chunk buffers are being committed. A chunk
	// that is not in memory reads as undefined.
	VoxelInstance peek_voxel(const pv::Vector3DInt32 &p)
	{
		const VoxelInstance undefined(interface::VOXELTYPEID_UNDEFINED);
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr)
			return undefined;
		ChunkBuffer &buf =
				section->chunk_buffers[section->get_chunk_i(chunk_p)];
		if(!buf.volume)
			return undefined;
		return buf.volume->getVoxelAt(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ());
	}

	// Fill the one voxel of padding around a chunk from the chunks next to it.
	// The mesher needs it to see what is on the other side of a chunk edge;
	// with the padding left empty, every face there is meshed against nothing,
	// and anything the mesher reads per voxel, such as skylight or the
	// neighbours ambient occlusion counts, breaks along chunk boundaries.
	//
	// Taken from whatever is loaded; a neighbour that is not in memory leaves
	// its side undefined, which is what the mesher falls back on anyway.
	// Nothing is written back to the neighbours, so a voxel changed at a chunk
	// edge leaves the neighbour's copy of it stale until that neighbour is
	// committed in turn.
	void fill_chunk_padding(const pv::Vector3DInt32 &chunk_p,
			pv::RawVolume<VoxelInstance> &volume)
	{
		const pv::Region &region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		const pv::Vector3DInt32 chunk_lc(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ());
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			bool z_edge = (z == lc.getZ() || z == uc.getZ());
			for(int y = lc.getY(); y <= uc.getY(); y++){
				bool y_edge = (y == lc.getY() || y == uc.getY());
				// Skip straight across the interior of each row
				int x_step = (z_edge || y_edge) ? 1 :
						uc.getX() - lc.getX();
				for(int x = lc.getX(); x <= uc.getX(); x += x_step){
					volume.setVoxelAt(x, y, z, peek_voxel(
							pv::Vector3DInt32(chunk_lc.getX() + x,
							chunk_lc.getY() + y, chunk_lc.getZ() + z)));
				}
			}
		}
	}

	// Skylight
	//
	// Air voxels hold the light itself. Voxels that block light hold the
	// brightest light next to them instead, which is what the mesher reads
	// when the air voxel in front of a face is in a chunk it is not meshing.

	// Whether nothing at all occupies the voxel. Not the same as
	// voxel_transmits_light(): a voxel can leave the faces against it
	// undrawn and still hold a mesh of its own inside itself, and such a
	// voxel is not free for something else to take.
	bool voxel_is_fully_empty(const VoxelInstance &v)
	{
		if(v.get_id() == interface::VOXELTYPEID_UNDEFINED)
			return false;
		const interface::CachedVoxelDefinition *def =
				m_voxel_reg->get_cached(v);
		if(def == nullptr)
			return false;
		return def->fully_empty;
	}

	bool voxel_transmits_light(const VoxelInstance &v)
	{
		if(v.get_id() == interface::VOXELTYPEID_UNDEFINED)
			return false;
		const interface::CachedVoxelDefinition *def =
				m_voxel_reg->get_cached(v);
		if(def == nullptr)
			return false;
		return def->edge_material_id == interface::EDGEMATERIALID_EMPTY;
	}

	// Voxels in the topmost row of the world see the open sky
	bool is_below_open_sky(const pv::Vector3DInt32 &p)
	{
		int section_h = m_section_size_chunks.getY() *
				m_chunk_size_voxels.getY();
		return p.getY() ==
				(m_section_region.getUpperCorner().getY() + 1) * section_h - 1;
	}

	struct LightNode
	{
		pv::Vector3DInt32 p;
		uint8_t level;
	};

	// The light update walks one voxel at a time and nearly every step stays
	// inside the chunk the last one was in, so it keeps that chunk's buffer
	// rather than going through get_voxel()/set_voxel() and their section
	// lookup and bookkeeping for every neighbour. Only crossing a chunk
	// boundary costs a lookup. Nothing is unloaded while this is in use, so
	// the buffer stays put.
	pv::Vector3DInt32 m_light_chunk_p;
	ChunkBuffer *m_light_buf = nullptr;
	pv::Vector3DInt16 m_light_section_p;
	Section *m_light_section = nullptr;
	// World position of the cached chunk's first voxel, so that a position
	// inside it can be turned into a local one by subtraction. Dividing to
	// find the chunk costs more than everything else the light update does.
	pv::Vector3DInt32 m_light_chunk_lc;
	// Indexed by voxel type id: 1 transmits light, 0 does not, 2 not asked yet
	sv_<uint8_t> m_light_transmits;

	ChunkBuffer* light_buffer(const pv::Vector3DInt32 &chunk_p)
	{
		if(m_light_buf && chunk_p == m_light_chunk_p)
			return m_light_buf;
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = m_light_section;
		if(section == nullptr || section_p != m_light_section_p){
			section = get_section(section_p);
			if(section == nullptr)
				return nullptr;
			auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
					m_sections_with_loaded_buffers.end(), section,
					std::greater<Section*>());
			if(it == m_sections_with_loaded_buffers.end() || *it != section)
				m_sections_with_loaded_buffers.insert(it, section);
			m_light_section = section;
			m_light_section_p = section_p;
		}
		// Reached straight into rather than through get_buffer(), which reads
		// the clock to timestamp the buffer on every call; the light update
		// changes chunk often enough for that to be most of its time. Loading
		// one that is not in memory still goes the long way.
		ChunkBuffer &buf = section->chunk_buffers[section->get_chunk_i(chunk_p)];
		if(!buf.volume){
			if(!section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded).volume)
				return nullptr;
		}
		m_light_chunk_p = chunk_p;
		m_light_chunk_lc = pv::Vector3DInt32(
				chunk_p.getX() * m_chunk_size_voxels.getX(),
				chunk_p.getY() * m_chunk_size_voxels.getY(),
				chunk_p.getZ() * m_chunk_size_voxels.getZ());
		m_light_buf = &buf;
		return m_light_buf;
	}

	pv::Vector3DInt32 light_local_p(const pv::Vector3DInt32 &p,
			const pv::Vector3DInt32 &chunk_p)
	{
		return pv::Vector3DInt32(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ());
	}

	VoxelInstance light_get(const pv::Vector3DInt32 &p)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		return buf->volume->getVoxelAt(light_local_p(p, chunk_p));
	}

	// Give the voxels that block light the brightest light next to them, by
	// pushing each new light value into the blocking neighbours of the voxel
	// that got it. Only ever raises one, so it is right on its own as long as
	// no light went away; update_skylight() recomputes the few that did.
	void light_bleed_into_blockers(const pv::Vector3DInt32 &p, uint8_t level)
	{
		for(size_t k = 0; k < 6; k++){
			pv::Vector3DInt32 n(p.getX() + LIGHT_OFF[k][0],
					p.getY() + LIGHT_OFF[k][1], p.getZ() + LIGHT_OFF[k][2]);
			VoxelInstance nv = light_get(n);
			if(transmits_light(nv) || get_sky(nv) >= level)
				continue;
			light_set(n, nv, level);
		}
	}

	void light_set(const pv::Vector3DInt32 &p, VoxelInstance v, uint8_t level)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return;
		set_sky(v, level);
		buf->volume->setVoxelAt(light_local_p(p, chunk_p), v);
		if(!buf->dirty){
			buf->dirty = true;
			m_total_buffers_dirty++;
		}
	}

	bool transmits_light(const VoxelInstance &v)
	{
		uint32_t id = v.get_id();
		if(id >= m_light_transmits.size())
			m_light_transmits.resize(id + 1, 2);
		uint8_t &t = m_light_transmits[id];
		if(t == 2)
			t = voxel_transmits_light(v) ? 1 : 0;
		return t == 1;
	}

	// Bring the skylight up to date after the voxels in m_skylight_seeds
	// changed. Light is taken out of everything the changed voxels were
	// lighting, and then spread back in from whatever still has light, so the
	// work done is proportional to how far the change reaches rather than to
	// the size of the world. Neighbours are read in world coordinates, so this
	// crosses chunk and section boundaries by itself; a section that is not in
	// memory reads as undefined and stops the light, which keeps an edit next
	// to the edge of the loaded world from running away.
	void update_skylight()
	{
		std::vector<SkylightSeed> seeds;
		seeds.swap(m_skylight_seeds);
		if(!m_skylight_enabled || seeds.empty())
			return;
		auto t0 = std::chrono::steady_clock::now();
		m_light_buf = nullptr;
		m_light_section = nullptr;

		std::vector<LightNode> unlight;
		std::vector<LightNode> spread;
		// Voxels that block light next to light that went away. Only these
		// have to be worked out the slow way; everywhere else the light is
		// pushed into them as it is written.
		std::vector<pv::Vector3DInt32> blockers;

		for(const SkylightSeed &seed : seeds){
			VoxelInstance v = light_get(seed.p);
			bool now_transparent = transmits_light(v);
			if(seed.was_transparent && !now_transparent){
				// It took its light with it
				unlight.push_back(LightNode{seed.p, seed.old_level});
				blockers.push_back(seed.p);
			} else if(!seed.was_transparent && now_transparent){
				// It is dark and has to be filled from around it
				uint8_t l = is_below_open_sky(seed.p) ? sky_max() : 0;
				light_set(seed.p, v, l);
				if(l > 0){
					spread.push_back(LightNode{seed.p, l});
					light_bleed_into_blockers(seed.p, l);
				}
				for(size_t k = 0; k < 6; k++){
					pv::Vector3DInt32 n(
							seed.p.getX() + LIGHT_OFF[k][0],
							seed.p.getY() + LIGHT_OFF[k][1],
							seed.p.getZ() + LIGHT_OFF[k][2]);
					VoxelInstance nv = light_get(n);
					if(!transmits_light(nv))
						continue;
					if(get_sky(nv) > 0)
						spread.push_back(LightNode{n, get_sky(nv)});
				}
			}
		}

		// Take the light out. A neighbour dimmer than where the light is being
		// removed from was lit by it and goes dark too; one that is as bright
		// or brighter is lit by something else and becomes a source to spread
		// back from. Straight down is the exception: light does not dim on the
		// way down, so a full strength voxel below a full strength one was
		// still lit by it.
		for(size_t i = 0; i < unlight.size(); i++){
			LightNode node = unlight[i];
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(
						node.p.getX() + LIGHT_OFF[k][0],
						node.p.getY() + LIGHT_OFF[k][1],
						node.p.getZ() + LIGHT_OFF[k][2]);
				VoxelInstance nv = light_get(n);
				if(!transmits_light(nv)){
					// It may have been holding the light that is going away
					blockers.push_back(n);
					continue;
				}
				uint8_t nl = get_sky(nv);
				if(nl == 0)
					continue;
				bool lit_from_above = (k == LIGHT_DOWN &&
						node.level == sky_max() && nl == sky_max());
				if(nl < node.level || lit_from_above){
					light_set(n, nv, 0);
					unlight.push_back(LightNode{n, nl});
				} else {
					spread.push_back(LightNode{n, nl});
				}
			}
		}

		// Spread it back in
		for(size_t i = 0; i < spread.size(); i++){
			LightNode node = spread[i];
			if(node.level == 0)
				continue;
			// Spread whatever the voxel holds now, not what it held when it
			// was put on the list: a source can be unlit by another branch
			// after it was queued, and spreading the level it used to have
			// would put light back where it was just taken from.
			VoxelInstance v = light_get(node.p);
			if(!transmits_light(v))
				continue;
			node.level = get_sky(v);
			if(node.level == 0)
				continue;
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(
						node.p.getX() + LIGHT_OFF[k][0],
						node.p.getY() + LIGHT_OFF[k][1],
						node.p.getZ() + LIGHT_OFF[k][2]);
				VoxelInstance nv = light_get(n);
				if(!transmits_light(nv)){
					if(get_sky(nv) < node.level)
						light_set(n, nv, node.level);
					continue;
				}
				uint8_t target = (k == LIGHT_DOWN &&
						node.level == sky_max()) ?
						sky_max() : node.level - 1;
				if(target > get_sky(nv)){
					light_set(n, nv, target);
					spread.push_back(LightNode{n, target});
				}
			}
		}

		// Give the voxels that block light the brightest light next to them.
		// The same one is reached from every transparent voxel around it, so
		// this is mostly duplicates by now and recomputing each of them costs
		// seven voxel reads.
		auto before = [](const pv::Vector3DInt32 &a, const pv::Vector3DInt32 &b){
			if(a.getX() != b.getX()) return a.getX() < b.getX();
			if(a.getY() != b.getY()) return a.getY() < b.getY();
			return a.getZ() < b.getZ();
		};
		std::sort(blockers.begin(), blockers.end(), before);
		blockers.erase(std::unique(blockers.begin(), blockers.end()),
				blockers.end());
		size_t n_blockers = blockers.size();
		for(const pv::Vector3DInt32 &p : blockers){
			VoxelInstance v = light_get(p);
			if(transmits_light(v))
				continue;
			uint8_t best = 0;
			for(size_t k = 0; k < 6; k++){
				VoxelInstance nv = light_get(pv::Vector3DInt32(
						p.getX() + LIGHT_OFF[k][0],
						p.getY() + LIGHT_OFF[k][1],
						p.getZ() + LIGHT_OFF[k][2]));
				if(transmits_light(nv) && get_sky(nv) > best)
					best = get_sky(nv);
			}
			if(get_sky(v) != best)
				light_set(p, v, best);
		}

		log_v(MODULE, "update_skylight(): %zu seeds, %zu unlit, %zu spread, "
				"%zu blockers in %i ms", seeds.size(), unlight.size(),
				spread.size(), n_blockers,
				(int)std::chrono::duration_cast<std::chrono::milliseconds>(
				std::chrono::steady_clock::now() - t0).count());
	}

	// Commit and unload chunk buffer
	void commit_chunk_buffer(Section *section, size_t chunk_i)
	{
		ChunkBuffer &chunk_buffer = section->chunk_buffers[chunk_i];
		if(!chunk_buffer.dirty){
			// No changes
			return;
		}

		pv::Vector3DInt32 chunk_p = section->get_chunk_p(chunk_i);
		uint node_id = section->node_ids->getVoxelAt(chunk_p);

		log_d(MODULE, "Committing chunk " PV3I_FORMAT " (node %i)",
				PV3I_PARAMS(chunk_p), node_id);

		if(node_id == 0){
			log_w(MODULE, "commit_chunk_buffer() chunk_i=%zu: "
					"No node found for chunk " PV3I_FORMAT
					" in section " PV3I_FORMAT,
					chunk_i, PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section->section_p));
			return;
		}

		fill_chunk_padding(chunk_p, *chunk_buffer.volume);

		run_commit_hooks_in_thread(chunk_p, *chunk_buffer.volume);

		ss_ new_data = interface::serialize_volume_compressed(
				*chunk_buffer.volume);

		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			Context *context = scene->GetContext();

			Node *n = scene->GetNode(node_id);
			if(!n){
				log_w(MODULE, "commit_chunk_buffer(): Node %i not found",
						node_id);
				return;
			}
			const Variant &var = n->GetVar(StringHash("buildat_voxel_data"));
			if(var.GetType() != VAR_BUFFER){
				log_w(MODULE, "commit_chunk_buffer(): Node %i does not contain "
						"an existing buffer; assuming some kind of error",
						node_id);
				return;
			}

			n->SetVar(StringHash("buildat_voxel_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)new_data.c_str(),
					new_data.size())));

			run_commit_hooks_in_scene(chunk_p, n);
		});

		// First send updated voxel registry to clients so that they are ready
		// to generate stuff from the voxels
		send_voxel_registry_if_dirty();

		// Then synchronize node and notify clients about it
		sv_<replicate::PeerId> peers;
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->sync_node_immediate(m_scene_ref, node_id);
			peers = ireplicate->find_peers_that_know_node(m_scene_ref, node_id);
		});
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((int32_t)node_id);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &peer_id: peers){
				if(!m_clients_initialized.count(peer_id))
					continue;
				inetwork->send(peer_id, "voxelworld:node_volume_updated",
						os.str());
			}
		});

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		// Reset dirty flag
		chunk_buffer.dirty = false;
		m_total_buffers_dirty--;

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, node_id, true, chunk_p));
	}

	size_t num_buffers_loaded()
	{
		return m_total_buffers_loaded;
	}

	void set_skylight_enabled(bool enabled)
	{
		if(enabled && !sky_field().bound())
			throw Exception(ss_()+"set_skylight_enabled(): there is nowhere "
					"to put it in "+m_voxel_reg->get_format().dump());
		m_skylight_enabled = enabled;
	}

	void commit()
	{
		// Before anything is meshed, so that the light lands in the same
		// remesh as the voxels that changed it
		update_skylight();

		if(m_sections_with_loaded_buffers.empty())
			return;
		log_d(MODULE, "Committing %zu dirty buffers in %zu sections",
				m_total_buffers_dirty,
				m_sections_with_loaded_buffers.size());
		for(Section *section : m_sections_with_loaded_buffers){
			for(size_t i = 0; i < section->chunk_buffers.size(); i++){
				commit_chunk_buffer(section, i);
			}
		}
	}

	VoxelInstance get_voxel(const pv::Vector3DInt32 &p, bool disable_warnings)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "get_voxel() p=" PV3I_FORMAT ": No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					PV3I_PARAMS(p), PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		}

		// Unload stuff if needed
		maintain_maximum_buffer_limit();

		// Get from buffer
		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "get_voxel() p=" PV3I_FORMAT ": Couldn't get "
					"buffer volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, PV3I_PARAMS(p), PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return VoxelInstance(interface::VOXELTYPEID_UNDEFINED);
		}
		pv::Vector3DInt32 voxel_p(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);
		VoxelInstance v = buf.volume->getVoxelAt(voxel_p);

		// Set section buffer loaded flag
		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>()); // position in descending order
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);

		return v;
	}
};

struct Module: public interface::Module, public voxelworld::Interface
{
	interface::Server *m_server;

	sm_<SceneReference, up_<CInstance>> m_instances;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_t(MODULE, "voxelworld construct");
	}

	~Module()
	{
		log_t(MODULE, "voxelworld destruct");
	}

	void init()
	{
		// NOTE: These also apply to CInstances
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("replicate:peer_left_scene"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
		/*m_server->sub_event(this, Event::t(
					"network:packet_received/voxelworld:get_section"));*/
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("replicate:peer_joined_scene", on_peer_joined_scene,
				replicate::PeerJoinedScene);
		EVENT_TYPEN("replicate:peer_left_scene", on_peer_left_scene,
				replicate::PeerLeftScene);
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("main_context:scene_deleted", on_scene_deleted,
				main_context::SceneDeleted);

		for(auto &pair : m_instances){
			up_<CInstance> &instance = pair.second;
			instance->event(type, p);
		}
	}

	void on_start()
	{
	}

	void unload_node(Scene *scene, uint node_id)
	{
		log_d(MODULE, "Unloading node %i", node_id);
		Node *n = scene->GetNode(node_id);
		if(!n){
			log_w(MODULE, "Cannot unload node %i: Not found in scene", node_id);
			return;
		}
		// Remove RigidBody first to speed up removal of CollisionShapes
		RigidBody *body = n->GetComponent<RigidBody>();
		if(body)
			n->RemoveComponent(body);
		// Remove everything else
		n->RemoveAllComponents();
		n->Remove();
	}

	void on_unload()
	{
		log_v(MODULE, "on_unload()");

		// TODO

		/*commit();

		// Remove everything managed by us from the scene
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene();
			size_t progress = 0;
			for(auto &sector_pair: m_sections){
				log_v(MODULE, "Unloading nodes... %i%%",
						100 * progress / m_sections.size());
				progress++;
				for(auto &section_pair: sector_pair.second){
					Section &section = section_pair.second;

					auto region = section.node_ids->getEnclosingRegion();
					auto lc = region.getLowerCorner();
					auto uc = region.getUpperCorner();
					for(int z = lc.getZ(); z <= uc.getZ(); z++){
						for(int y = lc.getY(); y <= uc.getY(); y++){
							for(int x = lc.getX(); x <= uc.getX(); x++){
								uint id = section.node_ids->getVoxelAt(x, y, z);
								section.node_ids->setVoxelAt(x, y, z, 0);
								unload_node(scene, id);
							}
						}
					}
				}
			}
			log_v(MODULE, "Unloading nodes... 100%%");
		});

		// Store voxel registry and stuff
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(m_voxel_reg->serialize());
		}
		m_server->tmp_store_data("voxelworld:restore_info", os.str());*/
	}

	void on_continue()
	{
		// TODO

		/*// Restore voxel registry and stuff
				ss_ data = m_server->tmp_restore_data("voxelworld:restore_info");
		ss_ voxel_reg_data;
		{
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_reg_data);
		}
		m_voxel_reg->deserialize(voxel_reg_data);*/

		// Start up normally
		on_start();
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_peer_joined_scene(const replicate::PeerJoinedScene &event)
	{
	}

	void on_peer_left_scene(const replicate::PeerLeftScene &event)
	{
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
	}

	void on_scene_deleted(const main_context::SceneDeleted &event)
	{
		// Drop instance of the deleted scene (there should be only one, but
		// loop through all of them just for robustness)
		for(auto it = m_instances.begin(); it != m_instances.end();){
			auto current_it = it++;
			up_<CInstance> &instance = current_it->second;
			if(instance->m_scene_ref == event.scene){
				m_instances.erase(current_it);
			}
		}
	}

	/*// TODO: How should nodes be filtered for replication?
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
		}*/

	// Interface

	void create_instance(SceneReference scene_ref, const pv::Region &region,
			bool physics_enabled)
	{
		auto it = m_instances.find(scene_ref);
		// TODO: Is an exception the best way to handle this?
		if(it != m_instances.end())
			throw Exception("create_instance(): Scene already has a voxel"
					" world instance");

		up_<CInstance> instance(new CInstance(m_server, scene_ref, region,
				physics_enabled));
		m_instances[scene_ref] = std::move(instance);
	}

	void delete_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			throw Exception("delete_instance(): Scene does not have a voxel"
					" world instance");
		m_instances.erase(it);
	}

	Instance* get_instance(SceneReference scene_ref)
	{
		auto it = m_instances.find(scene_ref);
		if(it == m_instances.end())
			return nullptr;
		return it->second.get();
	}

	void commit()
	{
		for(auto &pair : m_instances){
			up_<CInstance> &instance = pair.second;
			instance->commit();
		}
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
