#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/mutex.h"
#include "test1/include/api.h"
#include "core/log.h"

using interface::Event;

namespace test2 {

struct Module: public interface::Module
{
	interface::Mutex m_interface_mutex;
	interface::Server *m_server;
	Event::Type m_EventType_core_start;

	Module(interface::Server *server):
		interface::Module("test2"),
		m_server(server),
		m_EventType_core_start(Event::t("core:start"))
	{
		log_v(MODULE, "test2 construct");
	}

	void init()
	{
		interface::MutexScope ms(m_interface_mutex);

		log_v(MODULE, "test2 init");
		m_server->sub_event(this, m_EventType_core_start);
	}

	~Module()
	{
		log_v(MODULE, "test2 destruct");
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		interface::MutexScope ms(m_interface_mutex);

		if(type == m_EventType_core_start){
			on_start();
		}
	}

	void on_start()
	{
		log_i(MODULE, "test2 start(): Calling test1");

		{	// Raw
			Event::Type type = Event::t("test1:thing");
			Event event(type, up_<Event::Private>(new test1::Thing("Nakki")));
			m_server->emit_event(std::move(event));
		}

		{	// Simplified raw
			Event event("test1:thing", new test1::Thing("Kebab"));
			m_server->emit_event(std::move(event));
		}

		{	// Even simpler
			m_server->emit_event("test1:thing", new test1::Thing("Pitsa"));
		}

		{	// Inline wrapper
			test1::do_thing(m_server, "Rulla");
		}
	}
};

extern "C" {
	EXPORT void* createModule_test2(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
