// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "os.h"
#include <sys/time.h>

int64_t get_timeofday_us()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return (int64_t)tv.tv_sec * 1000000 + (int64_t)tv.tv_usec;
}

