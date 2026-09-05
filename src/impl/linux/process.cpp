#include "interface/process.h"
#include "core/log.h"
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <cstring>
#include <vector>
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

bool Handle::valid() const
{
	return impl > 0;
}

Handle start(const ss_ &path, const sv_<ss_> &args)
{
	Handle h;
	pid_t pid = fork();
	if(pid < 0){
		log_w(MODULE, "fork failed: %s", strerror(errno));
		return h;
	}
	if(pid == 0){
		std::vector<char*> argv;
		argv.push_back(const_cast<char*>(path.c_str()));
		for(const ss_ &a : args)
			argv.push_back(const_cast<char*>(a.c_str()));
		argv.push_back(nullptr);
		execv(path.c_str(), argv.data());
		log_w(MODULE, "execv(\"%s\") failed: %s", cs(path), strerror(errno));
		_exit(127);
	}
	h.impl = pid;
	log_i(MODULE, "Started pid %i: %s", (int)pid, cs(path));
	return h;
}

void terminate(Handle &h)
{
	if(!h.valid())
		return;
	pid_t pid = (pid_t)h.impl;
	kill(pid, SIGTERM);
	for(int i = 0; i < 100; i++){
		int status = 0;
		pid_t r = waitpid(pid, &status, WNOHANG);
		if(r == pid || (r < 0 && errno == ECHILD)){
			h.impl = 0;
			return;
		}
		usleep(50000);
	}
	kill(pid, SIGKILL);
	waitpid(pid, nullptr, 0);
	h.impl = 0;
}

bool is_running(const Handle &h)
{
	if(!h.valid())
		return false;
	pid_t pid = (pid_t)h.impl;
	if(kill(pid, 0) == 0)
		return true;
	if(errno == ESRCH){
		waitpid(pid, nullptr, WNOHANG);
		return false;
	}
	return true;
}

}
}
