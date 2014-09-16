#include "rccpp.h"
#include "interface/server.h"

#include <c55_filesys.h>

#include <vector>
#include <string>
#include <iostream>

#include <unistd.h>
#include <sys/wait.h>
#include <dlfcn.h>

#include <cstddef>

#include <vector>
#include <cassert>
#include <memory>
#include <string>
#include <unordered_map>
#include <algorithm>

namespace rccpp {

typedef void *(*RCCPP_Constructor)(interface::Server *server);

struct RCCPP_Info {
	void *module;
	RCCPP_Constructor constructor;
};

struct CCompiler: public Compiler
{
	CCompiler();

	bool build(const std::string &module_name,
			const std::string &in_path, const std::string &out_path);
	
	void* construct(const char *name, interface::Server *server);

private:
	std::unordered_map<std::string, RCCPP_Info> component_info_;
	std::unordered_map<std::string, std::vector<void*>> constructed_objects;

	bool compile(const std::string &in_path, const std::string &out_path);
};

// linux
#if 1
static void *library_load(const char *filename) { return dlopen(filename, RTLD_NOW); }
//static void library_unload(void *module) { dlclose(module); }
static void *library_get_address(void *module, const char *name) { return dlsym(module, name); }
#elif 0
static void *library_load(const char *filename) { return LoadLibrary(filename); }
static void library_unload(void *module) { FreeLibrary(module); }
static void *library_get_address(void *module, const char *name) { return GetProcAddress(module, name); }
#endif

CCompiler::CCompiler()
{ 
}

bool CCompiler::compile(const std::string &in_path, const std::string &out_path)
{
	//std::string command = "g++ -g -O0 -fPIC -fvisibility=hidden -shared";
	std::string command = "g++ -DRCCPP -g -fPIC -fvisibility=hidden -shared";
	
	command += " -std=c++11";
	
	for(const std::string &dir : include_directories) command += " -I" + dir;
	for(const std::string &dir : library_directories) command += " -L" + dir;
	
	command += " -o" + out_path;
	command += " " + in_path;
	
	//std::cout << ">>> " <<  command << std::endl;
	
	// Fork for compilation.
	int f = fork();
	if(f == 0) {
		execl("/bin/sh", "sh", "-c", command.c_str(), (const char*)nullptr);
	}
	
	// Wait for the forked process to exit.
	int exit_status;
	while(wait(&exit_status) > 0);
	
	return exit_status == 0;
}

bool CCompiler::build(const std::string &module_name,
		const std::string &in_path, const std::string &out_path)
{
	std::cout << "Building " << module_name << ": "
			<< in_path << " -> " << out_path << "... ";

	std::string out_dir = c55fs::stripFilename(out_path);
	c55fs::CreateAllDirs(out_dir);

	if(!compile(in_path, out_path)) {
		std::cout << "Failed!" << std::endl;
		return false;
	}
	std::cout << "Success!" << std::endl;

	void *new_module = library_load(out_path.c_str());
	if(new_module == NULL){
		std::cout<<"Failed to load compiled library: "<<dlerror()<<std::endl;
		return false;
	}

	ss_ constructor_name = ss_()+"createModule_"+module_name;
	RCCPP_Constructor constructor = (RCCPP_Constructor)library_get_address(
			new_module, constructor_name.c_str());
	if(constructor == nullptr) {
		std::cout<<constructor_name<<" is missing from the library"<<std::endl;
		return false;
	}
	
	auto it = component_info_.find(module_name);
	if(it != component_info_.end()) {
		RCCPP_Info &funcs = it->second;
		funcs.constructor = constructor;
		funcs.module = new_module;
	} else {
		RCCPP_Info funcs;
		funcs.constructor = constructor;
		funcs.module = new_module;
		component_info_.emplace(module_name, std::move(funcs));
	}
	return true;
}

void *CCompiler::construct(const char *name, interface::Server *server) {
	auto component_info_it = component_info_.find(name);
	if(component_info_it == component_info_.end()) {
		assert(nullptr && "Failed to get class info");
		return nullptr;
	}
	
	RCCPP_Info &info = component_info_it->second;
	RCCPP_Constructor constructor = info.constructor;
	
	void *result = constructor(server);
	
	auto it = constructed_objects.find(std::string(name));
	
	if(it == constructed_objects.end()) constructed_objects.insert(std::make_pair(name, std::vector<void*>{result}));
	else it->second.push_back(result);
	
	return result;
}

Compiler* createCompiler()
{
	return new CCompiler();
}

} // rccpp
