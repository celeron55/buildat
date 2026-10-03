// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <list>

namespace interface
{
	namespace debug
	{
		void log_current_backtrace(const ss_ &title = "Current backtrace:");
		void log_exception_backtrace(const ss_ &title = "Exception backtrace:");

		static const size_t BACKTRACE_SIZE = 48;

		struct StoredBacktrace {
			void *frames[BACKTRACE_SIZE];
			int num_frames = 0;
			ss_ exception_name;
		};

		void get_current_backtrace(StoredBacktrace &result);
		void get_exception_backtrace(StoredBacktrace &result);

		void log_backtrace(const StoredBacktrace &result,
				const ss_ &title = "Stored backtrace:");

		struct ThreadBacktrace {
			ss_ thread_name;
			interface::debug::StoredBacktrace bt;
		};

		void log_backtrace_chain(const std::list<ThreadBacktrace> &chain,
				const char *reason, bool cut_at_api = true);

		// A watchdog for the thread that calls this ([WIN8_START] 14): every
		// call says the thread is alive; a thread of its own logs the
		// caller's backtrace once no call has come for stall_seconds -- a
		// freeze reads like a crash in the log -- and again every minute
		// of the same freeze. Started on the first call.
		void watchdog_alive(int stall_seconds = 10);

		struct SigConfig {
			bool catch_segfault = true;
			bool catch_abort = true;
		};

		void init_signal_handlers(const SigConfig &config);
	}
}
// vim: set noet ts=4 sw=4:
