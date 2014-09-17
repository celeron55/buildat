#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/include/api.h"
#include "network/include/api.h"
#include <iostream>

using interface::Event;

namespace test1 {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_test1_thing;

	Module(interface::Server *server):
		m_server(server),
		m_EventType_test1_thing(Event::t("test1:thing"))
	{
		std::cout<<"test1 construct"<<std::endl;
	}

	void init()
	{
		std::cout<<"test1 init"<<std::endl;
		m_server->sub_event(this, m_EventType_test1_thing);
		m_server->sub_event(this, Event::t("network:new_client"));
	}

	~Module()
	{
		std::cout<<"test1 destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_TYPE(m_EventType_test1_thing, on_thing, Thing)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
	}

	void on_thing(const Thing &thing)
	{
		std::cout<<"test1.thing: some_data="<<thing.some_data<<std::endl;
	}

	void on_new_client(const network::NewClient &new_client)
	{
		std::cout<<"test1::on_new_client: id="<<new_client.info.id<<std::endl;

		m_server->emit_event("network:send",
				new network::Packet(new_client.info.id, 1337, "dummy data"));
	}
};

extern "C" {
	EXPORT void* createModule_test1(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
