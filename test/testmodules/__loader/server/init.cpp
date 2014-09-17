#include "interface/module.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "interface/event.h"
#include <iostream>

using interface::Event;

namespace __loader {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("__loader"),
		m_server(server)
	{
		std::cout<<"__loader construct"<<std::endl;
	}

	void init()
	{
		std::cout<<"__loader init"<<std::endl;
		m_server->sub_event(this, Event::t("core:load_modules"));
	}

	~Module()
	{
		std::cout<<"__loader destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		if(type == Event::t("core:load_modules")){
			on_load_modules();
		}
	}

	void on_load_modules()
	{
		m_server->load_module("network",
				m_server->get_builtin_modules_path()+"/network");

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
