#include "interface/module.h"
#include "interface/server.h"
#include <iostream>

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server)
	{
		std::cout<<"__loader construct"<<std::endl;
	}

	~Module()
	{
		std::cout<<"__loader destruct"<<std::endl;
	}

	void start()
	{
		m_server->load_module("test1", m_server->get_modules_path()+"/test1");
	}

	int test_add(int a, int b)
	{
		return a + b;
	}
};

extern "C" {
EXPORT void* createModule___loader(interface::Server *server)
{
	return (void*)(new Module(server));
}
}
