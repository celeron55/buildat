#include "interface/module.h"
#include "interface/server.h"

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server)
	{
	}

	~Module()
	{
	}

	void start()
	{
		m_server->load_module("foo", "bar");
	}

	int test_add(int a, int b)
	{
		return a + b;
	}
};

extern "C" {
EXPORT void* createModule(interface::Server *server)
{
	return (void*)(new Module(server));
}
}
