// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// vanilla with voxel physics ([VOXEL_PHYSICS_SAMPLE]): what this game adds
// to games/vanilla, which it is a variant of ([GAME_BASE]). A sample, not a
// serious game.
//
// The simulation is undermine's (games/undermine/main/main.cpp): a support
// number per voxel -- how far it is from something holding it up, reaching
// sideways as far as its material spans -- and a load, the column above
// it against what it carries; both recomputed around a change and nowhere
// else, so generated matter is judged as it is when a player first digs
// into it. What undermine reads from its material table is read here out
// of the game's node definitions by heuristics over their groups, and
// what fails does not fall voxel by voxel: the unsupported, connected
// portion comes off the world as one body with a rigid body, and falls
// under the scene's physics (games/voxel_physics's pieces). Where it goes
// when it lands is decided after the playtest: it lies where it stops.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "network/api.h"
#include "client_file/api.h"
#include <cereal/archives/portable_binary.hpp>
#include <Scene.h>
#include <Node.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <sstream>
#include <chrono>
#include <cmath>
#define MODULE "voxel_physics"

namespace pv = PolyVox;
using interface::Event;
using interface::VoxelInstance;
using interface::VoxelSample;
using main_context::SceneReference;

#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

namespace cereal {
template<class Archive>
void load(Archive &archive, pv::Vector3DInt32 &v){
	int32_t x, y, z;
	archive(x, y, z);
	v.setX(x); v.setY(y); v.setZ(z);
}
}

namespace voxel_physics {

using namespace Urho3D;

// The state plane: the low nibble how far from support (0 for nothing),
// the high nibble how loaded, 0...15 of what it carries
static const char *STATE_PLANE = "voxel_physics:state";
static const uint8_t SUPPORT_MAX = 15;
static const uint8_t BAND_MAX = 15;
static const uint8_t LOAD_MAX = 255;
// How far up a voxel is asked to carry; undermine's LOAD_DEPTH and its
// simplification: the column immediately above and no further
static const int LOAD_DEPTH = 32;
// Everything at or under this is supported: VoxeLibre's overworld floor is
// -62 with bedrock to -58, and nothing a player undermines is deeper
// (decided, 2026-09-22)
static const int SUPPORTED_BELOW_Y = -60;
static const size_t SIM_PER_TICK = 2048;
// The most voxels one body takes with it; what is left over is looked at
// again on the next tick
static const size_t BODY_MAX_VOXELS = 4096;
static const uint16_t CONTENT_AIR = 2;

// What the heuristics decided about a node; see the Lua below
struct Props
{
	bool structural = false;
	bool diggable = false;
	uint8_t span = 0;
	uint8_t density = 0;
	uint8_t capacity = 0;
};

// The heuristics, over the game's own definitions: which group a node
// digs as says roughly what it is made of. cracky is rock, choppy timber,
// crumbly dirt or sand (sand and gravel span nothing), snappy and leaves
// hang and weigh nothing, unbreakable is the bedrock role; what walks
// through -- air, liquids, plants -- takes no part. simplified: the
// per-game override table the plan names is not here yet; VoxeLibre's
// groups read well enough for the first playtest.
static const char *PROPS_LUA = R"LUA(
function core.__voxel_physics_props()
	local out = {}
	for name, def in pairs(core.registered_nodes) do
		local g = def.groups or {}
		local rec = nil
		if def.walkable == false or def.drawtype == "airlike" or
				(def.liquidtype ~= nil and def.liquidtype ~= "none") then
			rec = nil
		elseif g.unbreakable or name:find("bedrock", 1, true) then
			rec = {0, 15, 0, 255}
		elseif g.snappy or g.leaves or g.leafdecay then
			rec = {1, 2, 0, 10}
		elseif g.cracky then
			rec = {1, 6, 3, 200}
		elseif g.choppy then
			rec = {1, 8, 1, 30}
		elseif g.crumbly then
			if g.falling_node or name:find("sand", 1, true) or
					name:find("gravel", 1, true) then
				rec = {1, 0, 2, 40}
			else
				rec = {1, 2, 2, 60}
			end
		else
			rec = {1, 3, 3, 150}
		end
		if rec then
			out[#out + 1] = table.concat({core.get_content_id(name), rec[1],
					rec[2], rec[3], rec[4], name}, "\t")
		end
	end
	return out
end
)LUA";

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_scene = nullptr;
	int m_state_plane = -1;
	std::vector<Props> m_props; // By content id
	std::unordered_set<size_t> m_shown; // Peers the client half was run on

	// The relaxation's queue and its scratch, as undermine's
	std::deque<pv::Vector3DInt32> m_dirty;
	std::unordered_set<int64_t> m_dirty_set;
	struct Pending { pv::Vector3DInt32 p; VoxelSample v; };
	std::unordered_map<int64_t, Pending> m_scratch;
	std::vector<pv::Vector3DInt32> m_failing;
	std::unordered_set<int64_t> m_failing_set;
	size_t m_bodies = 0;
	sv_<uint> m_body_nodes;
	int m_ticks = 0;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:packet_received/main:dig"));
		m_server->sub_event(this, Event::t("network:packet_received/main:place"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("voxelworld:node_volume_updated"));
		// Before the game runs: the luanti module keeps the chunk until
		// then and runs it with the builtin, so the function is there when
		// the game has loaded
		luanti::access(m_server, [&](luanti::Interface *i){
			i->load_lua(PROPS_LUA, "voxel_physics");
			// The bodies land on the terrain's server-side shapes; see
			// [VOXEL_PHYSICS_PERF] for what that costs
			i->set_server_physics(true);
		});
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:packet_received/main:dig", on_dig,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:place", on_place,
				network::Packet)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("voxelworld:node_volume_updated", on_node_volume_updated,
				voxelworld::NodeVolumeUpdated)
	}

	// The world exists and the luanti module has set its format: the
	// state plane goes on beside it, and every chunk takes it on the
	// first time the sim writes into it
	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		voxelworld::access(m_server, m_scene,
				[&](voxelworld::Instance *world){
			m_state_plane = world->get_voxel_reg()->add_plane(STATE_PLANE, 8);
			log_i(MODULE, "%s is plane %i: %s", STATE_PLANE, m_state_plane,
					cs(world->get_voxel_reg()->get_format().dump()));
		});
		sv_<ss_> flat;
		luanti::access(m_server, [&](luanti::Interface *i){
			flat = i->call_string_list("__voxel_physics_props");
		});
		size_t structural = 0;
		for(const ss_ &line : flat){
			std::istringstream is(line);
			int id = 0, s = 0, span = 0, density = 0, capacity = 0;
			is >> id >> s >> span >> density >> capacity;
			if(id < 0 || id > 65535)
				continue;
			if(m_props.size() <= (size_t)id)
				m_props.resize(id + 1);
			Props &p = m_props[id];
			p.structural = true;
			p.diggable = s != 0;
			p.span = (uint8_t)span;
			p.density = (uint8_t)density;
			p.capacity = (uint8_t)capacity;
			structural++;
		}
		log_i(MODULE, "%zu node types take part in the physics", structural);
	}

	// The client half, after the game's own: main:init.lua has the
	// registries and the scene by then, and this draws the bodies
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		if(!m_shown.insert(event.recipient).second)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"voxel_physics/init.lua\")");
		});
	}

	// The player's changes are what wake the sim. Kept until the chunk
	// they are in is committed: the game's own handler of the same packet
	// is what makes the change, and it ran after this one and after the
	// tick between (2026-09-22) -- the commit is the change having
	// happened, whatever the order
	sv_<pv::Vector3DInt32> m_pending;

	void on_node_volume_updated(const voxelworld::NodeVolumeUpdated &event)
	{
		if(!event.is_static_chunk || m_pending.empty() || m_scene == nullptr)
			return;
		pv::Vector3DInt16 cs(16, 16, 16);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			cs = world->get_chunk_size_voxels();
		});
		sv_<pv::Vector3DInt32> left;
		for(const pv::Vector3DInt32 &p : m_pending){
			pv::Vector3DInt32 c(
					(int)std::floor((float)p.getX() / cs.getX()),
					(int)std::floor((float)p.getY() / cs.getY()),
					(int)std::floor((float)p.getZ() / cs.getZ()));
			if(c == event.chunk_p)
				mark_changed(p);
			else
				left.push_back(p);
		}
		m_pending.swap(left);
	}

	void on_dig(const network::Packet &packet)
	{
		pv::Vector3DInt32 p;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(p);
		} catch(std::exception &e){
			return;
		}
		m_pending.push_back(p);
	}

	void on_place(const network::Packet &packet)
	{
		pv::Vector3DInt32 under, above;
		uint8_t sneak = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(under, above, sneak);
		} catch(std::exception &e){
			return;
		}
		m_pending.push_back(under);
		m_pending.push_back(above);
	}

	// The simulation
	// --------------

	static int64_t pos_key(const pv::Vector3DInt32 &p)
	{
		return ((int64_t)(p.getX() & 0xfffff) << 40) |
				((int64_t)(p.getY() & 0xfffff) << 20) |
				(int64_t)(p.getZ() & 0xfffff);
	}

	const Props& props_of(uint32_t id)
	{
		static const Props none;
		return id < m_props.size() ? m_props[id] : none;
	}

	uint32_t id_of(voxelworld::Instance *world, const VoxelSample &v)
	{
		return world->get_voxel_reg()->get_format().id_of(v.planes[0]);
	}
	uint8_t support_of(const VoxelSample &v)
	{
		return v.planes[m_state_plane] & 0xf;
	}
	uint8_t band_of(const VoxelSample &v)
	{
		return (v.planes[m_state_plane] >> 4) & 0xf;
	}
	void set_state(VoxelSample &v, uint8_t support, uint8_t band)
	{
		v.planes[m_state_plane] = (uint32_t)(support & 0xf) |
				((uint32_t)(band & 0xf) << 4);
	}
	static uint8_t load_band(uint32_t load, uint8_t capacity)
	{
		if(capacity == 0)
			return 0;
		uint32_t band = load * (BAND_MAX + 1) / ((uint32_t)capacity + 1);
		return (uint8_t)(band > BAND_MAX ? BAND_MAX : band);
	}

	void mark_dirty(const pv::Vector3DInt32 &p)
	{
		if(m_dirty_set.insert(pos_key(p)).second)
			m_dirty.push_back(p);
	}

	// What has to be looked at again after the voxel at p changed: itself,
	// the six around it, and the LOAD_DEPTH voxels under it
	void mark_changed(const pv::Vector3DInt32 &p)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		mark_dirty(p);
		for(size_t k = 0; k < 6; k++)
			mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
					p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		for(int i = 1; i <= LOAD_DEPTH; i++)
			mark_dirty(pv::Vector3DInt32(p.getX(), p.getY() - i, p.getZ()));
	}

	void mark_failing(const pv::Vector3DInt32 &p)
	{
		if(m_failing_set.insert(pos_key(p)).second)
			m_failing.push_back(p);
	}

	VoxelSample peek(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		auto it = m_scratch.find(pos_key(p));
		if(it != m_scratch.end())
			return it->second.v;
		return world->get_sample(p, true);
	}

	// How far the voxel at p is from something holding it up, 0 for
	// nothing. Standing on something supported is supported; otherwise it
	// reaches sideways from its neighbours, one step less per voxel and
	// never past its span. The edge of what is loaded, and everything
	// under SUPPORTED_BELOW_Y, holds.
	uint8_t compute_support(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p, const Props &m)
	{
		if(!m.diggable || p.getY() <= SUPPORTED_BELOW_Y)
			return SUPPORT_MAX;
		VoxelSample below = peek(world,
				pv::Vector3DInt32(p.getX(), p.getY() - 1, p.getZ()));
		uint32_t bid = id_of(world, below);
		if(bid == interface::VOXELTYPEID_UNDEFINED)
			return SUPPORT_MAX;
		const Props &bm = props_of(bid);
		if(bm.structural && (support_of(below) > 0 || !bm.diggable))
			return SUPPORT_MAX;
		// Generated matter carries no state until the sim has been by:
		// a neighbour nothing has judged reads as held up, so the front
		// spreads through what the change touched and stops at what it
		// did not (the sim wakes only around a change)
		if(bm.structural && !judged(below))
			return SUPPORT_MAX;
		if(m.span == 0)
			return 0;
		static const int SIDE[4][2] = {{1,0}, {-1,0}, {0,1}, {0,-1}};
		uint8_t best = 0;
		for(size_t k = 0; k < 4; k++){
			VoxelSample n = peek(world, pv::Vector3DInt32(
					p.getX() + SIDE[k][0], p.getY(), p.getZ() + SIDE[k][1]));
			uint32_t nid = id_of(world, n);
			if(nid == interface::VOXELTYPEID_UNDEFINED)
				return SUPPORT_MAX;
			const Props &nm = props_of(nid);
			if(!nm.structural)
				continue;
			uint8_t s = judged(n) ? support_of(n) : SUPPORT_MAX;
			if(s > best)
				best = s;
		}
		if(best == 0)
			return 0;
		uint8_t reach = best - 1;
		return reach < m.span ? reach : m.span;
	}

	// Whether the sim has written this voxel's state: a state of 0 is what
	// a voxel nothing wrote reads as, and it is never what the sim writes
	// for a structural voxel (a judged voxel with no support is failing,
	// and is marked with the band nibble's top bit)
	bool judged(const VoxelSample &v)
	{
		return v.planes[m_state_plane] != 0;
	}

	uint8_t compute_load(voxelworld::Instance *world,
			const pv::Vector3DInt32 &p)
	{
		int carried = 0;
		for(int i = 1; i <= LOAD_DEPTH; i++){
			VoxelSample v = peek(world,
					pv::Vector3DInt32(p.getX(), p.getY() + i, p.getZ()));
			const Props &m = props_of(id_of(world, v));
			if(!m.structural)
				break;
			carried += m.density;
			if(carried >= LOAD_MAX)
				return LOAD_MAX;
		}
		return (uint8_t)carried;
	}

	void update_voxel(voxelworld::Instance *world, const pv::Vector3DInt32 &p)
	{
		VoxelSample v = peek(world, p);
		uint32_t id = id_of(world, v);
		if(id == interface::VOXELTYPEID_UNDEFINED)
			return;
		const Props &m = props_of(id);
		if(!m.structural)
			return;
		uint8_t support = compute_support(world, p, m);
		uint8_t load = compute_load(world, p);
		uint8_t band = load_band(load, m.capacity);
		bool fails = m.diggable && (support == 0 || load > m.capacity);
		// The band's top bit says "judged and failing", so a state is
		// never 0 once written; see judged()
		if(fails)
			band |= 8;
		// A voxel judged for the first time was read as fully supported
		// by whatever asked about it (see compute_support), so it moved
		// only when it is not: judging supported rock does not spread
		bool support_moved = judged(v) ? support != support_of(v) :
				support != SUPPORT_MAX;
		if(support_moved || band != band_of(v)){
			VoxelSample nv = v;
			set_state(nv, support, band);
			m_scratch[pos_key(p)] = Pending{p, nv};
		}
		if(support_moved){
			static const int OFF[6][3] = {
				{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
			};
			for(size_t k = 0; k < 6; k++)
				mark_dirty(pv::Vector3DInt32(p.getX() + OFF[k][0],
						p.getY() + OFF[k][1], p.getZ() + OFF[k][2]));
		}
		if(fails){
			log_v(MODULE, "fails: " PV3I_FORMAT " id=%u support=%i load=%i",
					PV3I_PARAMS(p), id, (int)support, (int)load);
			mark_failing(p);
		}
	}

	void flush_scratch(voxelworld::Instance *world)
	{
		for(auto &e : m_scratch)
			world->set_sample(e.second.p, e.second.v, true);
		m_scratch.clear();
	}

	// Bodies
	// ------

	// What comes off with a failing voxel: everything structural and
	// diggable connected to it that is failing or holds no support of its
	// own, and whatever stands directly on those -- a column standing on
	// what falls falls with it, whether or not the relaxation has got to
	// it yet
	void collect_body(voxelworld::Instance *world, const pv::Vector3DInt32 &start,
			std::vector<pv::Vector3DInt32> &out)
	{
		static const int OFF[6][3] = {
			{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1},
		};
		std::unordered_set<int64_t> seen;
		std::deque<pv::Vector3DInt32> queue;
		queue.push_back(start);
		seen.insert(pos_key(start));
		while(!queue.empty() && out.size() < BODY_MAX_VOXELS){
			pv::Vector3DInt32 p = queue.front();
			queue.pop_front();
			out.push_back(p);
			for(size_t k = 0; k < 6; k++){
				pv::Vector3DInt32 n(p.getX() + OFF[k][0], p.getY() + OFF[k][1],
						p.getZ() + OFF[k][2]);
				if(!seen.insert(pos_key(n)).second)
					continue;
				VoxelSample v = world->get_sample(n, true);
				const Props &m = props_of(id_of(world, v));
				if(!m.structural || !m.diggable)
					continue;
				bool above = OFF[k][1] == 1;
				bool loose = judged(v) && (support_of(v) == 0 || (band_of(v) & 8));
				if(loose || above)
					queue.push_back(n);
			}
		}
	}

	// The body cut out of the world: the voxels into a volume of the
	// world's format with a one-voxel border (the mesher wants one), air
	// where they were, and a node at the volume's corner with a rigid
	// body and a box per voxel. The client half meshes the volume.
	void make_body(voxelworld::Instance *world,
			const std::vector<pv::Vector3DInt32> &voxels)
	{
		pv::Vector3DInt32 lo = voxels[0], hi = voxels[0];
		for(const pv::Vector3DInt32 &p : voxels){
			lo = pv::Vector3DInt32(std::min(lo.getX(), p.getX()),
					std::min(lo.getY(), p.getY()), std::min(lo.getZ(), p.getZ()));
			hi = pv::Vector3DInt32(std::max(hi.getX(), p.getX()),
					std::max(hi.getY(), p.getY()), std::max(hi.getZ(), p.getZ()));
		}
		pv::Vector3DInt32 size = hi - lo + pv::Vector3DInt32(1, 1, 1);
		interface::VoxelVolume volume(pv::Region(pv::Vector3DInt32(-1, -1, -1),
				size), world->get_voxel_reg()->get_format().planes);
		float mass = 0;
		for(const pv::Vector3DInt32 &p : voxels){
			VoxelSample v = world->get_sample(p, true);
			set_state(v, SUPPORT_MAX, 0);
			volume.set_sample_at(p.getX() - lo.getX(), p.getY() - lo.getY(),
					p.getZ() - lo.getZ(), v);
			mass += props_of(id_of(world, v)).density;
			world->set_voxel(p, VoxelInstance(CONTENT_AIR), true);
			mark_changed(p);
		}
		ss_ data = interface::serialize_volume_compressed(volume);
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			Node *n = scene->CreateChild("VoxelBody");
			n->SetPosition(Vector3(lo.getX() - 0.5f, lo.getY() - 0.5f,
					lo.getZ() - 0.5f));
			n->SetVar(StringHash("voxel_body_data"), Variant(
					PODVector<uint8_t>((const uint8_t*)data.c_str(),
					data.size())));
			RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
			body->SetFriction(0.8f);
			body->SetMass(mass > 0 ? mass : 1.0f);
			m_body_nodes.push_back(n->GetID());
			for(const pv::Vector3DInt32 &p : voxels){
				CollisionShape *shape = n->CreateComponent<CollisionShape>(LOCAL);
				shape->SetBox(Vector3::ONE, Vector3(
						p.getX() - lo.getX() + 0.5f, p.getY() - lo.getY() + 0.5f,
						p.getZ() - lo.getZ() + 0.5f));
			}
		});
		m_bodies++;
		log_i(MODULE, "body %zu: %zu voxels from " PV3I_FORMAT " to "
				PV3I_FORMAT ", mass %.0f", m_bodies, voxels.size(),
				PV3I_PARAMS(lo), PV3I_PARAMS(hi), mass);
	}

	void step_failing(voxelworld::Instance *world)
	{
		std::vector<pv::Vector3DInt32> failing;
		failing.swap(m_failing);
		m_failing_set.clear();
		for(const pv::Vector3DInt32 &p : failing){
			VoxelSample v = world->get_sample(p, true);
			const Props &m = props_of(id_of(world, v));
			// Dug, held up again, or gone with an earlier body
			if(!m.structural || !m.diggable || !judged(v))
				continue;
			if(support_of(v) != 0 && compute_load(world, p) <= m.capacity)
				continue;
			std::vector<pv::Vector3DInt32> voxels;
			collect_body(world, p, voxels);
			make_body(world, voxels);
		}
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_scene == nullptr)
			return;
		// Where the bodies are, now and then: the reading a playtest wants
		if(++m_ticks % 100 == 0 && !m_body_nodes.empty()){
			main_context::access(m_server, [&](main_context::Interface *imc){
				Scene *scene = imc->check_scene(m_scene);
				for(uint id : m_body_nodes){
					Node *n = scene->GetNode(id);
					if(!n)
						continue;
					Vector3 p = n->GetPosition();
					log_i(MODULE, "body node %u at %.1f, %.1f, %.1f", id,
							p.x_, p.y_, p.z_);
				}
			});
		}
		if(m_dirty.empty() && m_failing.empty())
			return;
		auto t0 = std::chrono::steady_clock::now();
		size_t done = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			while(!m_dirty.empty() && done < SIM_PER_TICK){
				pv::Vector3DInt32 p = m_dirty.front();
				m_dirty.pop_front();
				m_dirty_set.erase(pos_key(p));
				update_voxel(world, p);
				done++;
			}
			flush_scratch(world);
			// Once the front has settled: a body is cut out of what the
			// whole relaxation says, not half of it
			if(m_dirty.empty())
				step_failing(world);
		});
		log_v(MODULE, "sim: %zu done in %i us, %zu dirty, %zu failing, "
				"%zu bodies", done, (int)std::chrono::duration_cast<
				std::chrono::microseconds>(
				std::chrono::steady_clock::now() - t0).count(),
				m_dirty.size(), m_failing.size(), m_bodies);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_voxel_physics(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
