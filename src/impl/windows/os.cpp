// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include "interface/fs.h"
#include <atomic>
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

static std::atomic<int64_t> g_wall_offset_us{0};

int64_t wall_us()
{
	return time_us() + g_wall_offset_us.load();
}

void set_wall_offset_us(int64_t offset_us)
{
	g_wall_offset_us = offset_us;
}

void sleep_us(int us)
{
	usleep(us);
}

int64_t memory_bytes()
{
	PROCESS_MEMORY_COUNTERS pmc;
	if(!GetProcessMemoryInfo(GetCurrentProcess(), &pmc, sizeof pmc))
		return 0;
	return (int64_t)pmc.WorkingSetSize;
}

int64_t free_bytes(const ss_ &path)
{
	ULARGE_INTEGER avail;
	if(!GetDiskFreeSpaceExA(path.c_str(), &avail, nullptr, nullptr))
		return -1;
	return (int64_t)avail.QuadPart;
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

ss_ get_sibling_exe_path(const ss_ &name)
{
	return interface::fs::strip_file_name(get_current_exe_path())+"/"+name+".exe";
}

}
}
// vim: set noet ts=4 sw=4:
