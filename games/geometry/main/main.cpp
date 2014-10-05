#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
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
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",         on_start)
		EVENT_TYPEN("core:tick",          on_tick,   interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
		m_server->access_scene([&](Scene *scene)
		{
			Context *context = scene->GetContext();
			ResourceCache* cache = context->GetSubsystem<ResourceCache>();

			{
				Node* node = scene->CreateChild("DirectionalLight");
				node->SetDirection(Vector3(-0.6f, -1.0f, 0.8f));
				Light* light = node->CreateComponent<Light>();
				light->SetLightType(LIGHT_DIRECTIONAL);
				light->SetCastShadows(true);
			}
			{
				Node *n = scene->CreateChild("Plane");
				n->SetPosition(Vector3(0.0f, -0.5f, 0.0f));
				n->SetScale(Vector3(10.0f, 1.0f, 10.0f));
				RigidBody *body = n->CreateComponent<RigidBody>();
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetBox(Vector3::ONE);
				body->SetFriction(0.75f);
				StaticModel *object = n->CreateComponent<StaticModel>();
				object->SetModel(cache->GetResource<Model>("Models/Box.mdl"));
				object->SetMaterial(
						cache->GetResource<Material>("Materials/Stone.xml"));
				object->SetCastShadows(true);
			}
			{
				Node *n = scene->CreateChild("Box");
				n->SetPosition(Vector3(0.0f, 1.5f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));

				//RigidBody *body = n->CreateComponent<RigidBody>();
				//CollisionShape *shape = n->CreateComponent<CollisionShape>();
				//shape->SetBox(Vector3::ONE);
				//body->SetMass(1.0);
				//body->SetFriction(0.75f);

				// Crude way of dynamically defining a voxel model
				n->SetVar(StringHash("simple_voxel_data"), Variant("11101111"));
				n->SetVar(StringHash("simple_voxel_w"), Variant(2));
				n->SetVar(StringHash("simple_voxel_h"), Variant(2));
				n->SetVar(StringHash("simple_voxel_d"), Variant(2));

				// TODO: Load the same model in here and give it to the physics
				//       subsystem so that it can be collided to
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		network::access(m_server, [&](network::Interface * inetwork){
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
