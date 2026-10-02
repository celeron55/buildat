// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// [PROCESS_SANDBOX]'s check: **a hostile app**. It spends its start trying to
// reach what the server's box must keep from an app -- the user's files, the
// other apps' directories and caches, the desktop's sockets, other processes
// -- and checks that what it may have, its own save and shared directory,
// still works. One verdict line, which apps/box_test/check.sh reads; then
// the server exits.
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "core/log.h"
#include <fstream>
#include <cerrno>
#include <cstdlib>
#ifdef __linux__
	#include <fcntl.h>
	#include <unistd.h>
	#include <dirent.h>
	#include <signal.h>
	#include <sys/socket.h>
	#include <sys/un.h>
	#include <sys/stat.h>
	#include <sys/syscall.h>
	#include <netdb.h>
	#include <netinet/in.h>
	#include <cstring>
#endif
#define MODULE "box_test"

using interface::Event;

namespace box_test {

#ifdef __linux__
static bool can_read(const ss_ &path)
{
	int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
	if(fd < 0)
		return false;
	char c;
	bool ok = read(fd, &c, 1) >= 0;
	close(fd);
	return ok;
}

static bool can_list(const ss_ &path)
{
	DIR *d = opendir(path.c_str());
	if(!d)
		return false;
	closedir(d);
	return true;
}

static bool can_write(const ss_ &path)
{
	int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_CLOEXEC, 0600);
	if(fd < 0)
		return false;
	bool ok = write(fd, "x", 1) == 1;
	close(fd);
	unlink(path.c_str());
	return ok;
}

// A unix socket at a path, or an abstract one where the name starts with @
static bool can_connect_unix(const ss_ &name)
{
	int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if(fd < 0)
		return false;
	struct sockaddr_un a;
	memset(&a, 0, sizeof a);
	a.sun_family = AF_UNIX;
	size_t n = name.size() < sizeof a.sun_path ? name.size() :
			sizeof a.sun_path - 1;
	memcpy(a.sun_path, name.c_str(), n);
	if(name[0] == '@')
		a.sun_path[0] = 0;
	bool ok = connect(fd, (struct sockaddr*)&a,
			offsetof(struct sockaddr_un, sun_path) + n) == 0;
	close(fd);
	return ok;
}

// TCP to a port on this machine: got through unless the box refused it
// (EACCES); a refusal by nobody listening is the port reached
static bool tcp_reaches(int port)
{
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if(fd < 0)
		return false;
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bool reached = connect(fd, (struct sockaddr*)&a, sizeof a) == 0 ||
			errno != EACCES;
	close(fd);
	return reached;
}

static bool tcp_binds(int port)
{
	int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
	if(fd < 0)
		return false;
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	bool ok = bind(fd, (struct sockaddr*)&a, sizeof a) == 0;
	close(fd);
	return ok;
}

// Name resolution with unix sockets refused: nscd and systemd-resolved
// answer over one, and glibc falls back to /etc/resolv.conf over UDP
static bool resolves(const char *name)
{
	struct addrinfo *res = nullptr;
	if(getaddrinfo(name, "443", nullptr, &res) != 0)
		return false;
	freeaddrinfo(res);
	return true;
}
#endif

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("main"),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
	}

	void on_start()
	{
#ifndef __linux__
		log_i(MODULE, "box_test: not written for this platform");
		m_server->shutdown(0, "box_test done");
#else
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ user = c.get<ss_>("user_path");
		// The app's own cache is <cache>/apps/box_test when boxed
		const ss_ cache = c.get<ss_>("cache_path")+"/../..";
		const ss_ home = getenv("HOME") ? getenv("HOME") : "/root";
		const char *secret = getenv("BUILDAT_BOX_TEST_SECRET");
		const ss_ uid = itos((int)getuid());
		const char *dbus = getenv("DBUS_SESSION_BUS_ADDRESS");
		ss_ dbus_path = "/run/user/"+uid+"/bus";
		if(dbus && ss_(dbus).compare(0, 10, "unix:path=") == 0)
			dbus_path = ss_(dbus).substr(10, ss_(dbus).find(',') - 10);

		struct Attempt { ss_ what; bool got_through; };
		sv_<Attempt> tried = {
			{"list $HOME", can_list(home)},
			{"read ~/.bashrc", can_read(home+"/.bashrc")},
			{"read ~/.ssh", can_list(home+"/.ssh")},
			{"read a file outside the box", secret && can_read(secret)},
			{"write ~/.buildat_box_test", can_write(home+"/.buildat_box_test")},
			{"write another app's directory",
				can_write(user+"/apps/vanilla/box_test_was_here")},
			{"write another app's shared directory",
				can_write(user+"/shared/vanilla/box_test_was_here")},
			{"write another app's cache",
				can_write(cache+"/apps/vanilla/box_test_was_here")},
			{"write the shared module build",
				can_write(cache+"/rccpp_build/box_test_was_here")},
			{"write the user path itself",
				can_write(user+"/box_test_was_here")},
			{"write /tmp", can_write("/tmp/buildat_box_test")},
			{"list /run/user", can_list("/run/user/"+uid)},
			{"connect to the D-Bus session bus", can_connect_unix(dbus_path)},
			{"connect to X11's abstract socket",
				can_connect_unix("@/tmp/.X11-unix/X0")},
			{"connect to X11's socket file",
				can_connect_unix("/tmp/.X11-unix/X0")},
			{"read the parent's environment",
				can_read("/proc/"+itos((int)getppid())+"/environ")},
			{"signal the parent", kill(getppid(), 0) == 0},
			{"a shell writing $HOME", [&](){
				const ss_ f = home+"/.buildat_box_test_shell";
				int r = system(("touch '"+f+"' 2>/dev/null").c_str());
				struct stat st;
				bool there = stat(f.c_str(), &st) == 0;
				(void)r;
				return there;
			}()},
			{"io_uring", syscall(__NR_io_uring_setup, 1, nullptr) >= 0 ||
				errno != ENOSYS},
			// The TCP rules: other programs' services on this machine
			{"connect to 127.0.0.1:22", tcp_reaches(22)},
			{"connect to 127.0.0.1:631", tcp_reaches(631)},
			{"listen on another port", tcp_binds(29899)},
		};
		ss_ through;
		int n = 0;
		for(const Attempt &a : tried){
			log_v(MODULE, "box_test: %s: %s", cs(a.what),
					a.got_through ? "GOT THROUGH" : "refused");
			if(a.got_through){
				through += (n++ ? ", " : ": ")+a.what;
				log_w(MODULE, "box_test: %s GOT THROUGH", cs(a.what));
			}
		}
		// And what an app has: its own save and its own shared directory
		const bool own = can_write(user+"/apps/box_test/save") &&
				can_write(user+"/shared/box_test/shared") &&
				can_list(user+"/shared/vanilla") && resolves("localhost");
		// Not asserted: it needs the network
		log_i(MODULE, "box_test: resolving buildat.org %s",
				resolves("buildat.org") ? "works" : "FAILED");
		log_i(MODULE, "box_test: %zu reaches tried, %i got through%s; "
				"its own files %s", tried.size(), n, cs(through),
				own ? "work" : "DO NOT WORK");
		m_server->shutdown(0, "box_test done");
#endif
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
