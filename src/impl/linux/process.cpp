#include "interface/process.h"
#include "core/log.h"
#include <unistd.h>
#include <sys/wait.h>
#define MODULE "__process"

namespace interface {
namespace process {

ss_ get_environment_variable(const ss_ &name)
{
	// TODO
	throw("get_environment_variable(): Not implemented");
}

int shell_exec(const ss_ &command, const ExecOptions &opts)
{
	log_d(MODULE, "shell_exec(\"%s\")", cs(command));
	int f = fork();
	if(f == 0){
		execl("/bin/sh", "sh", "-c", command.c_str(), (const char*)nullptr);
	}
	int exit_status;
	while(wait(&exit_status) > 0);
	return exit_status;
}

}
}
