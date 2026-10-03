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
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include <shlobj.h>
	#include <tlhelp32.h>
	#undef interface
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

#ifdef _WIN32
// [PROCESS_SANDBOX] B 4: the Windows set, for the user to run on a Windows
// machine (Wine has no AppContainer)
static bool w_can_list(const ss_ &dir)
{
	WIN32_FIND_DATAA fd;
	HANDLE h = FindFirstFileA((dir+"\\*").c_str(), &fd);
	if(h == INVALID_HANDLE_VALUE)
		return false;
	FindClose(h);
	return true;
}

static bool w_can_write(const ss_ &path)
{
	HANDLE h = CreateFileA(path.c_str(), GENERIC_WRITE, 0, nullptr,
			CREATE_ALWAYS, FILE_FLAG_DELETE_ON_CLOSE, nullptr);
	if(h == INVALID_HANDLE_VALUE)
		return false;
	CloseHandle(h);
	return true;
}

static ss_ known_folder(int csidl)
{
	char buf[MAX_PATH] = {0};
	SHGetFolderPathA(nullptr, csidl, nullptr, 0, buf);
	return buf;
}

// The classic next-start escape: a value under HKCU\...\Run
static bool w_run_key()
{
	HKEY k;
	if(RegCreateKeyExA(HKEY_CURRENT_USER,
			"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0,
			KEY_SET_VALUE, nullptr, &k, nullptr) != ERROR_SUCCESS)
		return false;
	bool ok = RegSetValueExA(k, "buildat_box_test", 0, REG_SZ,
			(const BYTE*)"x", 2) == ERROR_SUCCESS;
	if(ok)
		RegDeleteValueA(k, "buildat_box_test");
	RegCloseKey(k);
	return ok;
}

static bool w_clipboard()
{
	if(!OpenClipboard(nullptr))
		return false;
	bool got = GetClipboardData(CF_TEXT) != nullptr;
	CloseClipboard();
	return got;
}

// The parent, or the user's explorer.exe, opened to read its memory
static bool w_open_process(bool parent)
{
	const DWORD me = GetCurrentProcessId();
	DWORD target = 0, ppid = 0;
	HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
	PROCESSENTRY32 pe;
	pe.dwSize = sizeof pe;
	for(BOOL ok = Process32First(snap, &pe); ok; ok = Process32Next(snap, &pe)){
		if(pe.th32ProcessID == me)
			ppid = pe.th32ParentProcessID;
		if(!parent && _stricmp(pe.szExeFile, "explorer.exe") == 0)
			target = pe.th32ProcessID;
	}
	CloseHandle(snap);
	if(parent)
		target = ppid;
	if(!target)
		return false;
	HANDLE h = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION,
			FALSE, target);
	if(!h)
		return false;
	CloseHandle(h);
	return true;
}

// A loopback listener every Windows has: the RPC endpoint mapper
static bool w_loopback(int port)
{
	SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
	u_long nb = 1;
	ioctlsocket(s, FIONBIO, &nb);
	sockaddr_in a = {};
	a.sin_family = AF_INET;
	a.sin_port = htons(port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	connect(s, (sockaddr*)&a, sizeof a);
	fd_set w;
	FD_ZERO(&w);
	FD_SET(s, &w);
	timeval tv = {3, 0};
	bool ok = select(0, nullptr, &w, nullptr, &tv) > 0;
	closesocket(s);
	return ok;
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
#if defined(_WIN32)
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ user = c.get<ss_>("user_path");
		const ss_ cache = c.get<ss_>("cache_path")+"/../..";
		const ss_ profile = known_folder(CSIDL_PROFILE);
		struct Attempt { ss_ what; bool got_through; };
		sv_<Attempt> tried = {
			{"list your profile", w_can_list(profile)},
			{"list Documents", w_can_list(known_folder(CSIDL_PERSONAL))},
			{"write a file in your profile",
				w_can_write(profile+"\\buildat_box_test.txt")},
			// The profile's, not CSIDL_LOCAL_APPDATA's: in the container that
			// answers the container's own directory
			{"write a file in your TEMP", w_can_write(
				profile+"\\AppData\\Local\\Temp\\buildat_box_test.txt")},
			{"write another app's directory",
				w_can_write(user+"/apps/vanilla/box_test_was_here")},
			{"write another app's shared directory",
				w_can_write(user+"/shared/vanilla/box_test_was_here")},
			{"write another app's cache",
				w_can_write(cache+"/apps/vanilla/box_test_was_here")},
			{"write the shared module build",
				w_can_write(cache+"/rccpp_build/box_test_was_here")},
			{"write the user path itself",
				w_can_write(user+"/box_test_was_here")},
			{"set a value under HKCU\\...\\Run", w_run_key()},
			{"read the clipboard", w_clipboard()},
			{"open the parent process", w_open_process(true)},
			{"open explorer.exe", w_open_process(false)},
			{"connect to 127.0.0.1:135", w_loopback(135)},
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
		const bool own = w_can_write(user+"/apps/box_test/save") &&
				w_can_write(user+"/shared/box_test/shared") &&
				w_can_list(user+"/shared/vanilla");
		log_i(MODULE, "box_test: %zu reaches tried, %i got through%s; "
				"its own files %s", tried.size(), n, cs(through),
				own ? "work" : "DO NOT WORK");
		m_server->shutdown(0, "box_test done");
#elif !defined(__linux__)
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
			// Everyone the user owns but this process; seccomp refuses it
			// whatever the kernel, Landlock from ABI 6 ([SECURITY_RUN_1])
			{"signal every process (kill -1)", kill(-1, 0) == 0},
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
				can_list(user+"/shared/vanilla") && resolves("localhost") &&
				// and signal itself, which raise() and abort() do
				kill(getpid(), 0) == 0;
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
