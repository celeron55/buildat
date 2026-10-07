// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace os
	{
		int64_t time_us();
		void sleep_us(int us);
		ss_ get_current_exe_path();
		// name without extension; looks next to the current executable
		ss_ get_sibling_exe_path(const ss_ &name);
		// The process's resident memory in bytes, 0 if unknown
		// ([SERVER_HEALTH]; simplified: Linux and Windows, 0 on macOS)
		int64_t memory_bytes();
	}
}

// vim: set noet ts=4 sw=4:
