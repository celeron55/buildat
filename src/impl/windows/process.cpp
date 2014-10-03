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

int shell_exec(const ss_ &command)
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

	if(!CreateProcess(
			NULL, // Module name
			command_c, // Command line (non-const)
			NULL, // Process handle not inheritable
			NULL, // Thread handle not inheritable
			false, // Set handle inheritance to FALSE
			0, // No creation flags
			NULL, // Use parent's environment block
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

}
}
