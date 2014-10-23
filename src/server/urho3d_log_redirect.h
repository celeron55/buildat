// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/magic_event.h"
#include <Log.h>
#include <IOEvents.h>

namespace urho3d_log_redirect
{
	using interface::Event;
	namespace magic = Urho3D;

	struct Module: public interface::Module
	{
		interface::Server *m_server;

		Module(interface::Server *server):
			interface::Module("urho3d_log_redirect"),
			m_server(server)
		{
		}

		~Module()
		{
		}

		void init()
		{
			m_server->sub_magic_event(this, magic::E_LOGMESSAGE, 
					Event::t("urho3d_log_redirect:message"));
		}

		void event(const Event::Type &type, const Event::Private *p)
		{
			EVENT_TYPEN("urho3d_log_redirect:message", on_message,
					interface::MagicEvent)
		}

		void on_message(const interface::MagicEvent &event)
		{
			int magic_level = event.magic_data.Find("Level")->second_.GetInt();
			ss_ message = event.magic_data.Find("Message")->second_.GetString().CString();
			int core_level = LOG_ERROR;
			if(magic_level == magic::LOG_DEBUG)
				core_level = LOG_DEBUG;
			else if(magic_level == magic::LOG_INFO)
				core_level = LOG_VERBOSE;
			else if(magic_level == magic::LOG_WARNING)
				core_level = LOG_WARNING;
			else if(magic_level == magic::LOG_ERROR)
				core_level = LOG_ERROR;
			log_(core_level, MODULE, "Urho3D %s", cs(message));
		}
	};
} // urho3d_log_redirect
