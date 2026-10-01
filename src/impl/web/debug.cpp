// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// interface/debug.h in the web client ([WEB_CLIENT]): a browser has no
// execinfo and no signals, and its console already shows where an abort
// came from.
// simplified: no backtraces; emscripten_get_callstack would be the upgrade.
#include "interface/debug.h"
#include "core/log.h"
#define MODULE "debug"

namespace interface {
namespace debug {

void log_current_backtrace(const ss_ &title){}
void log_exception_backtrace(const ss_ &title){}
void get_current_backtrace(StoredBacktrace &result){ result.num_frames = 0; }
void get_exception_backtrace(StoredBacktrace &result){ result.num_frames = 0; }
void log_backtrace(const StoredBacktrace &result, const ss_ &title){}
void log_backtrace_chain(const std::list<ThreadBacktrace> &chain,
		const char *reason, bool cut_at_api)
{
	log_w(MODULE, "%s", reason);
}
void watchdog_alive(int stall_seconds){}
void init_signal_handlers(const SigConfig &config){}

}
}
// vim: set noet ts=4 sw=4:
