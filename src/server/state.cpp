#include "state.h"
#include "rccpp.h"
#include "config.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include <iostream>

extern server::Config g_server_config;

namespace server {

struct CState: public State, public interface::Server
{
	up_<rccpp::Compiler> m_compiler;
	ss_ m_modules_path;
	sm_<ss_, interface::Module*> m_modules;

	CState():
		m_compiler(rccpp::createCompiler())
	{
		m_compiler->include_directories.push_back(
				g_server_config.interface_path);
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/..");
		m_compiler->include_directories.push_back(
				g_server_config.interface_path+"/../../3rdparty/cereal/include");
	}

	void load_module(const ss_ &module_name, const ss_ &path)
	{
		std::cerr<<"Loading module "<<module_name<<" from "<<path<<std::endl;
		ss_ build_dst = g_server_config.rccpp_build_path +
				"/" + module_name + ".so";
		m_compiler->include_directories.push_back(m_modules_path);
		m_compiler->build(module_name, path+"/server/init.cpp", build_dst);
		m_compiler->include_directories.pop_back();

		interface::Module *m = static_cast<interface::Module*>(
				m_compiler->construct(module_name.c_str(), this));
		m_modules[module_name] = m;

		m->event(interface::Event("core:load_modules"));

		m->event(interface::Event("core:start"));
	}

	void load_modules(const ss_ &path)
	{
		m_modules_path = path;
		ss_ first_module_path = path+"/__loader";
		load_module("__loader", first_module_path);
	}

	ss_ get_modules_path()
	{
		return m_modules_path;
	}

	interface::Module* get_module(const ss_ &module_name)
	{
		auto it = m_modules.find(module_name);
		if(it == m_modules.end())
			return NULL;
		return it->second;
	}
};

State* createState()
{
	return new CState();
}
}
