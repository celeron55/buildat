#if defined(RCCPP_ENABLED)
#include "rccpp.h"

// Module interface
#include "interface/core.h"

#include <c55_filesys.h>

#include <vector>
#include <string>
#include <iostream>

#include <unistd.h>
#include <sys/wait.h>
#include <dlfcn.h>

// linux
#if 1
static void *library_load(const char *filename) { return dlopen(filename, RTLD_NOW); }
static void library_unload(void *module) { dlclose(module); }
static void *library_get_address(void *module, const char *name) { return dlsym(module, name); }
#elif 0
static void *library_load(const char *filename) { return LoadLibrary(filename); }
static void library_unload(void *module) { FreeLibrary(module); }
static void *library_get_address(void *module, const char *name) { return GetProcAddress(module, name); }
#endif

RCCPP_Compiler::RCCPP_Compiler()
{ 
}

bool RCCPP_Compiler::compile(const std::string &in_path, const std::string &out_path)
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

void RCCPP_Compiler::build(const std::string &in_path, const std::string &out_path)
{
	std::cout << "Building " << in_path << " -> " << out_path << "... ";

	std::string out_dir = c55fs::stripFilename(out_path);
	c55fs::CreateAllDirs(out_dir);

	if(compile(in_path, out_path)) {
		std::cout << "Success!" << std::endl;

		void *new_module = library_load(out_path.c_str());
		if(new_module == NULL){
			std::cout<<"Failed to load compiled library: "<<dlerror()<<std::endl;
		}
		
		RCCPP_GetInterface GetInterface = (RCCPP_GetInterface)library_get_address(new_module, "rccpp_GetInterface");
		if(GetInterface == nullptr) {
			std::cout << "GetInterface is missing from the library" << std::endl;
			return;
		}
		
		RCCPP_Interface *interface = GetInterface();
		assert(interface && "Interface is null");
		RCCPP_Constructor fun_constructor = interface->constructor;
		RCCPP_Destructor fun_destructor = interface->destructor;
		RCCPP_PlacementNew fun_placementnew = interface->placementnew;
		
		if(!(fun_constructor && fun_constructor && fun_placementnew)) {
			printf("Something failed with the function pointers in the module\n");
			printf("   constructor: %p (%s)\n", fun_constructor, (fun_constructor != nullptr ? "ok" : "fail"));
			printf("    destructor: %p (%s)\n", fun_destructor, (fun_destructor != nullptr ? "ok" : "fail"));
			printf(" placement new: %p (%s)\n", fun_placementnew, (fun_placementnew != nullptr ? "ok" : "fail"));
			fflush(stdout);
			return;
		}
		
		std::string classname = interface->classname;

		auto it = component_info_.find(classname);
		if(it != component_info_.end()) {
			RCCPP_Info &funcs = it->second;
			funcs.constructor = fun_constructor;
			funcs.destructor = fun_destructor;
			funcs.placement_new = fun_placementnew;
			if(funcs.module_prev) library_unload(funcs.module_prev);
			funcs.module_prev = funcs.module;
			funcs.module = new_module;
		} else {
			RCCPP_Info funcs;
			funcs.constructor = fun_constructor;
			funcs.destructor = fun_destructor;
			funcs.placement_new = fun_placementnew;
			funcs.module_prev = nullptr;
			funcs.module = new_module;
			funcs.size = interface->original_size;
			component_info_.emplace(classname, std::move(funcs));
		}
		
		changed_classes_.push_back(classname);
	} else {
		std::cout << "Failed!" << std::endl;
	}
}

void *RCCPP_Compiler::construct(const char *name) {
	auto component_info_it = component_info_.find(name);
	if(component_info_it == component_info_.end()) {
		assert(nullptr && "Failed to get class info");
		return nullptr;
	}
	
	RCCPP_Info &info = component_info_it->second;
	RCCPP_Constructor constructor = info.constructor;
	
	void *result = constructor();
	
	auto it = constructed_objects.find(std::string(name));
	
	if(it == constructed_objects.end()) constructed_objects.insert(std::make_pair(name, std::vector<void*>{result}));
	else it->second.push_back(result);
	
	return result;
}

#endif

