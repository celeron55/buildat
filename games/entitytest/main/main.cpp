#include "core/log.h"
#include "client_file/api.h"
#include "network/api.h"
#include "entitysync/api.h"
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
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/unordered_map.hpp>
#include <cereal/types/vector.hpp>

namespace entitytest {

using interface::Event;
using namespace Urho3D;

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("entitytest"),
		m_server(server)
	{
		log_v(MODULE, "entitytest construct");
	}

	~Module()
	{
		log_v(MODULE, "entitytest destruct");
	}

	void init()
	{
		log_v(MODULE, "entitytest init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:new_client"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",         on_start)
		EVENT_TYPEN("core:tick",          on_tick,     interface::TickEvent)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
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
			}
			{
				Node *n = scene->CreateChild("Box");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetScale(Vector3(1.0f, 1.0f, 1.0f));
				RigidBody *body = n->CreateComponent<RigidBody>();
				CollisionShape *shape = n->CreateComponent<CollisionShape>();
				shape->SetBox(Vector3::ONE);
				body->SetMass(1.0);
                body->SetFriction(0.75f);
				//body->SetUseGravity(true);
				//body->SetGravityOverride(Vector3(0.0, -1.0, 0.0));
				StaticModel *object = n->CreateComponent<StaticModel>();
				object->SetModel(cache->GetResource<Model>("Models/Box.mdl"));
				object->SetMaterial(
						cache->GetResource<Material>("Materials/Stone.xml"));
			}
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		log_d(MODULE, "entitytest::on_tick");
		static uint a = 0;
		if(((a++) % 25) == 0){
			m_server->access_scene([&](Scene *scene){
				Node *n = scene->GetChild("Box");
				n->SetPosition(Vector3(0.0f, 6.0f, 0.0f));
				n->SetRotation(Quaternion(30, 60, 90));
			});
			return;
		}
		m_server->access_scene([&](Scene *scene){
			Node *n = scene->GetChild("Box");
			//n->Translate(Vector3(0.1f, 0, 0));
			Vector3 p = n->GetPosition();
			log_v(MODULE, "Position: %s", p.ToString().CString());
		});
	}

	void on_new_client(const network::NewClient &new_client)
	{
		log_i(MODULE, "entitytest::on_new_client: id=%zu", new_client.info.id);

		/*network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(new_client.info.id, "core:run_script",
					"require(\"buildat/extension/entitysync\")");
		});*/
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		log_i(MODULE, "entitytest::on_client_disconnected: id=%zu", old_client.info.id);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);

		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(event.recipient, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
	}
};

extern "C" {
	EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
