#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "main_context/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "storage/api.h"
#include "worldgen/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include "interface/voxel_volume.h"
#include <Scene.h>
#include <sstream>
#include <cstdio>
#define MODULE "main"

using interface::Event;
namespace magic = Urho3D;
namespace pv = PolyVox;
using main_context::SceneReference;
using interface::VoxelVolume;

namespace launch_world {

// **The room, on the 45 cm grid**, authored here and nowhere else. One
// unit of the client's scene is one voxel; see client_lua/init.lua, which
// is written in metres and multiplies on the way in.
//
// The shell only: the floor the checkerboard is made of, and the mass the
// room is cut out of. The bays, their slabs and everything in front of
// them are still primitives in the client's scene -- see [LAUNCH_WORLD]
// step 6, which this is half of.
struct Room
{
	// In voxels, inclusive. The floor is the layers under y = 0, so that
	// the client's own metre-zero is the floor's top.
	static const int FLOOR_TOP = -1;
	static const int FLOOR_BOTTOM = -3;
	static const int X_MIN = -46, X_MAX = 46;
	static const int Z_MIN = -30, Z_MAX = 44;
	static const int Y_TOP = 26;
	static const int WALL = 4;

	// **The wall, as the reference actually has it.** Not a balcony per
	// orb on a flat plane: slabs protruding at random amounts, orbs in
	// generous pockets cut into the mass, and rectangles inset to
	// various depths until some read black. Its nominal surface is
	// BAY_Z; everything else is measured from there.
	static const int BAY_Z = -18;
	static const int SLAB_OUT = 4;        // the furthest a slab comes out
	static const int INSET_IN = 4;        // the deepest an inset goes
	static const int BAYS = 6;
	static const int BAY_SPACING = 14;
	static const int SLAB_H = 3;
	static const int TIERS = 6;
	// A pocket is about twice the orb across in every direction: the orb
	// is 1.7 units, which is under four voxels, so eight is twice it
	static const int POCKET = 8;
	static const int POCKET_DEPTH = 8;

	static int bay_x(int b) { return (b - (BAYS - 1) / 2) * BAY_SPACING - 7; }
	static int bay_tier(int b)
	{
		static const int t[BAYS] = {2, 4, 1, 3, 5, 2};
		return t[b];
	}
	// The middle of a pocket, which is where its orb hangs
	static int bay_y(int b) { return bay_tier(b) * SLAB_H + SLAB_H / 2 + 4; }

	// A hash with no state, so the wall is the same every boot and the
	// server and the client agree without either being told
	static uint32_t hash2(int a, int b, uint32_t salt)
	{
		uint32_t h = (uint32_t)(a * 73856093) ^ (uint32_t)(b * 19349663) ^
				(salt * 83492791);
		h ^= h >> 13;
		h *= 0x5bd1e995u;
		h ^= h >> 15;
		return h;
	}

	// **How far the wall's face stands at (x, y).** Two grids of
	// different periods are taken together so the slabs do not fall on a
	// rhythm, and a third cuts rectangles back into whatever is left --
	// which is where the wall's interest comes from, rather than from
	// putting different things on it.
	static int face_z(int x, int y)
	{
		int out = 0;
		// Slabs: cells of 9 and 13 voxels, most of them flush, a quarter
		// standing out by one to three. Two periods so the standing ones
		// do not fall on a rhythm; tuned down from "every cell, by up to
		// four" which read as rubble rather than as a wall (2026-09-23).
		const uint32_t a = hash2(floor_div(x, 9), floor_div(y, 9), 1);
		const uint32_t b = hash2(floor_div(x + 4, 13), floor_div(y + 6, 13), 2);
		if((a & 7) < 2)
			out = 1 + (int)((a >> 4) % 3);
		if((b & 7) < 2){
			const int bo = 1 + (int)((b >> 4) % 2);
			if(bo > out)
				out = bo;
		}
		// Insets: rectangles cut back, rare and deep, some of them deep
		// enough to read black once the overhead light is the only thing
		// reaching them
		const uint32_t c = hash2(floor_div(x + 2, 6), floor_div(y + 1, 6), 3);
		if((c & 15) < 2)
			out -= 1 + (int)((c >> 4) % INSET_IN);
		return BAY_Z + out;
	}

	static int floor_div(int a, int b)
	{
		return a >= 0 ? a / b : -(((-a) + b - 1) / b);
	}

	// Whether (x, y, z) is inside a pocket, and whether it is one of the
	// side columns that carry the ornament
	static bool in_pocket(int x, int y, int z, bool *column)
	{
		for(int b = 0; b < BAYS; b++){
			const int cx = bay_x(b), cy = bay_y(b);
			if(x < cx - POCKET / 2 || x > cx + POCKET / 2)
				continue;
			if(y < cy - POCKET / 2 || y > cy + POCKET / 2)
				continue;
			const int mouth = face_z(x, y);
			if(z > mouth || z < mouth - POCKET_DEPTH)
				continue;
			// The two voxels down each side of the mouth are the columns
			if(column != nullptr)
				*column = (x <= cx - POCKET / 2 + 1 ||
						x >= cx + POCKET / 2 - 1);
			return true;
		}
		return false;
	}
};

struct VoxelIds
{
	interface::VoxelInstance air = interface::VoxelInstance(0);
	interface::VoxelInstance stone = interface::VoxelInstance(0);
	interface::VoxelInstance dark = interface::VoxelInstance(0);
	interface::VoxelInstance floor_light = interface::VoxelInstance(0);
	interface::VoxelInstance floor_dark = interface::VoxelInstance(0);
	interface::VoxelInstance column = interface::VoxelInstance(0);
};
static VoxelIds g_ids;

// What is at a voxel, before anything is dissolved. The generator and the
// dissolve's own restore both read this, so there is one description of
// the room and not two.
static interface::VoxelInstance voxel_at(int x, int y, int z)
{
	const bool outside =
			x < Room::X_MIN || x > Room::X_MAX ||
			z < Room::Z_MIN || z > Room::Z_MAX;
	if(y <= Room::FLOOR_TOP && y >= Room::FLOOR_BOTTOM && !outside){
		// Two voxels a square: at 45 cm one voxel a square is a fine
		// check that reads as noise down the room
		return ((((x >> 1) + (z >> 1)) & 1) == 0) ?
				g_ids.floor_light : g_ids.floor_dark;
	}
	if(y < Room::FLOOR_BOTTOM)
		return g_ids.dark;
	if(outside && y <= Room::Y_TOP + Room::WALL)
		return g_ids.stone;
	// **The wall**: one mass whose face stands wherever face_z() says,
	// with pockets cut into it. The same material lines a pocket -- it
	// is a hole in the wall and not a differently finished box -- and
	// the ornament is on the side columns of its mouth and nowhere else.
	if(y >= 0 && y <= Room::Y_TOP && z <= Room::face_z(x, y)){
		bool column = false;
		if(Room::in_pocket(x, y, z, &column))
			return g_ids.air;
		// A voxel beside a pocket's mouth is one of its columns
		bool c2 = false;
		if(Room::in_pocket(x - 1, y, z, &c2) && c2)
			return g_ids.column;
		if(Room::in_pocket(x + 1, y, z, &c2) && c2)
			return g_ids.column;
		return g_ids.stone;
	}
	return g_ids.air;
}

struct RoomGen: public worldgen::GeneratorInterface
{
	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			VoxelVolume &volume)
	{
		const pv::Region region = volume.getEnclosingRegion();
		const auto lc = region.getLowerCorner();
		const auto uc = region.getUpperCorner();
		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int x = lc.getX(); x <= uc.getX(); x++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					volume.setVoxelAt(x, y, z, voxel_at(x, y, z));
				}
			}
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	SceneReference m_main_scene;
	storage::Save *m_save = nullptr;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this,
				Event::t("network:packet_received/main:dissolve"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:dissolve", on_dissolve,
				network::Packet)
	}

	interface::VoxelInstance add_voxel(interface::VoxelRegistry *reg,
			const ss_ &name, const ss_ &texture, bool solid,
			bool fully_empty, float roughness = 0.9f,
			float spec_strength = 0.3f, float bumpiness = 0.5f,
			uint8_t uv_scale = 1)
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
			seg.roughness = roughness;
			seg.spec_strength = spec_strength;
			seg.bumpiness = bumpiness;
			seg.translucency = 0.0f;
			seg.spots = 0.0f;
			seg.static_spots = 0.0f;
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = fully_empty;
		// How many voxels this voxel's texture spans before it repeats
		// ([WORLD_UV]); 1 is one stamp a voxel, as it always was
		vdef.uv_scale = uv_scale;
		return reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		// Worldgen before voxelworld, or the first sections' generation
		// requests are lost
		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);
			iworldgen->get_instance(m_main_scene)->set_generator(new RoomGen());
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			// The room and the mass around it, in sections
			pv::Region region(-3, -1, -3, 3, 2, 3);
			ivoxelworld->create_instance(m_main_scene, region);
		});

		// **No persistence**: the room is the same every boot, which is
		// on the leave-out list beside the mapgen. The world is generated
		// from the table above every time and nothing is written.
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world =
					ivoxelworld->get_instance(m_main_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			g_ids.air = add_voxel(reg, "air", "", false, true);
			// **The wall's own material**, generated by the client and
			// registered under this name ([LAUNCH_WORLD]'s rule that the
			// generator is the source and the picture is an artefact),
			// spanning eight voxels before it repeats so that it reads as
			// one knobby surface rather than as a grid of stamps
			g_ids.stone = add_voxel(reg, "stone", "generated/wall.png",
					true, false, 0.85f, 0.10f, 0.7f, 8);
			g_ids.dark = add_voxel(reg, "dark", "main/dark.png",
					true, false, 0.95f, 0.1f, 0.4f);
			// The pockets' side columns, which are the one place the
			// ornament goes; also generated by the client
			g_ids.column = add_voxel(reg, "column", "generated/column.png",
					true, false, 0.70f, 0.20f, 0.9f, 4);
			// The checkerboard: the light squares are polished, which is
			// what puts the room's reflection in the floor
			g_ids.floor_light = add_voxel(reg, "floor_light",
					"main/floor_light.png", true, false, 0.18f, 1.0f, 0.2f);
			g_ids.floor_dark = add_voxel(reg, "floor_dark",
					"main/floor_dark.png", true, false, 0.22f, 1.0f, 0.2f);
			world->set_skylight_enabled(true);
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});

		// Said out loud so a run can compare it with the client's own copy
		// of the same numbers ([LAUNCH_WORLD] step 6: the room is carved
		// here and the orbs are placed there)
		log_i(MODULE, "launch_world: bays %s", cs(bays_string()));
		log_i(MODULE, "launch_world: the room is %ix%ix%i voxels of 45 cm",
				Room::X_MAX - Room::X_MIN, Room::Y_TOP,
				Room::Z_MAX - Room::Z_MIN);
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
	}

	// The room is described in one place ([LAUNCH_WORLD] step 6): the
	// client is told where the bays are rather than keeping a second copy
	// of the numbers to drift from this one.
	ss_ bays_string()
	{
		std::ostringstream os;
		os << Room::BAYS << " " << Room::SLAB_H << " " << Room::BAY_Z << " "
				<< Room::POCKET << " " << Room::POCKET_DEPTH;
		for(int b = 0; b < Room::BAYS; b++){
			os << " " << Room::bay_x(b) << " " << Room::bay_tier(b)
					<< " " << Room::bay_y(b);
		}
		return os.str();
	}

	// **The dissolve, as voxel removal**: "<bay> <0|1>". The client flies
	// its own copies of the slabs; what happens here is that the voxels
	// stop being there, and come back from voxel_at() rather than from
	// anything remembered -- the room being generated and never saved,
	// the description is the only state there is.
	void on_dissolve(const network::Packet &packet)
	{
		int bay = 0, open = 0;
		if(sscanf(packet.data.c_str(), "%i %i", &bay, &open) != 2)
			return;
		if(bay < 0 || bay >= Room::BAYS)
			return;
		// The pocket's own box, which is what comes apart: the mouth
		// stands wherever the slabs around it put it, so the sweep goes
		// from the deepest a face can be to the furthest it can stand
		const int bx = Room::bay_x(bay);
		const int by = Room::bay_y(bay);
		voxelworld::access(m_server, m_main_scene,
				[&](voxelworld::Instance *world)
		{
			for(int x = bx - Room::POCKET; x <= bx + Room::POCKET; x++){
				for(int y = by - Room::POCKET; y <= by + Room::POCKET; y++){
					for(int z = Room::BAY_Z - Room::POCKET_DEPTH -
							Room::INSET_IN;
							z <= Room::BAY_Z + Room::SLAB_OUT; z++){
						const pv::Vector3DInt32 p(x, y, z);
						world->set_voxel(p, open ? g_ids.air :
								voxel_at(x, y, z), true);
					}
				}
			}
		});
		log_i(MODULE, "launch_world: bay %i %s", bay,
				open ? "dissolved" : "rebuilt");
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		// The client joins the scene the voxelworld is in, which is what
		// makes voxelworld initialise it and start sending sections --
		// without this the world generates on the server and the client
		// draws an empty room (2026-09-23)
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "main:bays", bays_string());
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new launch_world::Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
