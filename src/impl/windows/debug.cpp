// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/debug.h"
#include "core/log.h"
#define MODULE "debug"

namespace interface {
namespace debug {

void init_signal_handlers(const SigConfig &config)
{
	// No-op
}

void log_current_backtrace(const ss_ &title)
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

void log_exception_backtrace(const ss_ &title)
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

void get_current_backtrace(StoredBacktrace &result)
{
}

void get_exception_backtrace(StoredBacktrace &result)
{
}

void log_backtrace(const StoredBacktrace &result, const ss_ &title)
{
}

}
}
// vim: set noet ts=4 sw=4:
