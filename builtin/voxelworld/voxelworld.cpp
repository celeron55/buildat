// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "voxelworld/api.h"
#include "storage/api.h"
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
#include "interface/voxel_cereal.h"
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
#include <mutex>
#include <map>
#include <algorithm>
#define MODULE "voxelworld"

// What a voxel type the game no longer registers is tinted with, so that a
// player or a developer sees it rather than finding out the hard way. It
// multiplies the vertex colour, which is light; see adopt_unknown_voxel().
static const uint32_t UNKNOWN_VOXEL_TINT = 0xff60ff;

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using namespace Urho3D;
using interface::VoxelInstance;
using interface::VoxelVolume;
using interface::container_coord;
using interface::container_coord16;

namespace voxelworld {

struct ChunkBuffer
{
	pv::Vector3DInt32 chunk_p; // For logging
	up_<VoxelVolume> volume;
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
		// A buffer that has changes in it has nowhere to put them: what
		// writes them out is commit(), which runs at the end of the access
		// that made them. Dropping it here would lose whatever was written
		// into it -- which is what happened to a caller that wrote more
		// buffers in one access() than the limit allows. It stays until it
		// is committed, and the limit is exceeded until then.
		if(dirty)
			return false;
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
	// Something has changed since this section was read from the save, or it
	// was never in one. A section is written only when this is set, which is
	// what keeps saving a world nobody is digging in free.
	bool modified = false;

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

	// The world region's own sections have not been created yet; see the
	// constructor
	bool m_initial_sections_pending = true;
	static const int64_t MAX_INITIAL_SECTIONS = 4096;

	// Streaming: the points the world is kept loaded around, and how much
	// one pass may do. Empty and off until a game sets load points; until
	// then the world is its region and stays there.
	sv_<voxelworld::LoadPoint> m_load_points;
	bool m_streaming = false;
	size_t m_stream_budget = 2;
	uint m_stream_tick = 0;
	// Sections the save was asked for and does not have; see load_saved_only()
	set_<uint64_t> m_save_misses;

	// What the send filter answers from. replicate asks it from its own
	// thread, so this much is behind a lock of its own -- a small one, and
	// never held while reaching into another module.
	std::mutex m_send_mutex;
	// Chunk node id -> the chunk it holds. A node that is not in here is
	// not this world's and the filter says nothing about it.
	sm_<uint, pv::Vector3DInt32> m_chunk_node_chunk_p;
	// The load point of each peer that has one of its own
	sm_<replicate::PeerId, voxelworld::LoadPoint> m_peer_points;
	// How much world each client asked for, in sections. A peer that never
	// asked is not in here and gets everything its load point keeps.
	sm_<replicate::PeerId, int> m_peer_send_radius;
	// Where a peer was when replicate last reconsidered what it has
	sm_<replicate::PeerId, pv::Vector3DInt16> m_peer_section;

	// Persistence. Null until a game calls set_save(); a world that never
	// does is generated and forgotten, which is what every game did before
	// this existed and what an arena game wants.
	storage::Store *m_store = nullptr;
	ss_ m_world_name;
	// The save's voxel name table: save id -> name, append-only and never
	// renumbered. The running game owns the numbering and the save stores
	// names -- the game is the only thing that can decide whether a name
	// still means what it meant, and a save has nothing to contribute to
	// that question. See doc/plan/world_persistence_plan.md.
	sv_<interface::VoxelName> m_save_names;
	std::map<ss_, interface::VoxelTypeId> m_save_id_of_name;
	bool m_save_names_dirty = false;
	// save id -> session id and back. Both are the identity in the common
	// case -- the same game, registering the same types in the same order --
	// and then a chunk is the byte copy of the save's row that it was before
	// any of this existed.
	sv_<interface::VoxelTypeId> m_save_to_session;
	sv_<interface::VoxelTypeId> m_session_to_save;
	bool m_id_map_identity = true;
	bool m_logged_remap = false;
	// Session ids up to here are in the name table, and the registry row on
	// disk was written when the table reached the second of these. They are
	// what keeps both of those from being redone on every section.
	interface::VoxelTypeId m_names_synced_to = 0;
	interface::VoxelTypeId m_registry_saved_to = (interface::VoxelTypeId)-1;
	// The definitions the save carries, for a type the game has stopped
	// registering. Loaded on the first one that turns up and not before.
	up_<interface::VoxelRegistry> m_saved_reg;
	sv_<interface::VoxelName> m_unknown_voxels;
	// The formats the save's chunks are in, indexed by the tag a chunk row
	// carries, and which of them new chunks are written in
	sv_<interface::VoxelFormat> m_save_formats;
	uint16_t m_write_format = 0;

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

		// The region's sections are created on the first tick and not here.
		// A game creates the world, registers its voxels and calls
		// set_save() in one core:start, in that order, and a section that
		// comes out of a save must not be generated -- so nothing may be
		// loaded before the game has had the chance to say whether there is
		// a save to look in.

		check_streaming();

