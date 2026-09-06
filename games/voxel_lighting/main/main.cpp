// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
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
#include <cmath>
#include <cstdio>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using main_context::SceneReference;

namespace main {

using namespace Urho3D;

// One section, so the whole scene is 64x64x64 voxels at 0..63 on each axis
static const int VOLUME_SIZE = 64;

// The cave runs along the camera's view direction so the camera looks straight
// into it. Kept in sync with client_lua/init.lua by hand; there are only two
// of them and the client cannot tell the server what it is looking at.
static const float VIEW_DIR_X = -1.0f;
static const float VIEW_DIR_Y = -0.7f;
static const float VIEW_DIR_Z = -1.0f;

// Tuned so the surface keeps sky above it and rock below it across the volume
static const float TERRAIN_AMPLITUDE = 9.0f;

// Shifts the terrain up or down in the volume. With the noise below, 0 puts
// the surface at roughly y=19..44, averaging the middle of the volume. The
// generator logs the range it actually got, so retune this by reading that.
static const float GROUND_OFFSET = 0.0f;

static const float CAVE_RADIUS = 3.5f;
static const float CAVE_LENGTH = 62.0f;

// The cave is the view direction rotated about the vertical axis through the
// centre of the volume, so that it does not run straight away from the camera.
// Positive is clockwise seen from above.
static const float CAVE_YAW_DEGREES = 20.0f;

struct Worldgen: public worldgen::GeneratorInterface
{
	// The client places its benchmark cameras relative to the cave, so it is
	// told where the cave ended up rather than recomputing it from a copy of
	// these constants.
	bool cave_valid = false;
	float cave_mouth[3] = {0, 0, 0};
	float cave_dir[3] = {0, 0, 0};

	void generate_section(interface::Server *server,
			SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p)
	{
		voxelworld::access(server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(scene_ref);

			pv::Region region = world->get_section_region_voxels(section_p);
			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			int w = uc.getX() - lc.getX() + 1;
			int d = uc.getZ() - lc.getZ() + 1;

			// Digger's terrain, but with the low frequencies dropped. Digger
			// spreads its first octave over 160 voxels, which inside a 64
			// voxel box reads as a tilt rather than as terrain. Starting at a
			// wavelength of exactly the volume size puts one hill and one
			// valley in the scene, and the octaves below it supply the detail.
			interface::v3f spread(VOLUME_SIZE, VOLUME_SIZE, VOLUME_SIZE);
			// Digger's amplitude is set for its own much longer wavelength;
			// at this one it would swing the surface across the whole volume.
			interface::NoiseParams np(0, TERRAIN_AMPLITUDE, spread, 0, 5, 0.4);
			interface::Noise noise(&np, 3, w, d);
			noise.perlinMap2D(lc.getX() + spread.X/2, lc.getZ() + spread.Z/2);
			noise.transformNoiseMap();

			// Reported so GROUND_OFFSET and TERRAIN_AMPLITUDE can be retuned
			// by reading it, rather than by deriving them at runtime
			float nmin = 1e9f, nmax = -1e9f;
			for(int i = 0; i < w * d; i++){
				float n = noise.result[i];
				if(n < nmin) nmin = n;
				if(n > nmax) nmax = n;
			}
			// Digger draws the topmost solid voxel at a+10, so a+11 is ground
			log_v(MODULE, "noise [%.1f, %.1f] -> surface %.0f..%.0f",
					nmin, nmax, nmin + GROUND_OFFSET + 11.0f,
					nmax + GROUND_OFFSET + 11.0f);

			auto surface_at = [&](int x, int z) -> float {
				size_t i = (size_t)(z - lc.getZ()) * w + (x - lc.getX());
				return noise.result[i] + GROUND_OFFSET;
			};

			// Everything is built into a local array first so that skylight
			// can be flood filled over the finished shape, and so that each
			// voxel is written to the world exactly once, with its light.
			const int W = uc.getX() - lc.getX() + 1;
			const int H = uc.getY() - lc.getY() + 1;
			const int D = uc.getZ() - lc.getZ() + 1;
			const uint8_t AIR = 1;
			sv_<uint8_t> ids((size_t)W * H * D, AIR);
			auto idx = [&](int x, int y, int z) -> size_t {
				return ((size_t)(y - lc.getY()) * D + (z - lc.getZ())) * W +
						(x - lc.getX());
			};
			auto inside = [&](int x, int y, int z){
				return x >= lc.getX() && x <= uc.getX() &&
						y >= lc.getY() && y <= uc.getY() &&
						z >= lc.getZ() && z <= uc.getZ();
			};
			auto set_id = [&](int x, int y, int z, uint8_t id){
				if(inside(x, y, z))
					ids[idx(x, y, z)] = id;
			};

			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					float a = surface_at(x, z);
					for(int y = lc.getY(); y <= uc.getY(); y++){
						if(y < a + 5)
							set_id(x, y, z, 2);
						else if(y < a + 10)
							set_id(x, y, z, 3);
						else if(y < a + 11)
							set_id(x, y, z, 4);
						else
							set_id(x, y, z, AIR);
					}
				}
			}

