#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "test1/include/api.h"
#include <iostream>
#include <assert.h>

using interface::Event;

namespace test2 {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_core_start;

	Module(interface::Server *server):
		m_server(server),
		m_EventType_core_start(interface::getGlobalEventRegistry()->type("core:start"))
	{
		std::cout<<"test2 construct"<<std::endl;
	}

	~Module()
	{
		std::cout<<"test2 destruct"<<std::endl;
	}

	void event(const interface::Event &event)
	{
		if(event.type == m_EventType_core_start){
			start();
		}
	}

	void start()
	{
		interface::Module *m = m_server->get_module("test1");
		assert(m);
		interface::Event event("test1:thing");
		event.p.reset(new test1::Thing("Nakki"));
		m->event(event);
	}
};

extern "C" {
	EXPORT void* createModule_test2(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
