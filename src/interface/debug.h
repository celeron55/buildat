// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace debug
	{
		struct SigConfig {
			bool catch_segfault = true;
			bool catch_abort = true;
		};

		void init_signal_handlers(const SigConfig &config);

		void log_current_backtrace(const ss_ &title="Current backtrace:");

		void log_exception_backtrace(const ss_ &title="Exception backtrace:");
	}
}
// vim: set noet ts=4 sw=4:
