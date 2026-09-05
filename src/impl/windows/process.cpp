#include "interface/process.h"
#include "core/log.h"
#include "ports/windows_minimal.h"
#define MODULE "__process"

namespace interface {
namespace process {

static ss_ format_last_error()
{
	DWORD last_error = GetLastError();
	if(!last_error)
		return "No error";
	TCHAR buf[1000];
	FormatMessage(FORMAT_MESSAGE_FROM_SYSTEM, NULL, last_error,
			MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), buf, 1000-1, NULL);
	return buf;
};

ss_ get_environment_variable(const ss_ &name)
{
	char buf[10000];
	DWORD len = GetEnvironmentVariable(name.c_str(), buf, sizeof buf);
	return ss_(buf, len);
}

int shell_exec(const ss_ &command, const ExecOptions &opts)
{
	log_d(MODULE, "shell_exec(\"%s\")", cs(command));

	// http://stackoverflow.com/questions/334879/how-do-i-get-the-application-exit-code-from-a-windows-command-line/3119934#3119934

	STARTUPINFO si;
	PROCESS_INFORMATION pi;
	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);
	memset(&pi, 0, sizeof(pi));

	char command_c[50000];
	snprintf(command_c, 50000, cs(command));

	// The environment block is a null-terminated buffer of null-terminated strings
	sv_<char> env_block;
	for(auto &pair : opts.env){
		const ss_ &name = pair.first;
		const ss_ &value = pair.second;
		env_block.insert(env_block.end(), name.c_str(), name.c_str() + name.size());
		env_block.push_back('=');
		env_block.insert(env_block.end(), value.c_str(), value.c_str() + value.size());
		env_block.push_back(0);
	}
	env_block.push_back(0);

	if(!CreateProcess(
			NULL, // Module name
			command_c, // Command line (non-const)
			NULL, // Process handle not inheritable
			NULL, // Thread handle not inheritable
			false, // Set handle inheritance to FALSE
			0, // No creation flags
			env_block.data(), // Use a new environment block
			//NULL, // Use parent's environment block
			NULL, // Use parent's starting directory
			&si, // Pointer to STARTUPINFO structure
			&pi // Pointer to PROCESS_INFORMATION structure
	)){
		log_w(MODULE, "Trying to run \"%s\": CreateProcess failed: %s",
				cs(command), cs(format_last_error()));
		return 1;
	}

	WaitForSingleObject(pi.hProcess, INFINITE);
	int exit_code = -1;
	if(!GetExitCodeProcess(pi.hProcess, (LPDWORD)&exit_code)){
		log_w(MODULE, "Trying to run \"%s\": GetExitCodeProcess failed: %s",
				cs(command), cs(format_last_error()));
		return 1;
	}
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);
	return exit_code;
}

bool Handle::valid() const
{
	return impl != 0;
}

Handle start(const ss_ &path, const sv_<ss_> &args)
{
	Handle h;
	ss_ cmd = "\"" + path + "\"";
	for(const ss_ &a : args)
		cmd += " \"" + a + "\"";

	STARTUPINFO si;
	PROCESS_INFORMATION pi;
	memset(&si, 0, sizeof(si));
	si.cb = sizeof(si);
	memset(&pi, 0, sizeof(pi));

	char command_c[50000];
	snprintf(command_c, 50000, "%s", cs(cmd));

	if(!CreateProcess(
			path.c_str(),
			command_c,
			NULL, NULL, false, 0,
			NULL, NULL, &si, &pi)){
		log_w(MODULE, "start(\"%s\"): CreateProcess failed: %s",
				cs(path), cs(format_last_error()));
		return h;
	}
	CloseHandle(pi.hThread);
	h.impl = (intptr_t)pi.hProcess;
	log_i(MODULE, "Started process: %s", cs(path));
	return h;
}

void terminate(Handle &h)
{
	if(!h.valid())
		return;
	HANDLE process = (HANDLE)h.impl;
	TerminateProcess(process, 1);
	WaitForSingleObject(process, 5000);
	if(WaitForSingleObject(process, 0) != WAIT_OBJECT_0)
		TerminateProcess(process, 1);
	WaitForSingleObject(process, INFINITE);
	CloseHandle(process);
	h.impl = 0;
}

bool is_running(const Handle &h)
{
	if(!h.valid())
		return false;
	DWORD code = 0;
	if(!GetExitCodeProcess((HANDLE)h.impl, &code))
		return false;
	return code == STILL_ACTIVE;
}

}
}
