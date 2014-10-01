// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "rccpp.h"
#include "core/log.h"
#include "interface/server.h"
#include "interface/process.h"
#include <c55/filesys.h>
#include <vector>
#include <string>
#include <iostream>
#include <dlfcn.h>
#include <cstddef>
#include <vector>
#include <cassert>
#include <memory>
#include <string>
#include <unordered_map>
#include <algorithm>
#define MODULE "__rccpp"

namespace rccpp {

// linux
#if 1
static void *library_load(const char *filename){
	return dlopen(filename, RTLD_NOW);
}
static void library_unload(void *module){
	dlclose(module);
}
static void *library_get_address(void *module, const char *name){
	return dlsym(module, name);
}
#elif 0
static void *library_load(const char *filename){
	return LoadLibrary(filename);
}
static void library_unload(void *module){
	FreeLibrary(module);
}
static void *library_get_address(void *module, const char *name){
	return GetProcAddress(module, name);
}
#endif

typedef void *(*RCCPP_Constructor)(interface::Server *server);

struct RCCPP_Info {
	void *module;
	RCCPP_Constructor constructor;
};

struct CCompiler: public Compiler
{
	ss_ m_compiler_command;
	std::unordered_map<std::string, RCCPP_Info> m_module_info;

	CCompiler(const ss_ &compiler_command):
		m_compiler_command(compiler_command)
	{
	}

	bool compile(const std::string &in_path, const std::string &out_path,
			const ss_ &extra_cxxflags, const ss_ &extra_ldflags)
	{
		ss_ command = m_compiler_command;
		command += " -DRCCPP -g -fPIC -fvisibility=hidden -shared";
		command += " -std=c++11";
		if(extra_cxxflags != "")
			command += ss_()+" "+extra_cxxflags;
		if(extra_ldflags != "")
			command += ss_()+" "+extra_ldflags;

		for(const std::string &dir : include_directories) command += " -I"+dir;
		for(const std::string &dir : library_directories) command += " -L"+dir;

		command += " -o"+out_path;
		command += " "+in_path;

		for(const std::string &lib : libraries) command += " "+lib;

		int exit_status = interface::process::shell_exec(command);

		return exit_status == 0;
	}

	bool build(const std::string &module_name,
			const std::string &in_path, const std::string &out_path,
			const ss_ &extra_cxxflags, const ss_ &extra_ldflags)
	{
		log_nd(MODULE, "Building %s: %s -> %s... ", cs(module_name), cs(in_path),
				cs(out_path));

		std::string out_dir = c55fs::stripFilename(out_path);
		c55fs::CreateAllDirs(out_dir);

		if(!compile(in_path, out_path, extra_cxxflags, extra_ldflags)){
			log_d(MODULE, "Failed!");
			return false;
		}
		log_d(MODULE, "Success!");

		void *new_module = library_load(out_path.c_str());
		if(new_module == NULL){
			log_i(MODULE, "Failed to load compiled library: %s", dlerror());
			return false;
		}

		ss_ constructor_name = ss_()+"createModule_"+module_name;
		RCCPP_Constructor constructor = (RCCPP_Constructor)library_get_address(
				new_module, constructor_name.c_str());
		if(constructor == nullptr){
			log_i(MODULE, "%s is missing from the library", cs(constructor_name));
			return false;
		}

		auto it = m_module_info.find(module_name);
		if(it != m_module_info.end()){
			RCCPP_Info &funcs = it->second;
			funcs.constructor = constructor;
			funcs.module = new_module;
		} else {
			RCCPP_Info funcs;
			funcs.constructor = constructor;
			funcs.module = new_module;
			m_module_info.emplace(module_name, std::move(funcs));
		}
		return true;
	}

	void* construct(const char *name, interface::Server *server)
	{
		auto it = m_module_info.find(name);
		if(it == m_module_info.end()){
			log_w(MODULE, "construct(%s): Module is not loaded", name);
			return NULL;
		}

		RCCPP_Info &info = it->second;
		RCCPP_Constructor constructor = info.constructor;

		return constructor(server);
	}

	void unload(const std::string &module_name)
	{
		auto it = m_module_info.find(module_name);
		if(it == m_module_info.end()){
			assert(nullptr && "Failed to get class info");
			return;
		}
		void *module = it->second.module;
		library_unload(module);
		m_module_info.erase(module_name);
	}
};

Compiler* createCompiler(const ss_ &compiler_command)
{
	return new CCompiler(compiler_command);
}

} // rccpp
// vim: set noet ts=4 sw=4:
