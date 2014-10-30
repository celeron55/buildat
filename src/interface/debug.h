// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <list>

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

		struct StoredBacktrace {
			void *frames[16];
			int num_frames = 0;
			ss_ exception_name;
		};

		void get_current_backtrace(StoredBacktrace &result);
		void get_exception_backtrace(StoredBacktrace &result);

		void log_backtrace(const StoredBacktrace &result,
				const ss_ &title="Stored backtrace:");

		struct ThreadBacktrace {
			ss_ thread_name;
			interface::debug::StoredBacktrace bt;
		};

		void log_backtrace_chain(const std::list<ThreadBacktrace> &chain,
				const char *reason);
	}
}
// vim: set noet ts=4 sw=4:
