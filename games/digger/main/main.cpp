#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
#include "interface/voxel.h"
#include "interface/noise.h"
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

namespace digger {

using namespace Urho3D;

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("digger"),
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
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("voxelworld:generation_request"));
		m_server->sub_event(this, Event::t(
					"network:packet_received/main:place_voxel"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("voxelworld:generation_request",
				on_generation_request, voxelworld::GenerationRequest)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
	}

	void on_start()
	{
		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();

			{
				Node *node = scene->CreateChild("DirectionalLight");
				node->SetDirection(Vector3(-0.6f, -1.0f, 0.8f));
				Light *light = node->CreateComponent<Light>();
				light->SetLightType(LIGHT_DIRECTIONAL);
				light->SetCastShadows(true);
				light->SetBrightness(0.8);
				light->SetColor(Color(1.0, 1.0, 0.95));
			}
			{
				Node *node = scene->CreateChild("DirectionalLight");
				node->SetDirection(Vector3(0.3f, -1.0f, -0.4f));
				Light *light = node->CreateComponent<Light>();
				light->SetLightType(LIGHT_DIRECTIONAL);
				light->SetCastShadows(true);
				light->SetBrightness(0.2);
				light->SetColor(Color(0.7, 0.7, 1.0));
			}

			voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
			{
				interface::VoxelRegistry *voxel_reg = ivoxelworld->get_voxel_reg();

				Node *n = scene->CreateChild("Testbox");
				n->SetPosition(Vector3(30.0f, 30.0f, 40.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));

				/*int w = 1, h = 1, d = 1;
				ss_ data = "1";*/
				int w = 2, h = 2, d = 1;
				ss_ data = "1333";

				// Convert data to the actually usable voxel type id namespace
				// starting from VOXELTYPEID_UNDEFINED=0
				for(size_t i = 0; i < data.size(); i++){
					data[i] = data[i] - '0';
				}

				n->SetVar(StringHash("simple_voxel_data"), Variant(
						PODVector<uint8_t>((const uint8_t*)data.c_str(),
								data.size())));
				n->SetVar(StringHash("simple_voxel_w"), Variant(w));
				n->SetVar(StringHash("simple_voxel_h"), Variant(h));
				n->SetVar(StringHash("simple_voxel_d"), Variant(d));


				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::
						create_8bit_voxel_physics_model(context, w, h, d, data,
						voxel_reg));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				body->SetMass(1.0);
				CollisionShape *shape = n->CreateComponent<CollisionShape>(LOCAL);
				shape->SetConvexHull(model, 0, Vector3::ONE);
				//shape->SetTriangleMesh(model, 0, Vector3::ONE);
				//shape->SetBox(Vector3::ONE);
			});
		});
	}

	void on_continue()
	{
	}

	void update_scene()
	{
	}

	void on_tick(const interface::TickEvent &event)
	{
		/*m_server->access_scene([&](Scene *scene){
			Node *n = scene->GetChild("Testbox");
			auto p = n->GetPosition();
			log_v(MODULE, "Testbox: (%f, %f, %f)", p.x_, p.y_, p.z_);
		});*/
		static uint a = 0;
		if(((a++) % 100) == 0){
			m_server->access_scene([&](Scene *scene){
				Node *n = scene->GetChild("Testbox");
				n->SetRotation(Quaternion(30, 60, 90));
				n->SetPosition(Vector3(30.0f, 30.0f, 40.0f));
			});
		}
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}

	void on_generation_request(const voxelworld::GenerationRequest &event)
	{
		log_v(MODULE, "on_generation_request(): section_p: (%i, %i, %i)",
				event.section_p.getX(), event.section_p.getY(),
				event.section_p.getZ());
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			const pv::Vector3DInt16 &section_p = event.section_p;
			pv::Region region = ivoxelworld->get_section_region_voxels(section_p);

			pv::Vector3DInt32 p0 = region.getLowerCorner();
			pv::Vector3DInt32 p1 = region.getUpperCorner();

			log_t(MODULE, "on_generation_request(): p0: (%i, %i, %i)",
					p0.getX(), p0.getY(), p0.getZ());
			log_t(MODULE, "on_generation_request(): p1: (%i, %i, %i)",
					p1.getX(), p1.getY(), p1.getZ());

			interface::NoiseParams np(0, 35, interface::v3f(160,160,160),
					1, 6, 0.475);

			auto lc = region.getLowerCorner();
			auto uc = region.getUpperCorner();
			for(int z = lc.getZ(); z <= uc.getZ(); z++){
				for(int y = lc.getY(); y <= uc.getY(); y++){
					for(int x = lc.getX(); x <= uc.getX(); x++){
						pv::Vector3DInt32 p(x, y, z);
						pv::Vector3DInt32 cp(-112, 20, 253);
						if((p - cp).lengthSquared() < 30*30){
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
						double a = interface::NoisePerlin2D(&np, x, z, 0);
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
			auto extent = uc - lc + pv::Vector3DInt32(1,1,1);
			int area = extent.getX() * extent.getZ();
			auto pr = interface::PseudoRandom(13241);
			for(int i = 0; i < area / 100; i++){
				int x = pr.range(lc.getX(), uc.getX());
				int z = pr.range(lc.getZ(), uc.getZ());

				/*int y = 50;
				for(; y>-50; y--){
					pv::Vector3DInt32 p(x, y, z);
					VoxelInstance v = ivoxelworld->get_voxel(p);
					if(v.getId() != 1)
						break;
				}
				y++;*/
				double a = interface::NoisePerlin2D(&np, x, z, 0);
				int y = a + 11.0;
				if(y < lc.getY() - 5 || y > uc.getY() - 5)
					continue;

				for(int y1=y; y1<y+4; y1++){
					pv::Vector3DInt32 p(x, y1, z);
					ivoxelworld->set_voxel(p, VoxelInstance(3), true);
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

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			ivoxelworld->set_voxel(voxel_p, VoxelInstance(2));
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
