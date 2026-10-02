// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "server/confine.h"
#include "core/config.h"
#include "core/log.h"
#include "interface/fs.h"
#define MODULE "confine"

#ifndef __linux__

namespace server {
ss_ confine(core::Config &config, const ss_ &module_path)
{
	return "this platform has no box yet";
}
}

#else

#include <linux/landlock.h>
#include <linux/seccomp.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <stddef.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>

// What older headers lack: the build box is older than the kernels the
// server runs on
#ifndef SYS_landlock_create_ruleset
	#define SYS_landlock_create_ruleset 444
	#define SYS_landlock_add_rule 445
	#define SYS_landlock_restrict_self 446
#endif
#ifndef LANDLOCK_ACCESS_FS_REFER
	#define LANDLOCK_ACCESS_FS_REFER (1ULL << 13)
#endif
#ifndef LANDLOCK_ACCESS_FS_TRUNCATE
	#define LANDLOCK_ACCESS_FS_TRUNCATE (1ULL << 14)
#endif
#ifndef LANDLOCK_ACCESS_FS_IOCTL_DEV
	#define LANDLOCK_ACCESS_FS_IOCTL_DEV (1ULL << 15)
#endif
#ifndef LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET
	#define LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET (1ULL << 0)
	#define LANDLOCK_SCOPE_SIGNAL (1ULL << 1)
#endif
#ifndef __NR_io_uring_setup
	#define __NR_io_uring_setup 425
	#define __NR_io_uring_enter 426
	#define __NR_io_uring_register 427
#endif

namespace server {

// The ruleset's attribute as the newest kernel knows it; an older kernel
// is handed the prefix it knows
struct RulesetAttr {
	uint64_t handled_access_fs;
	uint64_t handled_access_net;
	uint64_t scoped;
};

static const uint64_t FS_ABI1 =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
		LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_READ_DIR |
		LANDLOCK_ACCESS_FS_REMOVE_DIR | LANDLOCK_ACCESS_FS_REMOVE_FILE |
		LANDLOCK_ACCESS_FS_MAKE_CHAR | LANDLOCK_ACCESS_FS_MAKE_DIR |
		LANDLOCK_ACCESS_FS_MAKE_REG | LANDLOCK_ACCESS_FS_MAKE_SOCK |
		LANDLOCK_ACCESS_FS_MAKE_FIFO | LANDLOCK_ACCESS_FS_MAKE_BLOCK |
		LANDLOCK_ACCESS_FS_MAKE_SYM;
// What a rule on a file, not a directory, may carry
static const uint64_t FS_FILE_RIGHTS =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_WRITE_FILE |
		LANDLOCK_ACCESS_FS_READ_FILE | LANDLOCK_ACCESS_FS_TRUNCATE |
		LANDLOCK_ACCESS_FS_IOCTL_DEV;
static const uint64_t FS_READ =
		LANDLOCK_ACCESS_FS_EXECUTE | LANDLOCK_ACCESS_FS_READ_FILE |
		LANDLOCK_ACCESS_FS_READ_DIR;

static ss_ real(const ss_ &path)
{
	char buf[PATH_MAX];
	if(!realpath(path.c_str(), buf))
		return "";
	return buf;
}

static bool inside(const ss_ &path, const ss_ &dir)
{
	return path.size() > dir.size() && path.compare(0, dir.size(), dir) == 0 &&
			path[dir.size()] == '/';
}

struct Ruleset
{
	int fd = -1;
	uint64_t handled = 0;
	sv_<ss_> refused; // Paths a rule could not be made for

	void add(const ss_ &path, uint64_t access)
	{
		const ss_ p = real(path);
		if(p.empty())
			return; // Not there: nothing to allow
		int pfd = open(p.c_str(), O_PATH | O_CLOEXEC);
		if(pfd < 0){
			refused.push_back(p);
			return;
		}
		struct landlock_path_beneath_attr attr;
		attr.allowed_access = access & handled;
		attr.parent_fd = pfd;
		struct stat st;
		if(fstat(pfd, &st) == 0 && !S_ISDIR(st.st_mode))
			attr.allowed_access &= FS_FILE_RIGHTS;
		if(syscall(SYS_landlock_add_rule, fd, LANDLOCK_RULE_PATH_BENEATH,
				&attr, 0) != 0)
			refused.push_back(p+": "+strerror(errno));
		close(pfd);
	}

	// Read access to `dir` but not to what is in `holes` under it: Landlock
	// only adds, so a granted directory gives all of itself, and the
	// development tree keeps user/ and cache/ inside the install directory.
	// The directory's other entries are granted one by one instead.
	void add_around(const ss_ &dir, const sv_<ss_> &holes, uint64_t access)
	{
		const ss_ d = real(dir);
		if(d.empty())
			return;
		bool has_hole = false;
		for(const ss_ &h : holes){
			if(h == d)
				return;
			if(inside(h, d))
				has_hole = true;
		}
		if(!has_hole){
			add(d, access);
			return;
		}
		for(const interface::fs::Node &n : interface::fs::list_directory(d)){
			if(n.name == "." || n.name == "..")
				continue;
			add_around(d+"/"+n.name, holes, access);
		}
	}
};

static int count_threads()
{
	int n = 0;
	DIR *d = opendir("/proc/self/task");
	if(!d)
		return -1;
	while(struct dirent *e = readdir(d))
		if(e->d_name[0] != '.')
			n++;
	closedir(d);
	return n;
}

// seccomp: no unix socket -- Landlock does not govern a named socket's
// connect(), and D-Bus, X11 and docker.sock are all one -- and no io_uring,
// which goes around both. The rest is Landlock's.
static ss_ install_seccomp()
{
#if defined(__x86_64__)
	const uint32_t arch = AUDIT_ARCH_X86_64;
#elif defined(__aarch64__)
	const uint32_t arch = AUDIT_ARCH_AARCH64;
#else
	return "seccomp: not written for this architecture";
#endif
	const uint32_t deny_unix = SECCOMP_RET_ERRNO | (EAFNOSUPPORT & SECCOMP_RET_DATA);
	const uint32_t deny_enosys = SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA);
	struct sock_filter filter[] = {
		BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, arch, 1, 0),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
		BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
		// The x32 numbers are the same calls under other names
		BPF_JUMP(BPF_JMP | BPF_JGE | BPF_K, 0x40000000, 0, 1),
		BPF_STMT(BPF_RET | BPF_K, deny_enosys),
#endif
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_setup, 3, 0),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_enter, 2, 0),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_io_uring_register, 1, 0),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_socket, 2, 1),
		BPF_STMT(BPF_RET | BPF_K, deny_enosys),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
		// socket(domain, ...): the low word of the first argument
		BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
		BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX, 0, 1),
		BPF_STMT(BPF_RET | BPF_K, deny_unix),
		BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
	};
	struct sock_fprog prog = {
		(unsigned short)(sizeof(filter) / sizeof(filter[0])), filter};
	if(prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0)
		return ss_("seccomp: ")+strerror(errno);
	return "";
}

ss_ confine(core::Config &config, const ss_ &module_path)
{
	// Landlock restricts the calling thread and what it starts; a thread
	// already running would stay outside
	const int threads = count_threads();
	if(threads != 1)
		return "the box is made before any thread starts, and "+
				itos(threads)+" are running";

	const int abi = syscall(SYS_landlock_create_ruleset, nullptr, 0,
			LANDLOCK_CREATE_RULESET_VERSION);
	if(abi < 1)
		return ss_("Landlock is not available (")+strerror(errno)+"): the "
				"kernel is older than 5.13 or has it off in its lsm= list";

	// The app's name, as the server's get_app_id() takes it
	ss_ app = module_path;
	while(!app.empty() && (app.back() == '/' || app.back() == '\\'))
		app.pop_back();
	const size_t sep = app.find_last_of("/\\");
	if(sep != ss_::npos)
		app = app.substr(sep + 1);
	if(app.empty() || app == "." || app == "..")
		app = "unnamed";

	const ss_ user = real(config.get<ss_>("user_path"));
	const ss_ cache = real(config.get<ss_>("cache_path"));
	if(user.empty() || cache.empty())
		return "the user or the cache path does not resolve";
	const ss_ prebuilt = config.get<ss_>("rccpp_build_path");

	// **The app's own cache** (decided 2026-10-02: a cache shared between
	// apps is an escape between them -- app A writes a module object app
	// B loads). The shared rccpp_build stays as what was built before, read
	// only: a module whose hash matches there is loaded from it.
	const ss_ app_cache = cache+"/apps/"+app;
	const ss_ app_user = user+"/apps/"+app;
	const ss_ app_shared = user+"/shared/"+app;
	for(const ss_ &d : {app_cache+"/tmp", app_cache+"/rccpp_build", app_user,
			app_shared})
		interface::fs::create_directories(d);
	config.set("cache_path", app_cache);
	config.set("rccpp_build_path", app_cache+"/rccpp_build");
	config.set("rccpp_prebuilt_path", prebuilt);
	// The compiler's temporary files
	setenv("TMPDIR", (app_cache+"/tmp").c_str(), 1);

	RulesetAttr attr;
	attr.handled_access_fs = FS_ABI1;
	if(abi >= 2)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_REFER;
	if(abi >= 3)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_TRUNCATE;
	if(abi >= 5)
		attr.handled_access_fs |= LANDLOCK_ACCESS_FS_IOCTL_DEV;
	// simplified: no TCP rules -- an app's outgoing ports are not known
	// ahead (a mod's HTTP), and the threat model is the user's files and
	// programs; bind and connect by port when an app can declare them
	attr.handled_access_net = 0;
	attr.scoped = abi >= 6 ? (LANDLOCK_SCOPE_ABSTRACT_UNIX_SOCKET |
			LANDLOCK_SCOPE_SIGNAL) : 0;
	const size_t attr_size = abi >= 6 ? sizeof(RulesetAttr) :
			abi >= 4 ? offsetof(RulesetAttr, scoped) :
			offsetof(RulesetAttr, handled_access_net);
	Ruleset rs;
	rs.handled = attr.handled_access_fs;
	rs.fd = syscall(SYS_landlock_create_ruleset, &attr, attr_size, 0);
	if(rs.fd < 0)
		return ss_("Landlock: ")+strerror(errno);

	const uint64_t rw = rs.handled;
	// The system: programs, libraries, the compiler, certificates, the
	// resolver's files. Not /run, /home, /root, /mnt, /media, /var, /tmp.
	for(const char *p : {"/usr", "/lib", "/lib32", "/lib64", "/bin", "/sbin",
			"/etc", "/opt", "/nix", "/proc", "/sys"})
		rs.add(p, FS_READ);
	// /etc's links out of it, granted where they lead: resolv.conf is
	// /run/systemd/resolve/stub-resolv.conf under systemd-resolved, and
	// without it no name resolves
	for(const char *p : {"/etc/resolv.conf", "/etc/hosts",
			"/etc/nsswitch.conf", "/etc/localtime"})
		rs.add(p, FS_READ);
	for(const char *p : {"/dev/null", "/dev/zero", "/dev/full",
			"/dev/random", "/dev/urandom"})
		rs.add(p, rw);
	// The install: the share path, the executable's, the headers and
	// Urho3D's, with the user and cache paths cut out of them
	const sv_<ss_> holes = {user, cache};
	char exe[PATH_MAX];
	ssize_t n = readlink("/proc/self/exe", exe, sizeof exe - 1);
	ss_ exe_dir = n > 0 ? interface::fs::strip_file_name(ss_(exe, n)) : "";
	for(const ss_ &p : {config.get<ss_>("share_path"), exe_dir,
			config.get<ss_>("interface_path"), config.get<ss_>("urho3d_path"),
			config.get<ss_>("web_client_path"), module_path,
			interface::fs::strip_file_name(
				config.get<ss_>("compiler_command"))})
		if(!p.empty())
			rs.add_around(p, holes, FS_READ);
	// The app's own, and what the other apps share, read only
	rs.add(app_user, rw);
	rs.add(app_shared, rw);
	rs.add(app_cache, rw);
	rs.add(user+"/shared", FS_READ);
	rs.add_around(prebuilt, {app_cache}, FS_READ);

	if(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0){
		close(rs.fd);
		return ss_("no_new_privs: ")+strerror(errno);
	}
	if(syscall(SYS_landlock_restrict_self, rs.fd, 0) != 0){
		const ss_ why = strerror(errno);
		close(rs.fd);
		return "Landlock: "+why;
	}
	close(rs.fd);
	const ss_ seccomp = install_seccomp();
	if(!seccomp.empty())
		return seccomp;

	for(const ss_ &r : rs.refused)
		log_w(MODULE, "No rule for %s", cs(r));
	log_i(MODULE, "The server is boxed: Landlock ABI %i (the filesystem%s), "
			"seccomp (no unix sockets, no io_uring); TCP is not limited. "
			"%s and %s writable, %s/shared readable",
			abi, abi >= 6 ? ", abstract sockets and signals scoped" :
				"; signals and abstract sockets not scoped before ABI 6",
			cs(app_user), cs(app_shared), cs(user));
	return "";
}

}
#endif
// vim: set noet ts=4 sw=4:
