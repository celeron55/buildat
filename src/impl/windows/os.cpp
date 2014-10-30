// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/os.h"
#include <sys/time.h>
#include "ports/windows_minimal.h"
#include "ports/windows_compat.h"

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
	const DWORD buflen = 1000;
	char buf[buflen];
	DWORD len = GetModuleFileName(GetModuleHandle(NULL), buf, buflen);
	if(len < buflen)
		throw Exception("len < buflen");
	return buf;
}

}
}
// vim: set noet ts=4 sw=4:
