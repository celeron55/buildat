#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/include/api.h"
#include <iostream>

using interface::Event;

namespace test2 {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_core_start;

	Module(interface::Server *server):
		m_server(server),
		m_EventType_core_start(Event::t("core:start"))
	{
		std::cout<<"test2 construct"<<std::endl;
	}

	void init()
	{
		std::cout<<"test2 init"<<std::endl;
		m_server->sub_event(this, m_EventType_core_start);
	}

	~Module()
	{
		std::cout<<"test2 destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		if(type == m_EventType_core_start){
			on_start();
		}
	}

	void on_start()
	{
		std::cout<<"test2 start(): Calling test1"<<std::endl;

		// Basic way
		Event event("test1:thing");
		event.p.reset(new test1::Thing("Nakki"));
		m_server->emit_event(event);

		// Simplified by inline wrapper
		test1::do_thing(m_server, "Kebab");
	}
};

extern "C" {
	EXPORT void* createModule_test2(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
