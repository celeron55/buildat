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
#include <Scene.h>
#include <Context.h>
#define MODULE "main"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;
using interface::VoxelField;
using main_context::SceneReference;

namespace main
{

using namespace Urho3D;

// The look spike of local/aggregate_plan.md, step 2. A wall of samples with
// their fields set by hand: no simulation, no rules, nothing derived. The
// question it exists to answer is whether a mixture reads on screen -- can
// 70% rock / 30% sand be told from 30/70 at a glance -- and it is asked here,
// before the storage is rewritten to hold mixtures.
//
// It is also the first consumer of the modifier roles at all, so it is what
// says whether the tint and the sag work.

static const int VOLUME_SIZE = 64;
static const int FLOOR_TOP = 8;

static const uint8_t AIR_ID = 1;
static const uint8_t FLOOR_ID = 2;
static const uint8_t ROCK_ID = 3;
static const uint8_t SAND_ID = 4;

// The samples stand in a wall facing the camera: ten columns of a row run
// along x, the rows are stacked in y, and all of them sit at one z. A grid
// read like a chart rather than a scene, which is the point of a spike.
static const int COLUMNS = 10;
static const int ROWS = 5;
static const int SAMPLE_S = 3;
static const int SAMPLE_STEP_X = 5;
static const int SAMPLE_STEP_Y = 5;
static const int GRID_X0 = 8;
static const int GRID_Y0 = 11;
static const int GRID_Z0 = 34;

// A sample: what the fields of every voxel in one block are set to
struct Sample
{
	uint8_t id = AIR_ID;
	int tint = 0;
	int wetness = 0;
	int grain = 0;
	int gloss = 0;
	int sag_top = 0;
};

// Row 0  sag, on sand -- lowest, because it is the one whose top faces have
//        to be seen and the camera looks down on the wall
// Row 1  rock to sand, dry
// Row 2  rock to sand, soaked
// Row 3  dry to soaked, on sand
// Row 4  no binder to all binder, on sand
//
// The base look is chosen by a threshold over the rock fraction, which is
// what aggregate itself will do; everything else about the sample is a
// modifier refining that base. So the ten columns of row 0 are two textures
// and eight refinements of them, and whether that reads is the question.
static Sample sample_at(int row, int col)
{
	// 0...1 across the row
	const float f = COLUMNS > 1 ? (float)col / (float)(COLUMNS - 1) : 0.0f;
	auto q = [](float v){
		int i = (int)(v * 15.0f + 0.5f);
		return i < 0 ? 0 : (i > 15 ? 15 : i);
	};
	Sample s;
	switch(row){
	case 0:
		s.id = SAND_ID;
		s.sag_top = q(f);
		break;
	case 1:
	case 2:
		// The sand fraction runs 0...1; the base is whichever material has
		// more than half of the voxel, and the grain says how much sand is
		// in it whichever way the threshold went
		s.id = f < 0.5f ? ROCK_ID : SAND_ID;
		s.grain = q(f);
		if(row == 2){
			s.tint = 15;
			s.wetness = 15;
		}
		break;
	case 3:
		s.id = SAND_ID;
		s.tint = q(f);
		s.wetness = q(f);
		break;
	case 4:
		s.id = SAND_ID;
		s.gloss = q(f);
		break;
	}
	return s;
}

// The voxel word of a sample, under the format below
static uint32_t word_of(const interface::VoxelFormat &f, const Sample &s)
{
	uint32_t word = 0;
	f.id.set(word, s.id);
	f.light_sky.set(word, f.light_sky.mask());
	f.tint.set(word, s.tint);
	f.wetness.set(word, s.wetness);
	f.grain.set(word, s.grain);
	f.gloss.set(word, s.gloss);
	f.sag_top.set(word, s.sag_top);
	return word;
}

static interface::VoxelFormat look_format()
{
	interface::VoxelFormat f;
	f.id = VoxelField(0, 0, 4);
	f.light_sky = VoxelField(0, 4, 4);
	// Four surface modifiers, which is all there is room for, and one
	// geometry modifier, which does not count against them
	f.tint = VoxelField(0, 8, 4);
	f.wetness = VoxelField(0, 12, 4);
	f.grain = VoxelField(0, 16, 4);
	f.gloss = VoxelField(0, 20, 4);
	f.sag_top = VoxelField(0, 24, 4);
	return f;
}

struct Worldgen: public worldgen::GeneratorInterface
{
	interface::VoxelFormat m_format = look_format();

