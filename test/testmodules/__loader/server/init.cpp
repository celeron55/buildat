#include "interface/module.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "interface/event.h"
//#include <cereal/archives/binary.hpp>
#include <iostream>

using interface::Event;

namespace __loader {

struct Module: public interface::Module
{
	interface::Server *m_server;
	Event::Type m_EventType_core_load_modules;

	Module(interface::Server *server):
		m_server(server),
		m_EventType_core_load_modules(interface::getGlobalEventRegistry()->type("core:load_modules"))
	{
		std::cout<<"__loader construct"<<std::endl;
	}

	~Module()
	{
		std::cout<<"__loader destruct"<<std::endl;
	}

	void event(const interface::Event &event)
	{
		if(event.type == m_EventType_core_load_modules){
			load_modules();
		}
	}

	int test_add(int a, int b)
	{
		return a + b;
	}

	void load_modules()
	{
		sv_<ss_> load_list = {"test1", "test2"};
		for(const ss_ &name : load_list){
			m_server->load_module(name, m_server->get_modules_path()+"/"+name);
		}
		/*// TODO: Dependencies
		auto list = interface::getGlobalFilesystem()->list_directory(m_server->get_modules_path());
		for(const interface::Filesystem::Node &n : list){
			if(n.name == "__loader")
				continue;
			m_server->load_module(n.name, m_server->get_modules_path()+"/"+n.name);
		}*/
	}
};

extern "C" {
	EXPORT void* createModule___loader(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
