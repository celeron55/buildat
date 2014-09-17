#include "os.h"
#include <sys/time.h>

int64_t get_timeofday_us()
{
	struct timeval tv;
	gettimeofday(&tv, nullptr);
	return (int64_t)tv.tv_sec*1000000 + (int64_t)tv.tv_usec;
}

