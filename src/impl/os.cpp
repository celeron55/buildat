// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include <sys/time.h>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <unistd.h>
#endif

namespace interface {
namespace os {

int64_t get_timeofday_us()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

void sleep_us(int us)
{
	usleep(us);
}

}
}
// vim: set noet ts=4 sw=4:
