#include "interface/process.h"
#include "core/log.h"
#include <unistd.h>
#include <sys/wait.h>
#define MODULE "__process"

namespace interface {
namespace process {

int shell_exec(const ss_ &command)
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
