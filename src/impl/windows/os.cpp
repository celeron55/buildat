// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include "core/log.h"
#include <sys/time.h>
#include "ports/windows_minimal.h"
#include "ports/windows_compat.h"
#include <psapi.h>
#define MODULE "os"

namespace interface {
namespace os {

int64_t time_us()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

void sleep_us(int us)
{
	usleep(us);
}

struct HandleScope {
	HANDLE h;
	HandleScope(HANDLE h): h(h){}
	~HandleScope(){CloseHandle(h);}
};

ss_ get_current_exe_path()
{
	DWORD process_id = GetCurrentProcessId();
	HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, process_id);
	if(process == nullptr)
		throw Exception("get_current_exe_path(): process == nullptr");
	HandleScope hs(process);

	HMODULE modules[1000];
	DWORD num_module_bytes;
	if(!EnumProcessModules(process, modules, sizeof modules, &num_module_bytes))
		throw Exception("get_current_exe_path(): EnumProcessModules failed");

	for(size_t i = 0; i < num_module_bytes / sizeof(HMODULE); i++){
		TCHAR module_name[MAX_PATH];
		if(GetModuleFileNameEx(process, modules[i], module_name,
				sizeof(module_name) / sizeof(char))){
			//log_w(MODULE, "module_name=%s", module_name);
			// We want a module that ends in ".exe"
			ss_ ns(module_name);
			if(ns.substr(ns.size()-4, 4) == ".exe"){
				return ns;
			}
		}
	}
	throw Exception("get_current_exe_path(): .exe module not found");
}

}
}
// vim: set noet ts=4 sw=4:
