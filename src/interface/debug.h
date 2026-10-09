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
		// What a freeze of 30 s does besides the logging (Linux; nothing
		// elsewhere): f is called on the frozen thread from a signal
		// handler, so it may do only what a handler may
		void watchdog_on_freeze(void (*f)());

		// **A crash's minidump** ([WIN_MINIDUMP], Windows; nothing
		// elsewhere): from this call on, a crash also writes
		// <dir>/crash-<exe>-<time>.dmp and keeps the newest five there.
		// A forced crash, for the test, is BUILDAT_DEBUG_CRASH=<exe>.
		void set_crash_dump_dir(const ss_ &dir, const ss_ &exe);
		// The newest dump in dir not told about yet, which is then told
		// about (a file beside them remembers it); "" if none
		ss_ crash_dump_untold(const ss_ &dir);

		struct SigConfig {
			bool catch_segfault = true;
			bool catch_abort = true;
		};

		void init_signal_handlers(const SigConfig &config);
	}
}
// vim: set noet ts=4 sw=4:
