#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "network/api.h"
#include "client_file/api.h"
#define MODULE "main"

using interface::Event;

namespace main {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		log_v(MODULE, "main construct");
	}

	~Module()
	{
		log_v(MODULE, "main destruct");
	}

	void init()
	{
		log_v(MODULE, "main init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
	}

	void on_start()
	{
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "main::on_client_connected: id=%zu", client_connected.info.id);
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		log_v(MODULE, "on_files_transmitted(): recipient=%zu", event.recipient);

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