	void generate(SceneReference scene_ref,
			const pv::Vector3DInt16 &section_p,
			pv::RawVolume<VoxelInstance> &volume)
	{
		const pv::Region region = volume.getEnclosingRegion();
		auto lc = region.getLowerCorner();
		auto uc = region.getUpperCorner();

		Sample air;
		const uint32_t air_word = word_of(m_format, air);
		Sample floor;
		floor.id = FLOOR_ID;
		const uint32_t floor_word = word_of(m_format, floor);

		for(int z = lc.getZ(); z <= uc.getZ(); z++){
			for(int y = lc.getY(); y <= uc.getY(); y++){
				for(int x = lc.getX(); x <= uc.getX(); x++){
					uint32_t word = y < FLOOR_TOP ? floor_word : air_word;
					volume.setVoxelAt(pv::Vector3DInt32(x, y, z),
							VoxelInstance(word));
				}
			}
		}

		for(int row = 0; row < ROWS; row++){
			for(int col = 0; col < COLUMNS; col++){
				const uint32_t word = word_of(m_format, sample_at(row, col));
				const int x0 = GRID_X0 + col * SAMPLE_STEP_X;
				const int y0 = GRID_Y0 + row * SAMPLE_STEP_Y;
				for(int dz = 0; dz < SAMPLE_S; dz++){
					for(int dy = 0; dy < SAMPLE_S; dy++){
						for(int dx = 0; dx < SAMPLE_S; dx++){
							const pv::Vector3DInt32 p(x0 + dx, y0 + dy,
									GRID_Z0 + dz);
							if(!region.containsPoint(p))
								continue;
							volume.setVoxelAt(p, VoxelInstance(word));
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
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
	}

	// The six numbers after solid describe the surface; see interface/atlas.h
	void add_voxel(interface::VoxelRegistry *reg, const ss_ &name,
			const ss_ &texture, bool solid,
			uint32_t tint_from = 0xffffff, uint32_t tint_to = 0xffffff,
			float sag_extent = 0.0f)
	{
		interface::VoxelDefinition vdef;
		vdef.name.block_name = name;
		vdef.handler_module = "";
		for(size_t i = 0; i < 6; i++){
			interface::AtlasSegmentDefinition &seg = vdef.textures[i];
			seg.resource_name = texture;
			seg.total_segments = magic::IntVector2(texture.empty() ? 0 : 1,
					texture.empty() ? 0 : 1);
			seg.select_segment = magic::IntVector2(0, 0);
			seg.roughness = 0.9f;
			seg.spec_strength = 0.7f;
			seg.bumpiness = 0.8f;
		}
		vdef.edge_material_id = solid ? interface::EDGEMATERIALID_GROUND :
				interface::EDGEMATERIALID_EMPTY;
		vdef.physically_solid = solid;
		vdef.fully_empty = !solid;
		vdef.tint_ramp[0] = tint_from;
		vdef.tint_ramp[1] = tint_to;
		vdef.sag_extent = sag_extent;
		reg->add_voxel(vdef);
	}

	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_main_scene = imc->create_scene();
		});

		worldgen::access(m_server, [&](worldgen::Interface *iworldgen)
		{
			iworldgen->create_instance(m_main_scene);
			m_worldgen = new Worldgen();
			iworldgen->get_instance(m_main_scene)->set_generator(m_worldgen);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			pv::Region region(0, 0, 0, 0, 0, 0);
			ivoxelworld->create_instance(m_main_scene, region, false);
		});

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			voxelworld::Instance *world = ivoxelworld->
					get_instance(m_main_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			reg->set_format(look_format());
			add_voxel(reg, "air", "", false);                    // id 1
			add_voxel(reg, "floor", "main/white.png", true);     // id 2
			// The tint darkens a material as it takes water, which is the
			// one thing a light tint is honestly right for. A sag of a full
			// field takes most of a voxel, so that it can be seen at all.
			add_voxel(reg, "rock", "main/rock.png", true,
					0xffffff, 0x6a7280, 0.8f);                   // id 3
			add_voxel(reg, "sand", "main/sand.png", true,
					0xffffff, 0x8a7550, 0.8f);                   // id 4

			world->set_skylight_enabled(true);
			log_v(MODULE, "aggregate_look: %s",
					cs(reg->get_format().dump()));
		});

		worldgen::access(m_server, m_main_scene,
				[&](worldgen::Instance *instance)
		{
			instance->enable();
		});
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

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_main_scene, event.recipient);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
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
