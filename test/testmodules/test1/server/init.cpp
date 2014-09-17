#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mutex.h"
#include "test1/include/api.h"
#include "network/include/api.h"
#include <iostream>
//#include <dlfcn.h>

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
		std::cout<<"test1 construct"<<std::endl;
	}

	void init()
	{
		interface::MutexScope ms(m_interface_mutex);

		std::cout<<"test1 init"<<std::endl;
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, m_EventType_test1_thing);
		m_server->sub_event(this, Event::t("network:new_client"));
	}

	~Module()
	{
		std::cout<<"test1 destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		interface::MutexScope ms(m_interface_mutex);

		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPE(m_EventType_test1_thing, on_thing, Thing)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
	}

	void on_start()
	{
	}

	void on_thing(const Thing &thing)
	{
		std::cout<<"test1.thing: some_data="<<thing.some_data<<std::endl;
	}

	void on_new_client(const network::NewClient &new_client)
	{
		std::cout<<"test1::on_new_client: id="<<new_client.info.id<<std::endl;

		network::Interface *inetwork = network::get_interface(m_server);
		inetwork->send(new_client.info.id, "test1:dummy", "dummy data");
	}
};

extern "C" {
	EXPORT void* createModule_test1(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
