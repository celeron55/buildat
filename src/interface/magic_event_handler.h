// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/server.h"
#include "interface/magic_event.h"
#include <Object.h>

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

		void emit_event(magic::StringHash event_type, magic::VariantMap &event_data)
		{
			m_server->emit_event(m_buildat_event_type, new interface::MagicEvent(
					event_type, event_data));
		}

		void on_event(magic::StringHash event_type, magic::VariantMap &event_data);
	};
}
// vim: set noet ts=4 sw=4:
