#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "interface/module.h"
#include "interface/server.h"
#include <c55_filesys.h>
#include <iostream>

extern server::Config g_server_config;

namespace server {

struct CState: public State, public interface::Server
{
	up_<rccpp::Compiler> m_compiler;

	CState():
		m_compiler(rccpp::createCompiler())
	{
		m_compiler->include_directories.push_back(
				g_server_config.interface_path);
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/..");
	}

	// State

	void load_module(const ss_ &module_name, const ss_ &path)
	{
		std::cerr<<"Loading module "<<module_name<<" from "<<path<<std::endl;
		ss_ build_dst = g_server_config.rccpp_build_path + "/module.so";
		m_compiler->build(module_name, path+"/server/main.cpp", build_dst);

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(module_name.c_str(), this));
		//int a = m->test_add(1, 2);
		//std::cout<<"a = "<<a<<std::endl;
		m->start();
	}

	void load_modules(const ss_ &path)
	{
		ss_ first_module_path = path+"/__loader";
		load_module("__loader", first_module_path);
		/*ss_ first_module_path2 = path+"/test1";
		load_module("test1", first_module_path2);*/
	}

	// interface::Server


};

State* createState()
{
	return new CState();
}
}
