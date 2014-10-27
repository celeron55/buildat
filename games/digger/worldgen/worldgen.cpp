#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/noise.h"
#include "interface/voxel_volume.h"
#include <Scene.h>
#include <RigidBody.h>
#include <CollisionShape.h>
#include <ResourceCache.h>
#include <Context.h>
#include <StaticModel.h>
#include <Model.h>
#include <Material.h>
#include <Texture2D.h>
#include <Technique.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>
#define MODULE "worldgen"

namespace magic = Urho3D;
namespace pv = PolyVox;

using interface::Event;
using interface::VoxelInstance;

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

namespace worldgen {

using namespace Urho3D;

struct Module: public interface::Module
{
	interface::Server *m_server;

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
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("voxelworld:generation_request"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("voxelworld:generation_request",
				on_generation_request, voxelworld::GenerationRequest)
	}

	void on_start()
	{
		// Define voxels on core:start (woxelworld will restore them on reload)
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			interface::VoxelRegistry *voxel_reg = ivoxelworld->get_voxel_reg();
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
				voxel_reg->add_voxel(vdef); // id 1
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
				voxel_reg->add_voxel(vdef); // id 2
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
				voxel_reg->add_voxel(vdef); // id 3
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
				voxel_reg->add_voxel(vdef); // id 4
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "leaves";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/leaves.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				voxel_reg->add_voxel(vdef); // id 5
			}
			{
				interface::VoxelDefinition vdef;
				vdef.name.block_name = "tree";
				vdef.name.segment_x = 0;
				vdef.name.segment_y = 0;
				vdef.name.segment_z = 0;
				vdef.name.rotation_primary = 0;
				vdef.name.rotation_secondary = 0;
				vdef.handler_module = "";
				for(size_t i = 0; i < 6; i++){
					interface::AtlasSegmentDefinition &seg = vdef.textures[i];
					seg.resource_name = "main/tree.png";
					seg.total_segments = magic::IntVector2(1, 1);
					seg.select_segment = magic::IntVector2(0, 0);
				}
				vdef.textures[0].resource_name = "main/tree_top.png";
				vdef.textures[1].resource_name = "main/tree_top.png";
				vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
				vdef.physically_solid = true;
				voxel_reg->add_voxel(vdef); // id 6
			}
		});
	}

	void on_continue()
	{
	}

	void update_scene()
	{
	}

	void on_generation_request(const voxelworld::GenerationRequest &event)
	{
		log_v(MODULE, "on_generation_request(): section_p: (%i, %i, %i)",
				event.section_p.getX(), event.section_p.getY(),
				event.section_p.getZ());
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			const pv::Vector3DInt16 &section_p = event.section_p;
			pv::Region region = ivoxelworld->get_section_region_voxels(
						section_p);

			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();

			log_t(MODULE, "on_generation_request(): lc: (%i, %i, %i)",
					lc.getX(), lc.getY(), lc.getZ());
			log_t(MODULE, "on_generation_request(): uc: (%i, %i, %i)",
					uc.getX(), uc.getY(), uc.getZ());

			interface::v3f spread(160, 160, 160);
			interface::NoiseParams np(0, 40, spread, 0, 7, 0.55);

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
							ivoxelworld->set_voxel(p, VoxelInstance(1));
							continue;
						}
						if(y >= 2 && y <= 3 && z >= 256 && z <= 258 &&
								x >= -112 && x <= -5){
							ivoxelworld->set_voxel(p, VoxelInstance(1));
							continue;
						}
						if(z > 37 && z < 50 && y > 20){
							ivoxelworld->set_voxel(p, VoxelInstance(1));
							continue;
						}
						if(x > 27 && x < 40 && y > 20){
							ivoxelworld->set_voxel(p, VoxelInstance(1));
							continue;
						}
						if(x > 18 && x < 25 && z >= 32 && z <= 37 &&
								y > 20 && y < 25){
							ivoxelworld->set_voxel(p, VoxelInstance(1));
							continue;
						}
						if(y < a+5){
							ivoxelworld->set_voxel(p, VoxelInstance(2));
						} else if(y < a+10){
							ivoxelworld->set_voxel(p, VoxelInstance(3));
						} else if(y < a+11){
							ivoxelworld->set_voxel(p, VoxelInstance(4));
						} else {
							ivoxelworld->set_voxel(p, VoxelInstance(1));
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
	                VoxelInstance v = ivoxelworld->get_voxel(p);
	                if(v.get_id() != 1)
	                    break;
	            }
	            y++;*/
				size_t noise_i = (z-lc.getZ())*d + (x-lc.getX());
				double a = noise.result[noise_i];
				int y = a + 11.0;
				if(y < lc.getY() - 5 || y > uc.getY() - 5)
					continue;

				for(int y1 = y; y1<y+4; y1++){
					pv::Vector3DInt32 p(x, y1, z);
					ivoxelworld->set_voxel(p, VoxelInstance(6), true);
				}

				for(int x1 = x-2; x1 <= x+2; x1++){
					for(int y1 = y+3; y1 <= y+7; y1++){
						for(int z1 = z-2; z1 <= z+2; z1++){
							pv::Vector3DInt32 p(x1, y1, z1);
							ivoxelworld->set_voxel(p, VoxelInstance(5), true);
						}
					}
				}
			}
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_worldgen(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
