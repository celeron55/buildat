#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mutex.h"
#include "test1/include/api.h"
#include "network/include/api.h"
#include "core/log.h"

using interface::Event;

namespace test1 {

struct Module: public interface::Module
{
	interface::Mutex m_interface_mutex;
	interface::Server *m_server;

	Event::Type m_EventType_test1_thing;

	Module(interface::Server *server):
		interface::Module("test1"),
		m_server(server),
		m_EventType_test1_thing(Event::t("test1:thing"))
	{
		log_v(MODULE, "test1 construct");
	}

	~Module()
	{
		log_v(MODULE, "test1 destruct");
	}

	void init()
	{
		interface::MutexScope ms(m_interface_mutex);

		log_v(MODULE, "test1 init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, m_EventType_test1_thing);
		m_server->sub_event(this, Event::t("network:new_client"));
		m_server->sub_event(this, Event::t("network:packet_received"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		interface::MutexScope ms(m_interface_mutex);

		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPE(m_EventType_test1_thing, on_thing, Thing)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
		EVENT_TYPEN("network:packet_received", on_packet_received, network::Packet)
	}

	void on_start()
	{
	}

	void on_thing(const Thing &thing)
	{
		log_i(MODULE, "test1.thing: some_data=%s", cs(thing.some_data));
	}

	void on_new_client(const network::NewClient &new_client)
	{
		log_i(MODULE, "test1::on_new_client: id=%zu", new_client.info.id);

		network::Interface *inetwork = network::get_interface(m_server);
		inetwork->send(new_client.info.id, "test1:dummy", "dummy data");
	}

	void on_packet_received(const network::Packet &packet)
	{
		log_i(MODULE, "test1::on_packet_received: type=%zu, size=%zu",
				packet.type, packet.data.size());
	}
};

extern "C" {
	EXPORT void* createModule_test1(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
