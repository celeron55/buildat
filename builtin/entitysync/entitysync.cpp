// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "entitysync/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
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

struct MagicEventHandler: public magic::Object
{
	OBJECT(MagicEventHandler);

	const char *MODULE = "entitysync";

	MagicEventHandler(magic::Context *context):
		magic::Object(context)
	{
		SubscribeToEvent(magic::E_UPDATE, HANDLER(MagicEventHandler, on_update));
		SubscribeToEvent(magic::E_NODEADDED, HANDLER(MagicEventHandler, on_node_added));
	}

	void on_update(magic::StringHash event_type, magic::VariantMap &event_data)
	{
	}

	void on_node_added(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		log_w(MODULE, "Node added");
	}
};

struct Module: public interface::Module, public entitysync::Interface
{
	interface::Server *m_server;
	magic::SharedPtr<MagicEventHandler> m_magic_event_handler;

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

		m_server->access_scene([&](magic::Scene *scene)
		{
			magic::Context *context = scene->GetContext();

			m_magic_event_handler = new MagicEventHandler(context);

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
		EVENT_VOIDN("core:start",           on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
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

	void on_update(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		/*m_server->access_scene([&](magic::Scene *scene)
		{
		});*/
	}

	void on_node_added(magic::StringHash event_type, magic::VariantMap &event_data)
	{
		log_w(MODULE, "Node added");
		/*m_server->access_scene([&](magic::Scene *scene)
		{
		});*/
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
