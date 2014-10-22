#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mesh.h"
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

namespace geometry {

using interface::Event;
using namespace Urho3D;

struct Module: public interface::Module
{
	interface::Server *m_server;
	uint m_slow_count = 0;

	Module(interface::Server *server):
		interface::Module("geometry"),
		m_server(server)
	{}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
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
			}
			{
				Node *n = scene->CreateChild("Base");
			}
			{
				Node *n = scene->CreateChild("Testbox");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));

	            /*int w = 1, h = 1, d = 1;
	            ss_ data = "1";*/
				int w = 2, h = 2, d = 1;
				ss_ data = "0111";

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("simple_voxel_data"), Variant(
							data.c_str()));
				n->SetVar(StringHash("simple_voxel_w"), Variant(w));
				n->SetVar(StringHash("simple_voxel_h"), Variant(h));
				n->SetVar(StringHash("simple_voxel_d"), Variant(d));

				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::mesh::
						create_simple_voxel_model(context, w, h, d, data.c_str()));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				body->SetMass(1.0);
				CollisionShape *shape = n->CreateComponent<CollisionShape>(
							LOCAL);
				shape->SetConvexHull(model, 0, Vector3::ONE);
				//shape->SetTriangleMesh(model, 0, Vector3::ONE);
				//shape->SetBox(Vector3::ONE);
			}
		});

		update_scene();
	}

	void on_continue()
	{
		update_scene();
	}

	void update_scene()
	{
		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();
			ResourceCache *cache = context->GetSubsystem<ResourceCache>();

			{
				Node *n = scene->GetChild("Base");
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				//n->SetPosition(Vector3(0.0f, 0.5f, 0.0f));
				n->SetPosition(Vector3(0.0f, 0.5f, 0.0f));
				//n->SetRotation(Quaternion(0, 90, 0));

				int w = 10, h = 3, d = 10;
				ss_ data =
					"111111111100100000100000000000"
					"111111111100000000000000000000"
					"111111111100000000000000000000"
					"111111111100000000000000000000"
					"111111111100011000000001000000"
					"111111111100011000000001000000"
					"111111111100000000000000000000"
					"111111111100000000000000000000"
					"111111111100000000000000000000"
					"111111111100000000000000000000"
					;

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("simple_voxel_data"), Variant(
							data.c_str()));
				n->SetVar(StringHash("simple_voxel_w"), Variant(w));
				n->SetVar(StringHash("simple_voxel_h"), Variant(h));
				n->SetVar(StringHash("simple_voxel_d"), Variant(d));

				// Load the same model in here and give it to the physics
				// subsystem so that it can be collided to
				SharedPtr<Model> model(interface::mesh::
						create_simple_voxel_model(context, w, h, d, data.c_str()));

				RigidBody *body = n->CreateComponent<RigidBody>(LOCAL);
				body->SetFriction(0.75f);
				CollisionShape *shape = n->CreateComponent<CollisionShape>(
							LOCAL);
				shape->SetTriangleMesh(model, 0, Vector3::ONE);
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		static uint a = 0;
		if(((a++) % 100) == 0){
			float rx = (float)rand() / RAND_MAX * 180;
			float ry = (float)rand() / RAND_MAX * 180;
			float rz = (float)rand() / RAND_MAX * 180;
			m_server->access_scene([&](Scene *scene){
				Node *n = scene->GetChild("Testbox");
				n->SetRotation(Quaternion(rx, ry, rz));
				n->SetPosition(Vector3(-0.5f, 8.0f, 0.0f));
			});
			return;
		}
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
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
