#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/include/api.h"
#include <iostream>

using interface::Event;

namespace test1 {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_test1_thing;

	Module(interface::Server *server):
		m_server(server),
		m_EventType_test1_thing(interface::getGlobalEventRegistry()->type("test1:thing"))
	{
		std::cout<<"test1 construct"<<std::endl;
	}

	~Module()
	{
		std::cout<<"test1 destruct"<<std::endl;
	}

	void event(const interface::Event &event)
	{
		if(event.type == m_EventType_test1_thing){
			thing(static_cast<Thing*>(event.p.get()));
		}
	}

	void thing(const Thing *thing)
	{
		std::cout<<"test1.thing: some_data="<<thing->some_data<<std::endl;
	}
};

extern "C" {
	EXPORT void* createModule_test1(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
