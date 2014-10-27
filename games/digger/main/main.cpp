#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "worldgen/api.h"
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
#define MODULE "main"

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

namespace main {

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
		m_server->sub_event(this, Event::t("worldgen:voxels_defined"));
		m_server->sub_event(this, Event::t("core:tick"));
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
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_VOIDN("worldgen:voxels_defined", on_voxels_defined)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted",
				on_files_transmitted, client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:place_voxel",
				on_place_voxel, network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_voxel",
				on_dig_voxel, network::Packet)
		EVENT_TYPEN("worldgen:queue_modified",
				on_worldgen_queue_modified, worldgen::QueueModifiedEvent);
	}

	void on_start()
	{
	}

	void on_continue()
	{
	}

	void on_voxels_defined()
	{
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			main_context::access(m_server, [&](main_context::Interface *imc)
			{
				Scene *scene = imc->get_scene();
				Context *context = imc->get_context();
				ResourceCache *cache = context->GetSubsystem<ResourceCache>();

				interface::VoxelRegistry *voxel_reg =
					ivoxelworld->get_voxel_reg();

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
				SharedPtr<Model> model(interface::mesh::
						create_8bit_voxel_physics_model(context, w, h, d, data,
						voxel_reg));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				body->SetMass(1.0);
				CollisionShape *shape =
					n->CreateComponent<CollisionShape>(LOCAL);
				shape->SetConvexHull(model, 0, Vector3::ONE);
				//shape->SetTriangleMesh(model, 0, Vector3::ONE);
				//shape->SetBox(Vector3::ONE);
			});
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		/*main_context::access(m_server, [&](main_context::Interface *imc)
		{
		    Scene *scene = imc->get_scene();
		    Node *n = scene->GetChild("Testbox");
		    auto p = n->GetPosition();
		    log_v(MODULE, "Testbox: (%f, %f, %f)", p.x_, p.y_, p.z_);
		});*/
		static uint a = 0;
		if(((a++) % 150) == 0){
			main_context::access(m_server, [&](main_context::Interface *imc)
			{
				Scene *scene = imc->get_scene();
				Node *n = scene->GetChild("Testbox");
				if(n){
					n->SetRotation(Quaternion(30, 60, 90));
					n->SetPosition(Vector3(30.0f, 30.0f, 40.0f));
				}
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

		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld)
		{
			ivoxelworld->set_voxel(voxel_p, VoxelInstance(1));
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
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
