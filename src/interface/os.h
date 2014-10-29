// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace os
	{
		int64_t get_timeofday_us();
		void sleep_us(int us);
		ss_ get_current_exe_path();
	}
}

// vim: set noet ts=4 sw=4:
