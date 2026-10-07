// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include "interface/fs.h"
#include <atomic>
#include <cstring>
#include <cstdio>
#include <sys/time.h>
#include <unistd.h>
#include <sys/statvfs.h>

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
	// statm: size, then resident, in pages
	FILE *f = fopen("/proc/self/statm", "r");
	if(!f)
		return 0;
	long size = 0, resident = 0;
	const int n = fscanf(f, "%ld %ld", &size, &resident);
	fclose(f);
	return n == 2 ? (int64_t)resident * sysconf(_SC_PAGESIZE) : 0;
}

int64_t free_bytes(const ss_ &path)
{
	struct statvfs st;
	if(statvfs(path.c_str(), &st) != 0)
		return -1;
	return (int64_t)st.f_bavail * (int64_t)st.f_frsize;
}

ss_ get_current_exe_path()
{
#ifdef __EMSCRIPTEN__
	// The web client has no executable file; this is where it would be in
	// the bundle's tree ([WEB_CLIENT]), beside the share path's client/
	return "/buildat/bin/buildat";
#endif
	char buf[BUFSIZ];
	memset(buf, 0, BUFSIZ);
	if(readlink("/proc/self/exe", buf, BUFSIZ-1) == -1)
		throw Exception("readlink(\"/proc/self/exe\") failed");
	return buf;
}

ss_ get_sibling_exe_path(const ss_ &name)
{
	return interface::fs::strip_file_name(get_current_exe_path())+"/"+name;
}

}
}
// vim: set noet ts=4 sw=4:
