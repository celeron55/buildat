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
#include "interface/polyvox_std.h"
#include "interface/polyvox_cereal.h"
#include <cereal/archives/portable_binary.hpp>
#include <cmath>
#include <cstdio>
#include <sstream>
#include <chrono>
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

// The benchmark edits: a shaft dug straight up out of the cave to the open air,
// and a slab hung over the cave mouth. The shaft starts this far along the cave
// axis, which is deep enough that the skylight there is 0 before it is dug, so
// what the relight has to do is bring a whole column of daylight into a part of
// the scene that had none. It is also in front of benchmark camera 3, so the
// change shows from inside the cave as well as from above.
static const float BENCH_SHAFT_T = 20.0f;
static const int BENCH_SHAFT_W = 3;
static const int BENCH_SLAB_W = 5;
static const int BENCH_SLAB_H = 2;

static const uint8_t AIR_ID = 1;

static inline size_t sky_idx(int x, int y, int z, int W, int D)
{
	return ((size_t)y * D + z) * W + x;
}

// Skylight over a W*H*D block of voxel ids. Sunlight falls straight down
// through air at full strength and stops at the first solid voxel; from there
// it spreads sideways and downwards losing one step per voxel, which is what
// makes a cave get darker the deeper it goes while a hollow just under the
// surface stays bright.
//
// sky is the light in air voxels. solid_sky is the brightest skylight next to
// a solid voxel: the mesher normally reads the air voxel in front of a face,
// but at a chunk edge that voxel is outside the chunk it is meshing, and it
// falls back to this.
static void compute_skylight(const sv_<uint8_t> &ids, int W, int H, int D,
		sv_<uint8_t> &sky, sv_<uint8_t> &solid_sky)
{
	const uint8_t SKY_MAX = VoxelInstance::SKYLIGHT_MAX;
	static const int off[6][3] = {
		{1,0,0}, {-1,0,0}, {0,1,0}, {0,-1,0}, {0,0,1}, {0,0,-1}
	};
	auto inside = [&](int x, int y, int z){
		return x >= 0 && x < W && y >= 0 && y < H && z >= 0 && z < D;
	};

	sky.assign((size_t)W * H * D, 0);
	solid_sky.assign((size_t)W * H * D, 0);

	for(int z = 0; z < D; z++){
		for(int x = 0; x < W; x++){
			uint8_t l = SKY_MAX;
			for(int y = H - 1; y >= 0; y--){
				size_t i = sky_idx(x, y, z, W, D);
				if(ids[i] != AIR_ID)
					l = 0;
				sky[i] = l;
			}
		}
	}
	// One pass per level, brightest first: a voxel written during the pass for
	// level L is picked up by the pass for L-1, so this is a breadth-first
	// spread without a queue.
	for(int level = SKY_MAX; level >= 2; level--){
		for(int y = 0; y < H; y++){
		for(int z = 0; z < D; z++){
		for(int x = 0; x < W; x++){
			if(sky[sky_idx(x, y, z, W, D)] != level)
				continue;
			for(size_t k = 0; k < 6; k++){
				int nx = x + off[k][0], ny = y + off[k][1];
				int nz = z + off[k][2];
				if(!inside(nx, ny, nz))
					continue;
				size_t ni = sky_idx(nx, ny, nz, W, D);
				if(ids[ni] != AIR_ID || sky[ni] >= level - 1)
					continue;
				sky[ni] = level - 1;
			}
		}
		}
		}
	}
	for(int y = 0; y < H; y++){
	for(int z = 0; z < D; z++){
	for(int x = 0; x < W; x++){
		size_t i = sky_idx(x, y, z, W, D);
		if(ids[i] == AIR_ID)
			continue;
		uint8_t best = 0;
		for(size_t k = 0; k < 6; k++){
			int nx = x + off[k][0], ny = y + off[k][1];
			int nz = z + off[k][2];
			if(!inside(nx, ny, nz))
				continue;
			size_t ni = sky_idx(nx, ny, nz, W, D);
			if(ids[ni] == AIR_ID && sky[ni] > best)
				best = sky[ni];
		}
		solid_sky[i] = best;
	}
	}
	}
}

struct Worldgen: public worldgen::GeneratorInterface
{
	// The client places its benchmark cameras relative to the cave, so it is
	// told where the cave ended up rather than recomputing it from a copy of
	// these constants.
	bool cave_valid = false;
	float cave_mouth[3] = {0, 0, 0};
	float cave_dir[3] = {0, 0, 0};

	// Where the benchmark edits go. Both sit on the +X +Z side of the cave
	// mouth, which is the side both benchmark cameras look from, and the slab
	// floats above the sight line rather than across it.
	pv::Vector3DInt32 bench_shaft_centre;  // BENCH_SHAFT_W^2 x bench_shaft_h
	int bench_shaft_h = 0;
	pv::Vector3DInt32 bench_slab_centre;   // BENCH_SLAB_W x 2 x BENCH_SLAB_W

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
			const uint8_t AIR = AIR_ID;
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

			// The shaft goes straight up out of the cave to the open air; the
			// slab hangs over the mouth. Together they swap where the cave gets
			// its light from, which is the thing the relight has to get right.
			auto clamp_xz = [&](int v, int lo, int hi){
				return v < lo ? lo : (v > hi ? hi : v);
			};
			int shaft_x = clamp_xz((int)std::floor(sx + dx * BENCH_SHAFT_T +
					0.5f), lc.getX() + 2, uc.getX() - 2);
			int shaft_z = clamp_xz((int)std::floor(sz + dz * BENCH_SHAFT_T +
					0.5f), lc.getZ() + 2, uc.getZ() - 2);
			int shaft_bottom = (int)std::floor(sy + dy * BENCH_SHAFT_T + 0.5f);
			// surface_at() + 11 is the first air voxel above the ground, so
			// this breaks the surface open rather than stopping under it
			int shaft_top = (int)std::floor(
					surface_at(shaft_x, shaft_z)) + 11;
			if(shaft_top < shaft_bottom)
				shaft_top = shaft_bottom;
			bench_shaft_h = shaft_top - shaft_bottom + 1;
			bench_shaft_centre = pv::Vector3DInt32(shaft_x,
					(shaft_bottom + shaft_top) / 2, shaft_z);

			// The slab caps the shaft, filling the two air voxels directly
			// above the ground, so the second edit takes back exactly the light
			// the first one let in and the cave returns to where it started.
			bench_slab_centre = pv::Vector3DInt32(
					clamp_xz(shaft_x, lc.getX() + 3, uc.getX() - 3),
					shaft_top + 1,
					clamp_xz(shaft_z, lc.getZ() + 3, uc.getZ() - 3));

			log_v(MODULE, "Bench: shaft " PV3I_FORMAT " h %i, slab "
					PV3I_FORMAT, PV3I_PARAMS(bench_shaft_centre),
					bench_shaft_h, PV3I_PARAMS(bench_slab_centre));

			sv_<uint8_t> sky, solid_sky;
			compute_skylight(ids, W, H, D, sky, solid_sky);

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
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place_voxel"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:bench_shaft"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:bench_slab"));
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
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:bench_shaft",
				on_bench_shaft, network::Packet)
		EVENT_TYPEN("network:packet_received/main:bench_slab",
				on_bench_slab, network::Packet)
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

	// Skylight is generated for the whole scene at once, and the scene is a
	// single 64^3 section, so an edit is relit by simply doing that again over
	// all of it. Only voxels whose skylight actually changed are written back,
	// which keeps the number of chunks that have to be remeshed down to the
	// ones the light really moved in.
	void relight(voxelworld::Instance *world)
	{
		auto t0 = std::chrono::steady_clock::now();
		pv::Region region = world->get_section_region_voxels(
				pv::Vector3DInt16(0, 0, 0));
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();
		const int W = uc.getX() - lc.getX() + 1;
		const int H = uc.getY() - lc.getY() + 1;
		const int D = uc.getZ() - lc.getZ() + 1;

		sv_<uint8_t> ids((size_t)W * H * D, AIR_ID);
		for(int y = 0; y < H; y++)
		for(int z = 0; z < D; z++)
		for(int x = 0; x < W; x++){
			VoxelInstance v = world->get_voxel(pv::Vector3DInt32(
					lc.getX() + x, lc.getY() + y, lc.getZ() + z), true);
			ids[sky_idx(x, y, z, W, D)] = (uint8_t)v.get_id();
		}

		sv_<uint8_t> sky, solid_sky;
		compute_skylight(ids, W, H, D, sky, solid_sky);

		size_t changed = 0;
		for(int y = 0; y < H; y++)
		for(int z = 0; z < D; z++)
		for(int x = 0; x < W; x++){
			size_t i = sky_idx(x, y, z, W, D);
			uint8_t l = (ids[i] == AIR_ID) ? sky[i] : solid_sky[i];
			pv::Vector3DInt32 p(lc.getX() + x, lc.getY() + y, lc.getZ() + z);
			VoxelInstance v = world->get_voxel(p, true);
			if(v.get_skylight() == l)
				continue;
			v.set_skylight(l);
			world->set_voxel(p, v, true);
			changed++;
		}
		log_v(MODULE, "relight(): %zu voxels changed skylight in %i ms",
				changed, (int)std::chrono::duration_cast<
						std::chrono::milliseconds>(
						std::chrono::steady_clock::now() - t0).count());
	}

	void edit_voxel(const pv::Vector3DInt32 &p, uint32_t id)
	{
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			world->set_voxel(p, VoxelInstance(id));
			relight(world);
		});
	}

	pv::Vector3DInt32 read_voxel_p(const network::Packet &packet)
	{
		pv::Vector3DInt32 p;
		std::istringstream is(packet.data, std::ios::binary);
		cereal::PortableBinaryInputArchive ar(is);
		ar(p);
		return p;
	}

	void on_dig_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 p = read_voxel_p(packet);
		log_v(MODULE, "C%i: dig " PV3I_FORMAT, packet.sender, PV3I_PARAMS(p));
		edit_voxel(p, AIR_ID);
	}

	void on_place_voxel(const network::Packet &packet)
	{
		pv::Vector3DInt32 p = read_voxel_p(packet);
		log_v(MODULE, "C%i: place " PV3I_FORMAT, packet.sender, PV3I_PARAMS(p));
		edit_voxel(p, 2); // rock
	}

	// The two benchmark edits. Their positions come from worldgen so that they
	// stay next to the cave mouth whatever the terrain noise does.
	void bench_box(const pv::Vector3DInt32 &centre, int w, int h, int d,
			uint32_t id)
	{
		if(!m_worldgen || !m_worldgen->cave_valid){
			log_w(MODULE, "bench_box(): world is not generated yet");
			return;
		}
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int y = -(h/2); y <= (h-1)/2; y++)
			for(int z = -(d/2); z <= (d-1)/2; z++)
			for(int x = -(w/2); x <= (w-1)/2; x++){
				world->set_voxel(pv::Vector3DInt32(centre.getX() + x,
						centre.getY() + y, centre.getZ() + z),
						VoxelInstance(id), true);
			}
			relight(world);
		});
		log_v(MODULE, "bench_box(): %ix%ix%i id %i at " PV3I_FORMAT,
				w, h, d, id, PV3I_PARAMS(centre));
	}

	void on_bench_shaft(const network::Packet &packet)
	{
		(void)packet;
		if(!m_worldgen) return;
		bench_box(m_worldgen->bench_shaft_centre, BENCH_SHAFT_W,
				m_worldgen->bench_shaft_h, BENCH_SHAFT_W, AIR_ID);
	}

	void on_bench_slab(const network::Packet &packet)
	{
		(void)packet;
		if(!m_worldgen) return;
		bench_box(m_worldgen->bench_slab_centre, BENCH_SLAB_W, BENCH_SLAB_H,
				BENCH_SLAB_W, 2); // rock
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