			// Trees, for something that casts a shadow with a shape to it.
			// Digger's density is a forest; here it would hide the terrain.
			// Seed picked by eye: keeps the cave mouth clear of canopy
			auto pr = interface::PseudoRandom(777);
			for(int i = 0; i < w * d / 400; i++){
				int x = pr.range(lc.getX() + 3, uc.getX() - 3);
				int z = pr.range(lc.getZ() + 3, uc.getZ() - 3);
				int y = (int)(surface_at(x, z) + 11.0f);
				if(y < lc.getY() || y > uc.getY() - 8)
					continue;

				for(int y1 = y; y1 < y + 4; y1++)
					set_id(x, y1, z, 6);
				for(int x1 = x-2; x1 <= x+2; x1++)
					for(int y1 = y+3; y1 <= y+7; y1++)
						for(int z1 = z-2; z1 <= z+2; z1++)
							set_id(x1, y1, z1, 5);
			}

			// Carve the cave with a sphere swept along the view direction
			// yawed by CAVE_YAW_DEGREES, starting in the air above the near
			// corner so that it breaks the surface and leaves a mouth instead
			// of a sealed pocket. Both the axis and its starting point are
			// rotated about the centre of the volume, so the whole cave turns
			// rather than just pivoting at the mouth.
			float ca = std::cos(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			float sa = std::sin(CAVE_YAW_DEGREES * 3.14159265f / 180.0f);
			auto rot_x = [&](float x, float z){ return x * ca + z * sa; };
			auto rot_z = [&](float x, float z){ return -x * sa + z * ca; };

			float centre_x = lc.getX() + VOLUME_SIZE / 2.0f;
			float centre_z = lc.getZ() + VOLUME_SIZE / 2.0f;

			float rdx = rot_x(VIEW_DIR_X, VIEW_DIR_Z);
			float rdz = rot_z(VIEW_DIR_X, VIEW_DIR_Z);
			float dl = std::sqrt(rdx*rdx + VIEW_DIR_Y*VIEW_DIR_Y + rdz*rdz);
			float dx = rdx / dl, dy = VIEW_DIR_Y / dl, dz = rdz / dl;

			float ox = (uc.getX() - 10) - centre_x;
			float oz = (uc.getZ() - 10) - centre_z;
			int mouth_x = (int)std::floor(centre_x + rot_x(ox, oz) + 0.5f);
			int mouth_z = (int)std::floor(centre_z + rot_z(ox, oz) + 0.5f);
			// surface_at() indexes the noise map, so it must stay in the region
			if(mouth_x < lc.getX()) mouth_x = lc.getX();
			if(mouth_x > uc.getX()) mouth_x = uc.getX();
			if(mouth_z < lc.getZ()) mouth_z = lc.getZ();
			if(mouth_z > uc.getZ()) mouth_z = uc.getZ();

			float sx = mouth_x;
			float sz = mouth_z;
			float sy = surface_at(mouth_x, mouth_z) + 11.0f + CAVE_RADIUS;

			size_t carved = 0;
			for(float t = 0.f; t <= CAVE_LENGTH; t += 0.5f){
				float cx = sx + dx * t, cy = sy + dy * t, cz = sz + dz * t;
				int x0 = (int)std::floor(cx - CAVE_RADIUS);
				int x1 = (int)std::ceil(cx + CAVE_RADIUS);
				int y0 = (int)std::floor(cy - CAVE_RADIUS);
				int y1 = (int)std::ceil(cy + CAVE_RADIUS);
				int z0 = (int)std::floor(cz - CAVE_RADIUS);
				int z1 = (int)std::ceil(cz + CAVE_RADIUS);
				for(int z = z0; z <= z1; z++){
					for(int y = y0; y <= y1; y++){
						for(int x = x0; x <= x1; x++){
							if(!inside(x, y, z))
								continue;
							float ddx = x - cx, ddy = y - cy, ddz = z - cz;
							if(ddx*ddx + ddy*ddy + ddz*ddz >
									CAVE_RADIUS * CAVE_RADIUS)
								continue;
							ids[idx(x, y, z)] = AIR;
							carved++;
						}
					}
				}
			}
			cave_mouth[0] = sx;
			cave_mouth[1] = sy;
			cave_mouth[2] = sz;
			cave_dir[0] = dx;
			cave_dir[1] = dy;
			cave_dir[2] = dz;
			cave_valid = true;

			log_v(MODULE, "Cave: mouth (%i, %.0f, %i), dir (%.2f, %.2f, %.2f), "
					"%zu brush writes", mouth_x, sy, mouth_z, dx, dy, dz,
					carved);

			// Skylight. Sunlight falls straight down through air at full
			// strength and stops at the first solid voxel; from there it
			// spreads sideways and downwards losing one step per voxel, which
			// is what makes a cave get darker the deeper it goes while a
			// hollow just under the surface stays bright.
			const uint8_t SKY_MAX = VoxelInstance::SKYLIGHT_MAX;
			sv_<uint8_t> sky((size_t)W * H * D, 0);
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					uint8_t l = SKY_MAX;
					for(int y = uc.getY(); y >= lc.getY(); y--){
						size_t i = idx(x, y, z);
						if(ids[i] != AIR)
							l = 0;
						sky[i] = l;
					}
				}
			}
			// One pass per level, brightest first: a voxel written during the
			// pass for level L is picked up by the pass for L-1, so this is a
			// breadth-first spread without a queue.
			for(int level = SKY_MAX; level >= 2; level--){
				for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					if(sky[idx(x, y, z)] != level)
						continue;
					static const int off[6][3] = {
						{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}
					};
					for(size_t k = 0; k < 6; k++){
						int nx = x + off[k][0], ny = y + off[k][1];
						int nz = z + off[k][2];
						if(!inside(nx, ny, nz))
							continue;
						size_t ni = idx(nx, ny, nz);
						if(ids[ni] != AIR || sky[ni] >= level - 1)
							continue;
						sky[ni] = level - 1;
					}
				}
				}
				}
			}
			// Solid voxels keep the brightest skylight next to them. The
			// mesher normally reads the air voxel in front of a face, but at a
			// chunk edge that voxel is outside the chunk it is meshing, and it
			// falls back to this.
			sv_<uint8_t> solid_sky((size_t)W * H * D, 0);
			for(int y = lc.getY(); y <= uc.getY(); y++){
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				size_t i = idx(x, y, z);
				if(ids[i] == AIR)
					continue;
				static const int off[6][3] = {
					{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}
				};
				uint8_t best = 0;
				for(size_t k = 0; k < 6; k++){
					int nx = x + off[k][0], ny = y + off[k][1];
					int nz = z + off[k][2];
					if(!inside(nx, ny, nz))
						continue;
					size_t ni = idx(nx, ny, nz);
					if(ids[ni] == AIR && sky[ni] > best)
						best = sky[ni];
				}
				solid_sky[i] = best;
			}
			}
			}

			size_t dark_air = 0, lit_air = 0;
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int z = lc.getZ(); z <= uc.getZ(); z++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						size_t i = idx(x, y, z);
						VoxelInstance v(ids[i]);
						v.set_skylight(ids[i] == AIR ? sky[i] : solid_sky[i]);
						world->set_voxel(pv::Vector3DInt32(x, y, z), v);
						if(ids[i] == AIR){
							if(sky[i] == 0) dark_air++;
							else lit_air++;
						}
					}
				}
			}
			log_v(MODULE, "Skylight: %zu lit air voxels, %zu fully dark",
					lit_air, dark_air);
		});
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_main_scene;
	Worldgen *m_worldgen = nullptr;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("worldgen:queue_modified"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent)
	}

	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid)
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
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
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
			m_worldgen = new Worldgen();
			iworldgen->get_instance(m_main_scene)->set_generator(m_worldgen);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			// A single section: the whole scene, never streamed
			pv::Region region(0, 0, 0, 0, 0, 0);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			interface::VoxelRegistry *reg = ivoxelworld->
					get_instance(m_main_scene)->get_voxel_reg();
			add_voxel(reg, "air", "", false);              // id 1
			add_voxel(reg, "rock", "main/rock.png", true); // id 2
			add_voxel(reg, "dirt", "main/dirt.png", true); // id 3
			add_voxel(reg, "grass", "main/grass.png", true); // id 4
			add_voxel(reg, "leaves", "main/leaves.png", true); // id 5
			add_voxel(reg, "tree", "main/tree.png", true); // id 6
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		log_v(MODULE, "voxel_lighting: %ix%ix%i scene",
				VOLUME_SIZE, VOLUME_SIZE, VOLUME_SIZE);
	}

	void on_unload()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			imc->delete_scene(m_main_scene);
		});
	}

	void on_continue()
	{
		on_start();
	}

	// "mx my mz dx dy dz"; the client turns it into camera positions
	ss_ cave_packet()
	{
		char buf[160];
		snprintf(buf, sizeof buf, "%f %f %f %f %f %f",
				m_worldgen->cave_mouth[0], m_worldgen->cave_mouth[1],
				m_worldgen->cave_mouth[2], m_worldgen->cave_dir[0],
				m_worldgen->cave_dir[1], m_worldgen->cave_dir[2]);
		return buf;
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
			// Generation normally finishes long before anyone connects; if it
			// has not, on_worldgen_queue_modified() sends this instead
			if(m_worldgen && m_worldgen->cave_valid)
				inetwork->send(event.recipient, "main:cave", cave_packet());
		});
	}

	void on_worldgen_queue_modified(const worldgen::QueueModifiedEvent &event)
	{
		if(event.queue_size != 0 || !m_worldgen || !m_worldgen->cave_valid)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			for(auto &peer : inetwork->list_peers())
				inetwork->send(peer, "main:cave", cave_packet());
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
