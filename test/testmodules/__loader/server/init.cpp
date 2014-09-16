#include "interface/module.h"
#include "interface/server.h"
#include "interface/fs.h"
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
		auto list = interface::getGlobalFilesystem()->list_directory(m_server->get_modules_path());
		for(const interface::Filesystem::Node &n : list){
			if(n.name == "__loader")
				continue;
			m_server->load_module(n.name, m_server->get_modules_path()+"/"+n.name);
		}
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
