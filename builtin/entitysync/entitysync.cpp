// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "entitysync/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/magic_event.h"
#include <Object.h>
#include <Context.h>
#include <Engine.h>
#include <Variant.h>
#include <Scene.h>
#include <ResourceCache.h>
#include <CoreEvents.h>
#include <SceneEvents.h>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>

using interface::Event;
namespace magic = Urho3D;

namespace entitysync {

struct Module: public interface::Module, public entitysync::Interface
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("entitysync"),
		m_server(server)
	{
		log_v(MODULE, "entitysync construct");
	}

	~Module()
	{
		log_v(MODULE, "entitysync destruct");
	}

	void init()
	{
		log_v(MODULE, "entitysync init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));

		m_server->sub_magic_event(this, magic::E_NODEADDED,
				Event::t("entitysync:node_added"));
		m_server->sub_magic_event(this, magic::E_NODEREMOVED,
				Event::t("entitysync:node_removed"));
		m_server->sub_magic_event(this, magic::E_COMPONENTADDED,
				Event::t("entitysync:component_added"));
		m_server->sub_magic_event(this, magic::E_COMPONENTREMOVED,
				Event::t("entitysync:component_removed"));

		m_server->access_scene([&](magic::Scene *scene)
		{
			magic::Context *context = scene->GetContext();

			/*magic::ResourceCache* cache =
					m_context->GetSubsystem<magic::ResourceCache>();

			Node* plane_node = m_scene->CreateChild("Plane");
			plane_node->SetScale(Vector3(100.0f, 1.0f, 100.0f));
			StaticModel* plane_object = plane_node->CreateComponent<StaticModel>();
			plane_object->SetModel(cache->GetResource<Model>("Models/Plane.mdl"));
			plane_object->SetMaterial(cache->GetResource<Material>("Materials/StoneTiled.xml"));*/
		});
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",            on_start)
		EVENT_VOIDN("core:unload",           on_unload)
		EVENT_VOIDN("core:continue",         on_continue)
		EVENT_TYPEN("entitysync:node_added",
				on_node_added, interface::MagicEvent)
		EVENT_TYPEN("entitysync:node_removed",
				on_node_removed, interface::MagicEvent)
		EVENT_TYPEN("entitysync:component_added",
				on_component_added, interface::MagicEvent)
		EVENT_TYPEN("entitysync:component_removed",
				on_component_removed, interface::MagicEvent)
	}

	void on_start()
	{
	}

	void on_unload()
	{
	}

	void on_continue()
	{
	}

	void on_node_added(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_w(MODULE, "Node added: %i", event_data["NodeID"].GetInt());
	}

	void on_node_removed(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_w(MODULE, "Node removed: %i", event_data["NodeID"].GetInt());
	}

	void on_component_added(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_w(MODULE, "Component added: %i", event_data["ComponentID"].GetInt());
	}

	void on_component_removed(const interface::MagicEvent &event)
	{
		magic::VariantMap event_data = event.magic_data;
		log_w(MODULE, "Component removed: %i", event_data["ComponentID"].GetInt());
	}

	// Interface

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	EXPORT void* createModule_entitysync(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
