// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include "interface/fs.h"
#include <cstring>
#include <cstdio>
#include <sys/time.h>
#include <unistd.h>

namespace interface {
namespace os {

int64_t time_us()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
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
