// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/server.h"
#include "interface/magic_event.h"
#include <Object.h>
#include <SceneEvents.h>
#include <Node.h>
#include <Component.h>

namespace interface
{
	using interface::Event;
	namespace magic = Urho3D;

	// This can be used for subscribing to Urho3D events as Buildat events
	struct MagicEventHandler: public magic::Object
	{
		OBJECT(MagicEventHandler);
		static constexpr const char *MODULE = "MagicEventHandler";

		interface::Server *m_server;
		interface::Event::Type m_buildat_event_type;

		MagicEventHandler(magic::Context *context,
				interface::Server *server,
				const magic::StringHash &event_type,
				const interface::Event::Type &buildat_event_type):
			magic::Object(context),
			m_server(server),
			m_buildat_event_type(buildat_event_type)
		{
			SubscribeToEvent(event_type, HANDLER(MagicEventHandler, on_event));
		}

		void on_event(magic::StringHash event_type, magic::VariantMap &event_data)
		{
			auto *evreg = interface::getGlobalEventRegistry();
			if(log_get_max_level() >= CORE_DEBUG){
				log_d(MODULE, "MagicEventHandler::on_event(): %s (%zu)",
						cs(evreg->name(m_buildat_event_type)), m_buildat_event_type);
			}
			// Convert pointers to IDs because the event will be queued for later
			// handling and pointers may become invalid
			if(event_type == magic::E_NODEADDED ||
					event_type == magic::E_NODEREMOVED){
				magic::Node *parent = static_cast<magic::Node*>(
						event_data["Parent"].GetVoidPtr());
				event_data["ParentID"] = parent->GetID();
				event_data.Erase("Parent");
				magic::Node *node = static_cast<magic::Node*>(
						event_data["Node"].GetVoidPtr());
				event_data["NodeID"] = node->GetID();
				event_data.Erase("Node");
			}
			if(event_type == magic::E_COMPONENTADDED ||
					event_type == magic::E_COMPONENTREMOVED){
				magic::Node *node = static_cast<magic::Node*>(
						event_data["Node"].GetVoidPtr());
				event_data["NodeID"] = node->GetID();
				event_data.Erase("Node");
				magic::Component *c = static_cast<magic::Component*>(
						event_data["Component"].GetVoidPtr());
				event_data["ComponentID"] = c->GetID();
				event_data.Erase("Component");
			}
			m_server->emit_event(m_buildat_event_type, new interface::MagicEvent(
					event_type, event_data));
		}
	};
}
// vim: set noet ts=4 sw=4:
