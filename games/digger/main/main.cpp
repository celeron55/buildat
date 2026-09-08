#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/noise.h"
#include "interface/voxel_volume.h"
#include <Scene.h>
#include <Context.h>
#include <StaticModel.h>
#include <Material.h>
#include <Texture2D.h>
#include <Technique.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#include <sstream>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using main_context::SceneReference;

// TODO: Move to a header (core/types_polyvox.h or something)
#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

// TODO: Move to a header (core/cereal_polyvox.h or something)
namespace cereal {

template<class Archive>
void save(Archive &archive, const pv::Vector3DInt32 &v){
	archive((int32_t)v.getX(), (int32_t)v.getY(), (int32_t)v.getZ());
}
template<class Archive>
void load(Archive &archive, pv::Vector3DInt32 &v){
	int32_t x, y, z;
	archive(x, y, z);
	v.setX(x); v.setY(y); v.setZ(z);
}

}

namespace main {

using namespace Urho3D;

// Everything at or below this that the terrain did not fill is water. The
// generator's surface runs from about y=13 to y=100 over the generated area,
// and this line puts water in the lowest 6% of it: a handful of ponds in the
// hollows rather than a sea with islands in it.
static const int WATER_LEVEL = 25;

struct Worldgen: public worldgen::GeneratorInterface
{
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			pv::RawVolume<VoxelInstance> &volume)
	{
		{
			const pv::Region region = volume.getEnclosingRegion();

			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			log_t(MODULE, "on_generation_request(): lc: (%i, %i, %i)",
					lc.getX(), lc.getY(), lc.getZ());
			log_t(MODULE, "on_generation_request(): uc: (%i, %i, %i)",
					uc.getX(), uc.getY(), uc.getZ());

			interface::v3f spread(160, 160, 160);
			interface::NoiseParams np(0, 20, spread, 0, 7, 0.4);

			int w = uc.getX() - lc.getX() + 1;
			int d = uc.getZ() - lc.getZ() + 1;

			interface::Noise noise(&np, 3, w, d);
			noise.perlinMap2D(lc.getX() + spread.X/2, lc.getZ() + spread.Z/2);
			noise.transformNoiseMap(); // ?

			size_t noise_i = 0;
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					double a = noise.result[noise_i];
					noise_i++;
					for(int y = lc.getY(); y <= uc.getY(); y++){
						pv::Vector3DInt32 p(x, y, z);
						pv::Vector3DInt32 cp(-112, 20, 253);
						if((p - cp).lengthSquared() < 30*30){
							volume.setVoxelAt(p, VoxelInstance(1));
							continue;
						}
						if(y >= 2 && y <= 3 && z >= 256 && z <= 258 &&
								x >= -112 && x <= -5){
							volume.setVoxelAt(p, VoxelInstance(1));
							continue;
						}
						if(z > 37 && z < 50 && y > 20){
							volume.setVoxelAt(p, VoxelInstance(1));
							continue;
						}
						if(x > 27 && x < 40 && y > 20){
							volume.setVoxelAt(p, VoxelInstance(1));
							continue;
						}
						if(x > 18 && x < 25 && z >= 32 && z <= 37 &&
								y > 20 && y < 25){
							volume.setVoxelAt(p, VoxelInstance(1));
							continue;
						}
						if(y < a+5){
							volume.setVoxelAt(p, VoxelInstance(2));
						} else if(y < a+10){
							volume.setVoxelAt(p, VoxelInstance(3));
						} else if(y < a+11){
							volume.setVoxelAt(p, VoxelInstance(4));
						} else if(y <= WATER_LEVEL){
							volume.setVoxelAt(p, VoxelInstance(7));
						} else {
							volume.setVoxelAt(p, VoxelInstance(1));
						}
					}
				}
			}

			// Add random trees
			auto extent = uc - lc + pv::Vector3DInt32(1, 1, 1);
			int area = extent.getX() * extent.getZ();
			auto pr = interface::PseudoRandom(13241);
			for(int i = 0; i < area / 100; i++){
				int x = pr.range(lc.getX(), uc.getX());
				int z = pr.range(lc.getZ(), uc.getZ());

				/*int y = 50;
				for(; y>-50; y--){
					pv::Vector3DInt32 p(x, y, z);
					VoxelInstance v = volume.getVoxelAt(p);
					if(v.get_id() != 1)
						break;
				}
				y++;*/
				size_t noise_i = (z-lc.getZ())*d + (x-lc.getX());
				double a = noise.result[noise_i];
				int y = a + 11.0;
				if(y < lc.getY() - 5 || y > uc.getY() - 5)
					continue;
				// The trunk would start under water
				if(y <= WATER_LEVEL)
					continue;

				for(int y1 = y; y1<y+4; y1++){
					pv::Vector3DInt32 p(x, y1, z);
					volume.setVoxelAt(p, VoxelInstance(6));
				}

				for(int x1 = x-2; x1 <= x+2; x1++){
					for(int y1 = y+3; y1 <= y+7; y1++){
						for(int z1 = z-2; z1 <= z+2; z1++){
							pv::Vector3DInt32 p(x1, y1, z1);
							volume.setVoxelAt(p, VoxelInstance(5));
						}
					}
				}
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;

	SceneReference m_main_scene;

	static const int SPAWN_X = -5;
	static const int SPAWN_Z = 257;
	static const int SPAWN_Y_MAX = 127;
	static const int SPAWN_Y_MIN = -64;
	static constexpr float PLAYER_HEIGHT = 1.7f;

	bool m_spawn_ready = false;
	float m_spawn_y = 0;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent);
	}

	// The six numbers after solid describe the surface; see interface/atlas.h.
	// visible is the edge material: an invisible voxel is also one light
	// passes through. top_texture, when given, goes on the +Y and -Y faces.
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool visible, bool solid,
			bool fully_empty, float roughness = 0.9f, float spec_strength = 1.0f,
			float bumpiness = 1.0f, float translucency = 0.0f,
			float spots = 0.0f, float static_spots = 0.0f,
			const ss_ &top_texture = "")
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.name.segment_x = 0;
		vdef.name.segment_y = 0;
		vdef.name.segment_z = 0;
		vdef.name.rotation_primary = 0;
		vdef.name.rotation_secondary = 0;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = (i < 2 && !top_texture.empty()) ?
					top_texture : texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
			seg.translucency = translucency;
			seg.spots = spots;
			seg.static_spots = static_spots;
		}
		vdef.edge_material_id = visible ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		// Worldgen must be created before the voxelworld; otherwise initial
		// generation request events are lost
		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);

			auto instance = iworldgen->get_instance(m_main_scene);
			instance->set_generator(new Worldgen());
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			//pv::Region region(0, 0, 0, 0, 0, 0); // Use this for valgrind
			//pv::Region region(-1, 0, -1, 1, 0, 1);
			//pv::Region region(-1, -1, -1, 1, 1, 1);
			//pv::Region region(-2, -1, -2, 2, 1, 2);
			//pv::Region region(-3, -1, -3, 3, 1, 3);
			pv::Region region(-5, -1, 0, 0, 1, 5);
			//pv::Region region(-5, -1, -5, 5, 1, 5);
			//pv::Region region(-6, -1, -6, 6, 1, 6);
			//pv::Region region(-8, -1, -8, 8, 1, 8);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		// Define voxels on core:start (woxelworld will restore them on reload)
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_main_scene);
			interface::VoxelRegistry *voxel_reg = world->get_voxel_reg();
			// roughness, spec_strength, bumpiness, translucency, spots,
			// static_spots; see interface/atlas.h. The values are
			// voxel_lighting's, which is where they were chosen.
			add_voxel(voxel_reg, "air", "", false, false, true);     // id 1
			add_voxel(voxel_reg, "rock", "main/rock.png", true, true, false,
					0.95f, 0.15f, 0.5f, 0.0f, 0.0f, 0.04f);    // id 2
			add_voxel(voxel_reg, "dirt", "main/dirt.png", true, true, false,
					0.98f, 0.15f, 0.6f, 0.0f, 0.0f, 0.04f);    // id 3
			add_voxel(voxel_reg, "grass", "main/grass.png", true, true, false,
					0.90f, 1.0f, 0.75f, 0.06f, 0.012f);        // id 4
			add_voxel(voxel_reg, "leaves", "main/leaves.png", true, true, false,
					0.95f, 1.0f, 1.5f, 0.11f, 0.03f);          // id 5
			add_voxel(voxel_reg, "tree", "main/tree.png", true, true, false,
					0.85f, 0.35f, 2.0f, 0.0f, 0.0f, 0.0f,
					"main/tree_top.png");                      // id 6
			// Walked into rather than stood on: the player sinks to the lake
			// floor and can dig or climb out. Nothing simulates flow, so a
			// dug shore leaves a hole in the water rather than draining it.
			add_voxel(voxel_reg, "water", "main/water.png", true, false, false,
					0.28f, 1.0f, 6.0f, 0.0f, 0.05f);           // id 7

			// Skylight, which is what the voxel shading reads to tell a cave
			// apart from a shadow. Enabled after the voxels are defined, as
			// it needs their edge materials to know what blocks light.
			world->set_skylight_enabled(true);
		});

		// Enable world generation now that the voxels are defined
		worldgen::access(m_server, m_main_scene, [&](worldgen::Instance *instance)
		{
			instance->enable();
		});
	}

	void on_unload()
	{
		// TODO: Store main scene reference
		// Just do this for now
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		// TODO: Restore main scene reference
		// Just do this for now
		on_start();
	}

	// Standing-height air along -X (player facing). No path check; long enough
	// that it is likely to hit a slope, pocket, or the world edge.
	void carve_spawn_tunnel(int floor_y)
	{
		const int length = 96;
		const int height = 3;
		const int half_w = 1;
		const int back = 2;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int dx = -back; dx < length; dx++){
				int x = SPAWN_X - dx;
				for(int dz = -half_w; dz <= half_w; dz++){
					int z = SPAWN_Z + dz;
					for(int dy = 1; dy <= height; dy++){
						world->set_voxel(
								pv::Vector3DInt32(x, floor_y + dy, z),
								VoxelInstance(1), true);
					}
				}
			}
		});
		log_i(MODULE, "Spawn tunnel: x=%i..%i y=%i..%i z=%i..%i",
				SPAWN_X + back, SPAWN_X - (length - 1),
				floor_y + 1, floor_y + height,
				SPAWN_Z - half_w, SPAWN_Z + half_w);
	}

	void send_spawn(network::PeerInfo::Id peer)
	{
		if(!m_spawn_ready)
			return;
		std::ostringstream os(std::ios::binary);
		cereal::PortableBinaryOutputArchive ar(os);
		double x = SPAWN_X;
		double y = m_spawn_y;
		double z = SPAWN_Z;
		ar(x, y, z);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:spawn", os.str());
		});
		log_v(MODULE, "Sent spawn (%.2f, %.2f, %.2f) to peer %zu",
				x, y, z, peer);
	}

	// Terrain ids: 2 rock, 3 dirt, 4 grass. Skip air (1), trees/leaves (5, 6).
	void try_resolve_spawn()
	{
		if(m_spawn_ready)
			return;
		int surface_y = SPAWN_Y_MIN - 1;
		bool column_ready = true;
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int y = SPAWN_Y_MAX; y >= SPAWN_Y_MIN; y--){
				VoxelInstance v = world->get_voxel(
						pv::Vector3DInt32(SPAWN_X, y, SPAWN_Z), true);
				auto id = v.get_id();
				if(id == interface::VOXELTYPEID_UNDEFINED){
					column_ready = false;
					return;
				}
				if(id == 2 || id == 3 || id == 4){
					surface_y = y;
					return;
				}
			}
		});
		if(!column_ready)
			return;
		if(surface_y < SPAWN_Y_MIN){
			log_w(MODULE, "Spawn column (%i, *, %i) has no terrain",
					SPAWN_X, SPAWN_Z);
			return;
		}
		carve_spawn_tunnel(surface_y);
		// Voxel n is a 1x1x1 cube centered at n; stand on its top face.
		m_spawn_y = (float)surface_y + 0.5f + PLAYER_HEIGHT / 2.0f + 0.05f;
		m_spawn_ready = true;
		log_i(MODULE, "Spawn at (%i, %.2f, %i) (terrain y=%i)",
				SPAWN_X, m_spawn_y, SPAWN_Z, surface_y);

		network::access(m_server, [&](network::Interface *inetwork){
			std::ostringstream os(std::ios::binary);
			cereal::PortableBinaryOutputArchive ar(os);
			double x = SPAWN_X;
			double y = m_spawn_y;
			double z = SPAWN_Z;
			ar(x, y, z);
			ss_ data = os.str();
			for(auto peer : inetwork->list_peers())
				inetwork->send(peer, "main:spawn", data);
		});
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		size_t queue_size = 0;
		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			queue_size = instance->get_num_sections_queued();
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
			inetwork->send(event.recipient, "main:worldgen_queue_size",
					itos(queue_size));
		});
		send_spawn(event.recipient);
	}

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_place_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			instance->set_voxel(voxel_p, VoxelInstance(2));
		});
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 voxel_p;
		{
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		}
		log_v(MODULE, "C%i: on_dig_voxel(): p=" PV3I_FORMAT,
				packet.sender, PV3I_PARAMS(voxel_p));

		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *instance)
		{
			instance->set_voxel(voxel_p, VoxelInstance(1));
		});
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		log_t(MODULE, "on_worldgen_queue_modified()");
		network::access(m_server, [&](network::Interface *inetwork){
			sv_<network::PeerInfo::Id> peers = inetwork->list_peers();
			for(auto &peer: peers){
				inetwork->send(peer, "main:worldgen_queue_size",
						itos(event.queue_size));
			}
		});
		if(event.queue_size == 0)
			try_resolve_spawn();
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
