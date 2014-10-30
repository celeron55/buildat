// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include "interface/fs.h"
#include <cstring>
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

ss_ get_current_exe_path()
{
	char buf[BUFSIZ];
	memset(buf, 0, BUFSIZ);
	if(readlink("/proc/self/exe", buf, BUFSIZ-1) == -1)
		throw Exception("readlink(\"/proc/self/exe\") failed");
	return buf;
}

}
}
// vim: set noet ts=4 sw=4:
