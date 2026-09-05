#include "interface/process.h"
#include "core/log.h"
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include <cstring>
#include <vector>
#ifdef __linux__
#include <sys/prctl.h>
#endif
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
		_exit(127);
	}
	int exit_status = 1;
	if(waitpid(f, &exit_status, 0) < 0)
		return 1;
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
		setpgid(0, 0);
#ifdef __linux__
		prctl(PR_SET_PDEATHSIG, SIGKILL);
		if(getppid() == 1)
			_exit(1);
#endif
		std::vector<char*> argv;
		argv.push_back(const_cast<char*>(path.c_str()));
		for(const ss_ &a : args)
			argv.push_back(const_cast<char*>(a.c_str()));
		argv.push_back(nullptr);
		execv(path.c_str(), argv.data());
		log_w(MODULE, "execv(\"%s\") failed: %s", cs(path), strerror(errno));
		_exit(127);
	}
	setpgid(pid, pid);
	h.impl = pid;
	log_i(MODULE, "Started pid %i: %s", (int)pid, cs(path));
	return h;
}

static void kill_tree(pid_t pid, int sig)
{
	kill(-pid, sig);
	kill(pid, sig);
}

static bool reap_dead(Handle &h)
{
	if(!h.valid())
		return true;
	pid_t pid = (pid_t)h.impl;
	int status = 0;
	pid_t r = waitpid(pid, &status, WNOHANG);
	if(r == pid || (r < 0 && errno == ECHILD && kill(pid, 0) != 0 &&
			errno == ESRCH)){
		h.impl = 0;
		return true;
	}
	return false;
}

void request_terminate(Handle &h)
{
	if(!h.valid())
		return;
	if(reap_dead(h))
		return;
	pid_t pid = (pid_t)h.impl;
	log_i(MODULE, "SIGTERM pid %i", (int)pid);
	kill_tree(pid, SIGTERM);
}

void kill_force(Handle &h)
{
	if(!h.valid())
		return;
	if(reap_dead(h))
		return;
	pid_t pid = (pid_t)h.impl;
	log_w(MODULE, "SIGKILL pid %i", (int)pid);
	kill_tree(pid, SIGKILL);
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

void terminate(Handle &h)
{
	if(!h.valid())
		return;
	request_terminate(h);
	for(int i = 0; i < 200; i++){
		if(!is_running(h) || reap_dead(h))
			return;
		usleep(50000);
	}
	kill_force(h);
}

}
}