		// Which chunks reach which peer. Nothing is filtered until a game
		// gives its peers load points of their own; see peer_wants_node().
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->set_node_filter(m_scene_ref,
					[this](replicate::PeerId peer, uint node_id){
				return peer_wants_node(peer, node_id);
			});
		});

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
		// The filter holds this; it must not outlive it
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->set_node_filter(m_scene_ref, nullptr);
		});
	}

	void create_initial_sections()
	{
		auto lc = m_section_region.getLowerCorner();
		auto uc = m_section_region.getUpperCorner();
		int64_t num = (int64_t)(uc.getX() - lc.getX() + 1) *
				(uc.getY() - lc.getY() + 1) * (uc.getZ() - lc.getZ() + 1);
		// The bounds of a world that streams are far larger than anything
		// anyone wants loaded at once, and creating them would be the rest
		// of the day. Say so instead of taking it.
		if(num > MAX_INITIAL_SECTIONS)
			throw Exception(ss_()+"voxelworld: the region is "+itos(num)+
					" sections and nothing called set_load_points(); a world "
					"with bounds bigger than it wants loaded has to stream");
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					load_or_generate_section(pv::Vector3DInt16(x, y, z));
				}
			}
		}
	}

	// Streaming. One pass loads, generates or unloads a few sections at
	// most, nearest first, so that a player waiting for the ground under
	// them does not wait for the horizon.

	static uint64_t section_key(const pv::Vector3DInt16 &p)
	{
		return (uint64_t)(uint16_t)p.getX() |
				((uint64_t)(uint16_t)p.getY() << 16) |
				((uint64_t)(uint16_t)p.getZ() << 32);
	}

	pv::Vector3DInt16 section_of_voxel(const pv::Vector3DInt32 &p)
	{
		return container_coord16(
				container_coord(p, m_chunk_size_voxels),
				m_section_size_chunks);
	}

	bool is_in_bounds(const pv::Vector3DInt16 &sp)
	{
		auto lc = m_section_region.getLowerCorner();
		auto uc = m_section_region.getUpperCorner();
		return sp.getX() >= lc.getX() && sp.getX() <= uc.getX() &&
				sp.getY() >= lc.getY() && sp.getY() <= uc.getY() &&
				sp.getZ() >= lc.getZ() && sp.getZ() <= uc.getZ();
	}

	// Inside some point's load radius, which is what lets a section stay
	static int dist(int a, int b){ return a > b ? a - b : b - a; }

	bool is_wanted_loaded(const pv::Vector3DInt16 &sp)
	{
		for(const voxelworld::LoadPoint &lp : m_load_points){
			pv::Vector3DInt16 c = section_of_voxel(lp.p);
			if(dist(sp.getX(), c.getX()) <= lp.load_xz &&
					dist(sp.getZ(), c.getZ()) <= lp.load_xz &&
					dist(sp.getY(), c.getY()) <= lp.load_y)
				return true;
		}
		return false;
	}

	// Which chunks a peer is sent: the ones its own load point keeps near
	// it, as far out as its client asked for. replicate calls this from its
	// own sync, so it reaches into nothing and holds only m_send_mutex.
	//
	// A node this world did not make, or a peer whose position nobody
	// declared, is none of this filter's business and passes.
	bool peer_wants_node(replicate::PeerId peer, uint node_id)
	{
		std::lock_guard<std::mutex> lock(m_send_mutex);
		auto it = m_chunk_node_chunk_p.find(node_id);
		if(it == m_chunk_node_chunk_p.end())
			return true;
		auto pit = m_peer_points.find(peer);
		if(pit == m_peer_points.end())
			return true;
		const voxelworld::LoadPoint &lp = pit->second;
		int radius = lp.load_xz;
		auto rit = m_peer_send_radius.find(peer);
		if(rit != m_peer_send_radius.end() && rit->second < radius)
			radius = rit->second;
		pv::Vector3DInt16 sp = container_coord16(it->second,
				m_section_size_chunks);
		pv::Vector3DInt16 c = section_of_voxel(lp.p);
		return dist(sp.getX(), c.getX()) <= radius &&
				dist(sp.getZ(), c.getZ()) <= radius &&
				dist(sp.getY(), c.getY()) <= lp.load_y;
	}

	// The client says how much world it wants; what it gets is that or the
	// load radius, whichever is smaller. Only the client knows what its
	// computer can draw, and loading more than it will look at is the
	// server's memory spent on nothing.
	void on_set_send_distance(const network::Packet &packet)
	{
		if(!m_clients_initialized.count(packet.sender))
			return;
		int distance_voxels = atoi(packet.data.c_str());
		if(distance_voxels < 0)
			return;
		int section_w = m_chunk_size_voxels.getX() *
				m_section_size_chunks.getX();
		// A section the point is anywhere in is one the client can see into
		int radius = (distance_voxels + section_w - 1) / section_w;
		log_v(MODULE, "C%zu: wants %i voxels of world, which is %i sections",
				(size_t)packet.sender, distance_voxels, radius);
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_peer_send_radius[packet.sender] = radius;
		}
		replicate::access(m_server, [&](replicate::Interface *irep){
			irep->refresh_peer_nodes(m_scene_ref, packet.sender);
		});
	}

	void stream_pass()
	{
		size_t budget = m_stream_budget;
		for(const voxelworld::LoadPoint &lp : m_load_points){
			if(budget == 0)
				return;
			stream_around(lp, budget);
		}
		if(budget == 0)
			return;
		unload_distant_sections(budget);
	}

	// The sections of a box around c, ring by ring outward, so that the
	// nearest section that is missing something is the one that gets it. The
	// callback is given the ring it is on -- which is its distance in XZ --
	// and stops the walk by returning false.
	template<typename F>
	static void for_each_section_around(const pv::Vector3DInt16 &c,
			int load_xz, int load_y, F f)
	{
		for(int r = 0; r <= load_xz; r++){
			for(int dy = -load_y; dy <= load_y; dy++){
				for(int dz = -r; dz <= r; dz++){
					for(int dx = -r; dx <= r; dx++){
						// The ring and not the square: what is inside it was
						// walked by a smaller r already
						if(r > 0 && dx != r && dx != -r &&
								dz != r && dz != -r)
							continue;
						if(!f(pv::Vector3DInt16(c.getX() + dx, c.getY() + dy,
								c.getZ() + dz), r, dy))
							return;
					}
				}
			}
		}
	}

	void stream_around(const voxelworld::LoadPoint &lp, size_t &budget)
	{
		for_each_section_around(section_of_voxel(lp.p), lp.load_xz, lp.load_y,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			if(!is_in_bounds(sp))
				return true;
			bool generate = (r <= lp.generate_xz &&
					dist(dy, 0) <= lp.generate_y);
			if(!stream_section(sp, generate))
				return true;
			return --budget != 0;
		});
	}

	// The rings cover the box exactly once, nearest first, and the ring a
	// section is on is its distance -- which is what decides whether it is
	// generated as well as loaded
	static void check_streaming()
	{
		const int R = 3, RY = 1;
		const pv::Vector3DInt16 c(10, -2, 7);
		set_<uint64_t> seen;
		int last_r = 0;
		size_t n = 0;
		for_each_section_around(c, R, RY,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			bool fresh = seen.insert(section_key(sp)).second;
			assert(fresh);
			(void)fresh;
			assert(r >= last_r);
			last_r = r;
			assert(r == std::max(dist(sp.getX(), c.getX()),
					dist(sp.getZ(), c.getZ())));
			assert(dy == sp.getY() - c.getY());
			assert(dist(sp.getY(), c.getY()) <= RY);
			n++;
			return true;
		});
		assert(n == (size_t)(2*R+1) * (2*R+1) * (2*RY+1));
		// And it stops where it is told
		size_t stopped_after = 0;
		for_each_section_around(c, R, RY,
				[&](const pv::Vector3DInt16 &sp, int r, int dy) -> bool
		{
			return ++stopped_after < 5;
		});
		assert(stopped_after == 5);
		log_v(MODULE, "check_streaming: the rings cover the box once");
	}

	// True if this section wanted something and got it
	bool stream_section(const pv::Vector3DInt16 &sp, bool generate)
	{
		Section *section = get_section(sp);
		if(section && section->loaded && (section->generated || !generate))
			return false;
		if(generate){
			load_or_generate_section(sp);
			return true;
		}
		return load_saved_only(sp);
	}

	// What the save already holds, without generating what it does not: the
	// terrain a player sees far away is the terrain that is already there.
	bool load_saved_only(const pv::Vector3DInt16 &sp)
	{
		if(!m_store)
			return false;
		// The save was asked once and does not have it; asking again every
		// pass would be a query per section of the load radius per pass
		if(m_save_misses.count(section_key(sp)))
			return false;
		Section &section = force_get_section(sp);
		if(section.loaded)
			return true;
		if(load_saved_section(section)){
			section.loaded = true;
			m_server->emit_event("voxelworld:section_loaded",
					new SectionLoaded(m_scene_ref, sp));
			return true;
		}
		m_save_misses.insert(section_key(sp));
		forget_section(sp);
		return false;
	}

	// Drop a section nothing was put in. Not unload_section(): there is
	// nothing to write, no nodes to remove and no buffers to free.
	void forget_section(const pv::Vector3DInt16 &sp)
	{
		Section *section = get_section(sp);
		if(!section)
			return;
		m_last_used_sections.erase(
				std::remove(m_last_used_sections.begin(),
				m_last_used_sections.end(), section),
				m_last_used_sections.end());
		pv::Vector<2, int16_t> p_yz(sp.getY(), sp.getZ());
		auto sector_it = m_sections.find(p_yz);
		if(sector_it == m_sections.end())
			return;
		sector_it->second.erase(sp.getX());
		if(sector_it->second.empty())
			m_sections.erase(sector_it);
	}

	void unload_distant_sections(size_t &budget)
	{
		sv_<pv::Vector3DInt16> drop;
		for(auto &sector : m_sections){
			for(auto &pair : sector.second){
				Section &section = pair.second;
				if(!section.loaded)
					continue;
				if(is_wanted_loaded(section.section_p))
					continue;
				drop.push_back(section.section_p);
				if(drop.size() >= budget)
					break;
			}
			if(drop.size() >= budget)
				break;
		}
		for(const pv::Vector3DInt16 &sp : drop)
			unload_section(sp);
		budget -= drop.size();
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
		EVENT_TYPEN("network:packet_received/voxelworld:set_send_distance",
				on_set_send_distance, network::Packet)
		/*EVENT_TYPEN("network:packet_received/voxelworld:get_section",
				on_get_section, network::Packet)*/
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_initial_sections_pending){
			m_initial_sections_pending = false;
			// A world that streams says where it wants sections; the region
			// is then its bounds and its sky and not a thing to fill
			if(!m_streaming)
				create_initial_sections();
		}

		// Every fourth tick: often enough that a running player stays ahead
		// of the edge, seldom enough that the work is not the tick
		if(m_streaming && ((m_stream_tick++) % 4) == 0)
			stream_pass();

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
				up_<VoxelVolume> volume =
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
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_chunk_node_chunk_p.erase(node_id);
		}
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

	// saved_data is a chunk read back out of a save: the same bytes this
	// wrote there, which are the same bytes replication sends, so nothing
	// about the on-disk format was designed -- it is the volume format.
	void create_chunk_node(Scene *scene, Section &section, int x, int y, int z,
			const ss_ *saved_data = nullptr)
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
		{
			// What the send filter answers from; see peer_wants_node()
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_chunk_node_chunk_p[n->GetID()] = chunk_p;
		}

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
		sp_<VoxelVolume> volume(
				new VoxelVolume(region));

		// Every plane of a new volume reads as zero and none of them is
		// allocated, so a chunk of nothing but VOXELTYPEID_UNDEFINED costs
		// its planes nothing at all

		// A loaded chunk has had the in_thread hooks run on it already, on
		// the way in to the save
		if(!saved_data)
			run_commit_hooks_in_thread(chunk_p, *volume);

		ss_ data = saved_data ? *saved_data :
				interface::serialize_volume_compressed(*volume);
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

	// One chunk, one row. The section is the load and unload unit, but the
	// chunk is what a node holds and what the volume format describes, so a
	// key per chunk means no container format had to be invented for the
	// eight of them.
	ss_ chunk_key(const pv::Vector3DInt32 &chunk_p)
	{
		return m_world_name+"/"+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
	}

	// A chunk's row in the save: a header naming the format the chunk was
	// written in, and then the blob replication already produces. The tag is
	// Luanti's MapBlock property and it buys what it buys there -- chunks
	// are independent of each other, so a save converges as sections are
	// touched instead of being rewritten in one go, and one unreadable chunk
	// is one unreadable chunk.
	static const size_t CHUNK_HEADER_SIZE = 6;

	ss_ chunk_row(const ss_ &blob)
	{
		ss_ row;
		row.reserve(CHUNK_HEADER_SIZE + blob.size());
		row += "BVC";
		row += (char)1;
		row += (char)(m_write_format & 0xff);
		row += (char)((m_write_format >> 8) & 0xff);
		row += blob;
		return row;
	}

	// A row without the header was written before there was one, and is in
	// the world's own format by definition -- there was only ever the one. A
	// cereal archive begins with an endianness byte and never with 'B', so
	// the two cannot be read for each other.
	bool split_chunk_row(const ss_ &row, uint16_t &format_out, ss_ &blob_out)
	{
		if(row.size() < CHUNK_HEADER_SIZE || row.compare(0, 3, "BVC") != 0){
			format_out = m_write_format;
			blob_out = row;
			return true;
		}
		if((uint8_t)row[3] != 1)
			return false;
		format_out = (uint16_t)(uint8_t)row[4] |
				((uint16_t)(uint8_t)row[5] << 8);
		blob_out = row.substr(CHUNK_HEADER_SIZE);
		return true;
	}

	// A chunk out of the save, in the cut and the numbering this world runs.
	// Byte for byte what was stored, in the common case.
	bool prepare_loaded_chunk(const pv::Vector3DInt32 &chunk_p,
			const ss_ &row, ss_ &data_out, bool &converted_out)
	{
		ss_ where = ss_("chunk ")+itos(chunk_p.getX())+","+
				itos(chunk_p.getY())+","+itos(chunk_p.getZ());
		uint16_t tag = 0;
		ss_ blob;
		if(!split_chunk_row(row, tag, blob)){
			refuse_save(where+" has a header this build does not know");
			return false;
		}
		if(tag == m_write_format && m_id_map_identity){
			data_out = blob;
			return true;
		}
		// What comes out is not what is on disk, so the section is written
		// back the next time it is unloaded: the save converges on the
		// world's own format as sections are touched, and nothing that was
		// not touched is rewritten
		converted_out = true;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume){
			refuse_save(where+" is not in a volume format this build knows");
			return false;
		}
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		if(tag != m_write_format){
			if(tag >= m_save_formats.size()){
				refuse_save(where+" is tagged with format "+itos((int)tag)+
						", which the save's format table does not have");
				return false;
			}
			ss_ why;
			up_<VoxelVolume> moved = interface::migrate_volume(*volume,
					m_save_formats[tag], format, &why);
			if(!moved){
				refuse_save(where+" was written in "+
						m_save_formats[tag].dump()+" and this world is "+
						format.dump()+": "+why);
				return false;
			}
			volume = std::move(moved);
		}
		if(!m_id_map_identity)
			interface::remap_volume_ids(*volume, format, m_save_to_session);
		data_out = interface::serialize_volume_compressed(*volume);
		return true;
	}

	// A chunk on its way into the save, in the save's numbering
	ss_ prepare_saved_chunk(const ss_ &blob)
	{
		if(m_id_map_identity)
			return blob;
		up_<VoxelVolume> volume = interface::deserialize_volume(blob);
		if(!volume)
			return blob;
		interface::remap_volume_ids(*volume, m_voxel_reg->get_format(),
				m_session_to_save);
		return interface::serialize_volume_compressed(*volume);
	}

	// Somehow get the section's static nodes and possible other nodes, either
	// by loading from the save or by creating new ones
	void load_section(Section &section)
	{
		if(section.loaded)
			return;
		section.loaded = true;
		pv::Vector3DInt16 section_p = section.section_p;
		log_d(MODULE, "Loading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		if(!m_store || !load_saved_section(section))
			create_section(section);
		// What a game keeps of its own per section comes back with it
		m_server->emit_event("voxelworld:section_loaded",
				new SectionLoaded(m_scene_ref, section_p));
	}

	// True if the whole section was in the save. All or nothing: a section
	// with some of its chunks saved and some not would have to be both loaded
	// and generated, and generation is by section.
	bool load_saved_section(Section &section)
	{
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return false;
		auto lc = section.contained_chunks.getLowerCorner();
		auto uc = section.contained_chunks.getUpperCorner();
		sv_<ss_> chunks;
		chunks.reserve(section.num_chunks);
		bool converted = false;
		for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
			for(int y = 0; y <= uc.getY() - lc.getY(); y++){
				for(int x = 0; x <= uc.getX() - lc.getX(); x++){
					pv::Vector3DInt32 chunk_p(
							lc.getX() + x, lc.getY() + y, lc.getZ() + z);
					ss_ row;
					if(!m_store->get(chunk_key(chunk_p), row))
						return false;
					ss_ data;
					if(!prepare_loaded_chunk(chunk_p, row, data, converted))
						return false;
					chunks.push_back(data);
				}
			}
		}
		log_v(MODULE, "Loading section " PV3I_FORMAT " from the save",
				PV3I_PARAMS(section.section_p));
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			size_t i = 0;
			for(int z = 0; z <= uc.getZ() - lc.getZ(); z++){
				for(int y = 0; y <= uc.getY() - lc.getY(); y++){
					for(int x = 0; x <= uc.getX() - lc.getX(); x++){
						create_chunk_node(scene, section, x, y, z,
								&chunks[i++]);
					}
				}
			}
		});
		// It came out of the save the way the generator left it, and running
		// the generator over it again would undo whatever has been built
		// there since
		section.generated = true;
		section.modified = converted;
		return true;
	}

	// Writes the section's chunks as one transaction. Called when a section
	// is unloaded and when the world is saved as a whole; both are moments
	// where the data is about to stop being reachable.
	//
	// A section nothing has touched since it was read is not written at all,
	// which is what keeps saving a world people are only walking through
	// free. The flag is per section rather than per chunk because a section
	// is what is read and written as a unit.
	void save_section(Section &section)
	{
		if(!m_store || !section.loaded || !section.modified)
			return;
		update_id_maps();
		if(!m_store) // update_id_maps() can refuse the save
			return;
		sv_<ss_> keys;
		sv_<ss_> values;
		keys.reserve(section.num_chunks);
		values.reserve(section.num_chunks);
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene_ref);
			auto lc = section.contained_chunks.getLowerCorner();
			auto uc = section.contained_chunks.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						uint id = section.node_ids->getVoxelAt(x, y, z);
						if(!id)
							continue;
						Node *n = scene->GetNode(id);
						if(!n)
							continue;
						const Variant &var =
								n->GetVar(StringHash("buildat_voxel_data"));
						const PODVector<unsigned char> &buf = var.GetBuffer();
						if(buf.Size() == 0)
							continue;
						keys.push_back(chunk_key(pv::Vector3DInt32(x, y, z)));
						values.push_back(
								ss_((const char*)&buf[0], buf.Size()));
					}
				}
			}
		});
		if(keys.empty()){
			section.modified = false;
			return;
		}
		// Outside the scene lock: a chunk that has to be renumbered is
		// decompressed, rewritten and compressed again, and the scene is not
		// waiting for that
		for(ss_ &value : values)
			value = chunk_row(prepare_saved_chunk(value));
		// One transaction: a row at a time outside one is the classic slow
		// save, and it is also what leaves half a section on disk after a
		// crash. The name table goes in with the chunks that made it grow,
		// so there is no window where a row names an id the table has not.
		m_store->batch([&](){
			for(size_t i = 0; i < keys.size(); i++)
				m_store->set(keys[i], values[i]);
			save_name_table();
			save_registry();
		});
		section.modified = false;
		// The save has it now, whatever the streamer was told earlier
		m_save_misses.erase(section_key(section.section_p));
	}

	// Generate the section; requires static nodes to already exist
	void generate_section(Section &section)
	{
		if(section.generated)
			return;
		section.generated = true;
		// Whatever the generator makes of it is not in the save, and a
		// generator that writes nothing at all still ran
		section.modified = true;
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
			VoxelVolume &volume)
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

	// The voxel's type, through the format the game chose. Not
	// VoxelInstance::get_id(), which is the default format's bit range and
	// would read a game's own light, parameter and simulation bits as part
	// of the id.
	interface::VoxelTypeId get_id(const VoxelInstance &v)
	{
		return m_voxel_reg->get_format().id_of(v.data);
	}

	// One plane's word as a whole voxel, for a world that has only the one
	static interface::VoxelSample sample_of(const VoxelInstance &v)
	{
		interface::VoxelSample s;
		s.planes[0] = v.data;
		return s;
	}

	bool is_undefined(const VoxelInstance &v)
	{
		return get_id(v) == interface::VOXELTYPEID_UNDEFINED;
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

	void set_load_points(const sv_<voxelworld::LoadPoint> &points)
	{
		m_load_points = points;
		m_streaming = true;
		// A peer whose point moved into another section is sent another set
		// of chunks, and replicate has no other way of knowing that it did
		sv_<replicate::PeerId> moved;
		{
			std::lock_guard<std::mutex> lock(m_send_mutex);
			m_peer_points.clear();
			for(const voxelworld::LoadPoint &lp : points){
				if(lp.peer == 0)
					continue;
				m_peer_points[lp.peer] = lp;
				pv::Vector3DInt16 sp = section_of_voxel(lp.p);
				auto it = m_peer_section.find(lp.peer);
				if(it != m_peer_section.end() && it->second == sp)
					continue;
				m_peer_section[lp.peer] = sp;
				moved.push_back(lp.peer);
			}
		}
		if(moved.empty())
			return;
		replicate::access(m_server, [&](replicate::Interface *irep){
			for(replicate::PeerId peer : moved)
				irep->refresh_peer_nodes(m_scene_ref, peer);
		});
	}

	sv_<pv::Vector3DInt16> get_loaded_sections()
	{
		sv_<pv::Vector3DInt16> result;
		for(auto &sector : m_sections){
			for(auto &pair : sector.second){
				if(pair.second.loaded)
					result.push_back(pair.second.section_p);
			}
		}
		return result;
	}

	void set_stream_budget(size_t sections_per_pass)
	{
		m_stream_budget = sections_per_pass;
	}

	void unload_section(const pv::Vector3DInt16 &section_p)
	{
		Section *section = get_section(section_p);
		if(!section || !section->loaded)
			return;

		log_v(MODULE, "Unloading section " PV3I_FORMAT, PV3I_PARAMS(section_p));

		// Before the voxels go, so that a game writing something of its own
		// out with the section still has the section to look at
		m_server->emit_event("voxelworld:section_unloaded",
				new SectionUnloaded(m_scene_ref, section_p));

		if(m_store){
			// What the nodes hold is what has been committed; the buffers
			// below are dropped without one
			commit();
			save_section(*section);
		}

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

	ss_ registry_key(){ return m_world_name+"/registry"; }
	ss_ names_key(){ return m_world_name+"/names"; }
	ss_ formats_key(){ return m_world_name+"/formats"; }

	void set_save(storage::Save *save, const ss_ &world_name)
	{
		if(!save){
			m_store = nullptr;
			m_world_name = "";
			m_save_names.clear();
			m_save_id_of_name.clear();
			m_save_to_session.clear();
			m_session_to_save.clear();
			m_save_formats.clear();
			m_saved_reg.reset();
			return;
		}
		m_store = save->store("voxelworld");
		m_world_name = world_name;
		load_name_table();
		load_format_table();
	}

	// The save holds something this build must not overwrite: a chunk in a
	// cut nothing here can move it out of, or a voxel type with no name this
	// game or the save can put to it. Stop touching the save altogether
	// rather than guess -- what is on disk is somebody's world, and a wrong
	// guess written over it cannot be undone.
	void refuse_save(const ss_ &why)
	{
		log_e(MODULE, "World \"%s\": %s. The save is neither read nor written "
				"any further; migrating it is the game's to do.",
				cs(m_world_name), cs(why));
		m_store = nullptr;
	}

	void load_name_table()
	{
		m_save_names.clear();
		m_save_id_of_name.clear();
		m_save_to_session.clear();
		m_session_to_save.clear();
		m_save_names_dirty = false;
		m_names_synced_to = 0;
		m_registry_saved_to = (interface::VoxelTypeId)-1;
		ss_ data;
		if(m_store->get(names_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version != 1)
				throw Exception(ss_()+"voxelworld: the name table of world \""+
						m_world_name+"\" is version "+itos(version)+
						" and this build writes 1");
			ar(m_save_names);
		}
		// Save id 0 is VOXELTYPEID_UNDEFINED under every format, and is not
		// a name
		if(m_save_names.empty())
			m_save_names.resize(1);
		// A save written before there was a name table carries the registry
		// it was written under instead, and that registry *is* the numbering
		// its chunks are in. Seeding the table from it is what keeps such a
		// save readable by a game that has since registered its types in
		// another order -- without this the ids would quietly mean something
		// else.
		if(m_save_names.size() == 1)
			seed_name_table_from_saved_registry();
		for(size_t i = 1; i < m_save_names.size(); i++)
			m_save_id_of_name[m_save_names[i].dump()] =
					(interface::VoxelTypeId)i;
	}

	void seed_name_table_from_saved_registry()
	{
		if(!load_saved_registry())
			return;
		interface::VoxelTypeId num = m_saved_reg->num_voxels();
		for(interface::VoxelTypeId id = 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_saved_reg->get(id);
			if(!def)
				break;
			m_save_names.push_back(def->name);
		}
		if(m_save_names.size() > 1){
			m_save_names_dirty = true;
			log_v(MODULE, "World \"%s\": name table seeded with %zu names "
					"from the registry the save carries",
					cs(m_world_name), m_save_names.size() - 1);
		}
	}

	bool load_saved_registry()
	{
		if(m_saved_reg)
			return true;
		ss_ data;
		if(!m_store->get(registry_key(), data))
			return false;
		m_saved_reg.reset(interface::createVoxelRegistry());
		m_saved_reg->deserialize(data);
		return true;
	}

	void save_name_table()
	{
		if(!m_store || !m_save_names_dirty)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, m_save_names);
		}
		m_store->set(names_key(), os.str());
		m_save_names_dirty = false;
	}

	// The save's id for a name, appending it if the save has not seen it.
	// The table only ever grows, which is what keeps a chunk written under
	// an older one valid.
	interface::VoxelTypeId save_id_of(const interface::VoxelName &name)
	{
		ss_ key = name.dump();
		auto it = m_save_id_of_name.find(key);
		if(it != m_save_id_of_name.end())
			return it->second;
		m_save_names.push_back(name);
		interface::VoxelTypeId id =
				(interface::VoxelTypeId)(m_save_names.size() - 1);
		m_save_id_of_name[key] = id;
		m_save_names_dirty = true;
		return id;
	}

	// A voxel type the save has and the game no longer registers. It gets a
	// session id of its own so that its word travels whole and it is written
	// back under the same name, and it is drawn with the definition the save
	// carries -- so a dropped type still looks like itself in an old world.
	//
	// What that would hide is that the game does not support it any more, so
	// every variant of it is tinted. Honest limitation: the tint multiplies
	// the vertex colour, which is light and not albedo, so in the dark an
	// unknown voxel looks like everything else.
	const interface::VoxelDefinition* adopt_unknown_voxel(
			const interface::VoxelName &name)
	{
		if(!load_saved_registry())
			return nullptr;
		const interface::VoxelDefinition *saved = m_saved_reg->get(name);
		if(!saved)
			return nullptr;
		interface::VoxelDefinition def = *saved;
		def.id = interface::VOXELTYPEID_UNDEFINED;
		// A definition with no variants has one now, which is the plain cube
		// with somewhere to put the tint; variant_of_param is all zeroes, so
		// every param value finds it
		if(def.variants.empty())
			def.variants.resize(1);
		for(interface::VoxelVariant &v : def.variants)
			v.color = UNKNOWN_VOXEL_TINT;
		interface::VoxelTypeId id = m_voxel_reg->add_voxel(def);
		log_w(MODULE, "World \"%s\": the save has voxel type %s, which this "
				"game does not register. It is kept and drawn with the "
				"definition the save carries, tinted.",
				cs(m_world_name), cs(name.dump()));
		m_unknown_voxels.push_back(name);
		return m_voxel_reg->get(id);
	}

	// save id -> session id and back, worked out by name.
	//
	// Called before a section is read or written rather than once, because
	// the game goes on registering voxel types after set_save(): a name that
	// does not resolve now may resolve later, and a type registered later
	// still has to reach the table before anything holding it is written.
	// Both loops normally do nothing at all.
	void update_id_maps()
	{
		// Every type the game has registered goes into the table first, so
		// that writing a chunk cannot come across a name the save has no id
		// for. Appending in id order is what keeps the identity case the
		// identity.
		interface::VoxelTypeId num = m_voxel_reg->num_voxels();
		for(interface::VoxelTypeId id = m_names_synced_to + 1; id <= num; id++){
			const interface::VoxelDefinition *def = m_voxel_reg->get(id);
			if(!def)
				break;
			interface::VoxelTypeId save_id = save_id_of(def->name);
			if(save_id >= m_save_to_session.size())
				m_save_to_session.resize(save_id + 1, 0);
			m_save_to_session[save_id] = id;
			m_names_synced_to = id;
		}
		// What is left is a name the save has and the game does not register
		m_save_to_session.resize(m_save_names.size(), 0);
		for(size_t i = 1; i < m_save_names.size(); i++){
			if(m_save_to_session[i] != 0)
				continue; // Resolved once and for all: nothing is unregistered
			const interface::VoxelDefinition *def =
					adopt_unknown_voxel(m_save_names[i]);
			if(!def){
				refuse_save("the save holds voxel type "+
						m_save_names[i].dump()+", which this game does not "
						"register and the save's own definitions do not "
						"describe");
				return;
			}
			m_save_to_session[i] = def->id;
			if(def->id >= m_names_synced_to)
				m_names_synced_to = def->id;
		}
		m_session_to_save.assign(m_names_synced_to + 1, 0);
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			interface::VoxelTypeId sid = m_save_to_session[i];
			if(sid != 0 && sid < m_session_to_save.size())
				m_session_to_save[sid] = (interface::VoxelTypeId)i;
		}
		m_id_map_identity = true;
		for(size_t i = 1; i < m_save_to_session.size(); i++){
			if(m_save_to_session[i] != i){
				m_id_map_identity = false;
				break;
			}
		}
		for(size_t i = 1; m_id_map_identity && i < m_session_to_save.size();
				i++){
			if(m_session_to_save[i] != i)
				m_id_map_identity = false;
		}
		if(!m_id_map_identity && !m_logged_remap){
			m_logged_remap = true;
			size_t n = 0;
			for(size_t i = 1; i < m_save_to_session.size(); i++)
				if(m_save_to_session[i] != i)
					n++;
			log_i(MODULE, "World \"%s\": the save's voxel numbering is not "
					"this run's; %zu of %zu names are read and written through "
					"the table", cs(m_world_name), n,
					m_save_names.size() - 1);
		}
	}

	// The formats the save's chunks are in. A save may hold a mix and that
	// is the point: chunks are independent, so nothing is rewritten that was
	// not modified, and one damaged chunk is one damaged chunk.
	void load_format_table()
	{
		m_save_formats.clear();
		m_write_format = 0;
		ss_ data;
		if(m_store->get(formats_key(), data)){
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version != 1)
				throw Exception(ss_()+"voxelworld: the format table of world "
						"\""+m_world_name+"\" is version "+itos(version)+
						" and this build writes 1");
			ar(m_save_formats);
		}
		const interface::VoxelFormat &format = m_voxel_reg->get_format();
		for(size_t i = 0; i < m_save_formats.size(); i++){
			if(m_save_formats[i] == format){
				m_write_format = (uint16_t)i;
				return;
			}
		}
		m_save_formats.push_back(format);
		m_write_format = (uint16_t)(m_save_formats.size() - 1);
		save_format_table();
		if(m_save_formats.size() > 1)
			log_i(MODULE, "World \"%s\": %s is new to this save, which holds "
					"%zu formats now", cs(m_world_name), cs(format.dump()),
					m_save_formats.size());
	}

	void save_format_table()
	{
		if(!m_store)
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, m_save_formats);
		}
		m_store->set(formats_key(), os.str());
	}

	// The definitions themselves, so that a type the game stops registering
	// can still be drawn and still has a name. Not the authority on
	// numbering -- the name table is -- and written again whenever the game
	// has registered something since.
	void save_registry()
	{
		if(!m_store || m_registry_saved_to == m_names_synced_to)
			return;
		m_store->set(registry_key(), m_voxel_reg->serialize());
		m_registry_saved_to = m_names_synced_to;
	}

	sv_<interface::VoxelName> get_unknown_voxels()
	{
		return m_unknown_voxels;
	}

	void save()
	{
		if(!m_store)
			return;
		commit();
		size_t n = 0, total = 0;
		for(auto &sector_pair : m_sections){
			for(auto &section_pair : sector_pair.second){
				total++;
				if(!m_store) // A section can refuse the save
					continue;
				if(!section_pair.second.modified)
					continue;
				save_section(section_pair.second);
				n++;
			}
		}
		log_v(MODULE, "World \"%s\": saved %zu sections of %zu",
				cs(m_world_name), n, total);
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
			up_<VoxelVolume> volume =
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

		section->modified = true;

		// Mark node for collision box update
		mark_node_for_physics_update(node_id);

		m_server->emit_event("voxelworld:node_volume_updated",
				new NodeVolumeUpdated(m_scene_ref, node_id, true, chunk_p));
	}

	// The buffer a voxel is in and where in it, or nullptr. What set_voxel(),
	// set_sample() and get_sample() all start with; each of them used to
	// carry its own copy of this.
	ChunkBuffer* buffer_for(const pv::Vector3DInt32 &p,
			pv::Vector3DInt32 *voxel_p_out, bool disable_warnings,
			const char *what)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		pv::Vector3DInt16 section_p =
				container_coord16(chunk_p, m_section_size_chunks);
		Section *section = get_section(section_p);
		if(section == nullptr){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "%s() p=" PV3I_FORMAT ": No section "
					PV3I_FORMAT " for chunk " PV3I_FORMAT,
					what, PV3I_PARAMS(p), PV3I_PARAMS(section_p),
					PV3I_PARAMS(chunk_p));
			return nullptr;
		}

		maintain_maximum_buffer_limit();

		ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
				&m_total_buffers_loaded);
		if(!buf.volume){
			log_(disable_warnings ? CORE_DEBUG : CORE_WARNING,
					MODULE, "%s() p=" PV3I_FORMAT ": Couldn't get buffer "
					"volume for chunk " PV3I_FORMAT " in section "
					PV3I_FORMAT, what, PV3I_PARAMS(p), PV3I_PARAMS(chunk_p),
					PV3I_PARAMS(section_p));
			return nullptr;
		}
		*voxel_p_out = pv::Vector3DInt32(
				p.getX() - chunk_p.getX() * m_chunk_size_voxels.getX(),
				p.getY() - chunk_p.getY() * m_chunk_size_voxels.getY(),
				p.getZ() - chunk_p.getZ() * m_chunk_size_voxels.getZ()
		);

		auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
				m_sections_with_loaded_buffers.end(), section,
				std::greater<Section*>());
		if(it == m_sections_with_loaded_buffers.end() || *it != section)
			m_sections_with_loaded_buffers.insert(it, section);

		return &buf;
	}

	void mark_buffer_dirty(ChunkBuffer &buf)
	{
		if(!buf.dirty){
			buf.dirty = true;
			m_total_buffers_dirty++;
		}
	}

	void set_sample(const pv::Vector3DInt32 &p,
			const interface::VoxelSample &v, bool disable_warnings)
	{
		pv::Vector3DInt32 voxel_p;
		ChunkBuffer *buf = buffer_for(p, &voxel_p, disable_warnings,
				"set_sample");
		if(buf == nullptr)
			return;
		// A chunk written before the world had these planes, or one that
		// has never had anything but the first written into it, takes them
		// on here. The size test is what keeps this off the hot path.
		const sv_<interface::VoxelPlane> &planes =
				m_voxel_reg->get_format().planes;
		if(buf->volume->planes().size() != planes.size())
			buf->volume->add_planes(planes);

		interface::VoxelSample nv = v;
		if(m_skylight_enabled){
			interface::VoxelSample old = buf->volume->sample_at(voxel_p);
			VoxelInstance old_first(old.planes[0]);
			VoxelInstance first(nv.planes[0]);
			bool old_transparent = voxel_transmits_light(old);
			if(old_transparent != voxel_transmits_light(nv)){
				m_skylight_seeds.push_back(SkylightSeed{
						p, get_sky(old_first), old_transparent});
			}
			set_sky(first, get_sky(old_first));
			nv.planes[0] = first.data;
		}

		buf->volume->set_sample_at(voxel_p.getX(), voxel_p.getY(),
				voxel_p.getZ(), nv);
		mark_buffer_dirty(*buf);
	}

	interface::VoxelSample get_sample(const pv::Vector3DInt32 &p,
			bool disable_warnings)
	{
		pv::Vector3DInt32 voxel_p;
		ChunkBuffer *buf = buffer_for(p, &voxel_p, disable_warnings,
				"get_sample");
		if(buf == nullptr)
			return interface::VoxelSample();
		return buf->volume->sample_at(voxel_p);
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
			// The whole voxel, because which definition it wears can depend
			// on any of its planes; only the first one is being written
			interface::VoxelSample old = buf.volume->sample_at(voxel_p);
			interface::VoxelSample now = old;
			now.planes[0] = v.data;
			VoxelInstance old_first(old.planes[0]);
			bool old_transparent = voxel_transmits_light(old);
			if(old_transparent != voxel_transmits_light(now)){
				m_skylight_seeds.push_back(SkylightSeed{
						p, get_sky(old_first), old_transparent});
			}
			// Once skylight is on those bits belong to voxelworld, so they
			// are carried over from the voxel that was there; a caller
			// writing a plain voxel would otherwise wipe the light out of
			// one whose transparency did not change, and nothing would put
			// it back
			set_sky(nv, get_sky(old_first));
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

	// The voxels of a region in one read, chunk by chunk rather than voxel
	// by voxel through get_voxel(): what a caller of this is doing is a
	// sweep, and a section is a quarter of a million voxels.
	//
	// What is not there -- a section that is not loaded, a chunk nothing has
	// written -- is left undefined, which is what get_voxel() answers for
	// one and what the volume already holds.
	VoxelVolume get_volume(const pv::Region &region)
	{
		const pv::Vector3DInt32 rlc = region.getLowerCorner();
		const pv::Vector3DInt32 ruc = region.getUpperCorner();
		VoxelVolume out(region);
		if(ruc.getX() < rlc.getX() || ruc.getY() < rlc.getY() ||
				ruc.getZ() < rlc.getZ())
			return out;
		pv::Vector3DInt32 chunk_lc = container_coord(rlc, m_chunk_size_voxels);
		pv::Vector3DInt32 chunk_uc = container_coord(ruc, m_chunk_size_voxels);

		for(int cz = chunk_lc.getZ(); cz <= chunk_uc.getZ(); cz++){
		for(int cy = chunk_lc.getY(); cy <= chunk_uc.getY(); cy++){
		for(int cx = chunk_lc.getX(); cx <= chunk_uc.getX(); cx++){
			pv::Vector3DInt32 chunk_p(cx, cy, cz);
			pv::Vector3DInt16 section_p =
					container_coord16(chunk_p, m_section_size_chunks);
			Section *section = get_section(section_p);
			if(section == nullptr || !section->loaded)
				continue;
			ChunkBuffer &buf = section->get_buffer(chunk_p, m_server,
					&m_total_buffers_loaded);
			if(!buf.volume)
				continue;

			// Whatever planes the chunk has, the answer gets: a caller
			// reading a world of more than one plane is reading all of it
			out.add_planes(buf.volume->planes());
			const size_t num_extra_planes = buf.volume->planes().size() > 1 ?
					buf.volume->planes().size() - 1 : 0;

			pv::Region chunk_region = get_chunk_region_voxels(chunk_p);
			pv::Vector3DInt32 lc = chunk_region.getLowerCorner();
			pv::Vector3DInt32 uc = chunk_region.getUpperCorner();
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

			VoxelVolume::Sampler src(buf.volume.get());
			VoxelVolume::Sampler dst(&out);
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				src.setPosition(
						lc.getX() - chunk_off.getX(),
						y - chunk_off.getY(),
						z - chunk_off.getZ());
				dst.setPosition(lc.getX(), y, z);
			for(int x = lc.getX(); x <= uc.getX(); x++,
					src.movePositiveX(), dst.movePositiveX()){
				dst.setVoxel(src.getVoxel());
				for(size_t pi = 1; pi <= num_extra_planes; pi++){
					out.set_plane_at((uint8_t)pi, x, y, z,
							buf.volume->plane_at((uint8_t)pi,
							x - chunk_off.getX(), y - chunk_off.getY(),
							z - chunk_off.getZ()));
				}
			}
			}
			}

			auto it = std::lower_bound(m_sections_with_loaded_buffers.begin(),
					m_sections_with_loaded_buffers.end(), section,
					std::greater<Section*>());
			if(it == m_sections_with_loaded_buffers.end() || *it != section)
				m_sections_with_loaded_buffers.insert(it, section);
		}
		}
		}

		// Buffers were loaded above; keep to the limit once, not per voxel
		maintain_maximum_buffer_limit();
		return out;
	}

	// See the comment on Instance::merge_volume() in api.h for what the
	// priorities are. This is chunk by chunk rather than voxel by voxel
	// through set_voxel(): a section is a quarter of a million voxels, and
	// all of this is done while holding the module.
	void merge_volume(const VoxelVolume &volume,
			bool create_missing_sections)
	{
		write_volume(volume, create_missing_sections, false);
	}

	// The same walk that overwrites instead, which is what everything that
	// is not a generator wants: an importer, a VoxelManip, a mod putting a
	// building down.
	void set_volume(const VoxelVolume &volume, bool create_missing_sections)
	{
		write_volume(volume, create_missing_sections, true);
	}

	// overwrite tells the two apart: with it every defined voxel of the
	// volume is written, and without it the generator priorities in api.h
	// decide. A voxel that is undefined in the volume is skipped either
	// way, so a caller can leave holes.
	void write_volume(const VoxelVolume &volume,
			bool create_missing_sections, bool overwrite)
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

			// Whatever planes the incoming volume has, the chunk gets --
			// which is how a field a generator writes reaches storage
			// without voxelworld being told about it
			buf.volume->add_planes(volume.planes());
			const size_t num_extra_planes = volume.planes().size() > 1 ?
					volume.planes().size() - 1 : 0;

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
			VoxelVolume::Sampler src(
					const_cast<VoxelVolume*>(&volume));
			VoxelVolume::Sampler dst(buf.volume.get());

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
				if(is_undefined(nv))
					continue;
				VoxelInstance old = dst.getVoxel();
				bool old_undefined = is_undefined(old);
				// Which definition a voxel wears can depend on any of its
				// planes, so the questions below are asked of the whole
				// voxel and not of the word the sampler walks
				interface::VoxelSample src_v = num_extra_planes == 0 ?
						sample_of(nv) : volume.sample_at(x, y, z);
				interface::VoxelSample dst_v = num_extra_planes == 0 ?
						sample_of(old) : buf.volume->sample_at(
						x - chunk_off.getX(), y - chunk_off.getY(),
						z - chunk_off.getZ());
				if(!overwrite && !old_undefined){
					// Anything already standing here wins
					if(!voxel_is_fully_empty(dst_v))
						continue;
					// Empty stays empty unless something is put in it
					if(voxel_is_fully_empty(src_v))
						continue;
				}

				if(m_skylight_enabled){
					bool old_transparent = voxel_transmits_light(dst_v);
					if(old_transparent != voxel_transmits_light(src_v)){
						m_skylight_seeds.push_back(SkylightSeed{
								pv::Vector3DInt32(x, y, z),
								get_sky(old), old_transparent});
					}
					set_sky(nv, get_sky(old));
				}

				dst.setVoxel(nv);
				// The sampler is plane 0; anything else the volume carries
				// is copied by position. Only a world that has more than
				// one plane pays for this.
				for(size_t pi = 1; pi <= num_extra_planes; pi++){
					buf.volume->set_plane_at((uint8_t)pi,
							x - chunk_off.getX(),
							y - chunk_off.getY(),
							z - chunk_off.getZ(),
							volume.plane_at((uint8_t)pi, x, y, z));
				}
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

		log_d(MODULE, "%s: %zu voxels written",
				overwrite ? "set_volume()" : "merge_volume()", num_written);
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
			VoxelVolume &volume)
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
	bool voxel_is_fully_empty(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return false;
		const interface::CachedVoxelDefinition *def =
				m_voxel_reg->get_cached(v);
		if(def == nullptr)
			return false;
		return def->fully_empty;
	}

	bool voxel_transmits_light(const interface::VoxelSample &v)
	{
		if(is_undefined(VoxelInstance(v.planes[0])))
			return false;
		const interface::CachedVoxelDefinition *def =
				m_voxel_reg->get_cached(v);
		if(def == nullptr)
			return false;
		// Two ways light gets past a voxel: nothing is there, or something
		// is and the sky is seen through it anyway. See
		// VoxelDefinition::transmits_light.
		return def->edge_material_id == interface::EDGEMATERIALID_EMPTY ||
				def->transmits_light;
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
			if(transmits_light_at(n) || get_sky(nv) >= level)
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

	// Whether light passes through the voxel at p.
	//
	// By position rather than by value, and without the cache-by-id it used
	// to have, because **a voxel is its planes**: which definition it wears
	// can depend on any of them, and the first plane's id role says only
	// whether the voxel has been generated in a world whose looks come from
	// rules. What is left is the registry's own cached-definition array,
	// which is an index and a mutex.
	//
	// simplified: that mutex is now taken once per voxel of a light flood
	// where the cache made it once per id. If a flood ever shows up in a
	// profile, the fix is a per-flood memo keyed on the planes the rules
	// actually read.
	bool transmits_light_at(const pv::Vector3DInt32 &p)
	{
		pv::Vector3DInt32 chunk_p = container_coord(p, m_chunk_size_voxels);
		ChunkBuffer *buf = light_buffer(chunk_p);
		if(buf == nullptr)
			return false;
		return voxel_transmits_light(
				buf->volume->sample_at(light_local_p(p, chunk_p)));
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
			bool now_transparent = transmits_light_at(seed.p);
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
					if(!transmits_light_at(n))
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
				if(!transmits_light_at(n)){
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
			if(!transmits_light_at(node.p))
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
				if(!transmits_light_at(n)){
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
			if(transmits_light_at(p))
				continue;
			uint8_t best = 0;
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 np(
						p.getX() + LIGHT_OFF[k][0],
						p.getY() + LIGHT_OFF[k][1],
						p.getZ() + LIGHT_OFF[k][2]);
				VoxelInstance nv = light_get(np);
				if(transmits_light_at(np) && get_sky(nv) > best)
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
		section->modified = true;

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
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("replicate:peer_joined_scene"));
		m_server->sub_event(this, Event::t("replicate:peer_left_scene"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("main_context:scene_deleted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/voxelworld:set_send_distance"));
		/*m_server->sub_event(this, Event::t(
					"network:packet_received/voxelworld:get_section"));*/
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
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

	// The server is going away. A world with a save gets one last flush; one
	// without is unchanged by this, which is every game that has not asked
	// for persistence.
	void on_shutdown()
	{
		for(auto &pair : m_instances)
			pair.second->save();
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
