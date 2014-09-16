#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "internal_interface.h"
#include <iostream>

extern server::Config g_server_config;

namespace server {

struct CState: public State
{
	RCCPP_Compiler m_compiler;

	CState()
	{
		m_compiler.include_directories.push_back(
				g_server_config.interface_path);
		m_compiler.include_directories.push_back(
				g_server_config.interface_path+"/..");
	}

	void load_module(const ss_ &path)
	{
		ss_ build_dst = g_server_config.rccpp_build_path + "/foo.o";
		m_compiler.build(path+"/server/main.cpp", build_dst);

		Module *m = static_cast<Module*>(m_compiler.construct("Test1Module"));
		int a = m->test_add(1, 2);
		std::cout<<"a = "<<a<<std::endl;
	}
};

State* createState()
{
	return new CState();
}
}
