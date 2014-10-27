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

void log_current_backtrace()
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

void log_exception_backtrace()
{
	log_i(MODULE, "Backtrace logging not implemented on Windows");
}

}
}
// vim: set noet ts=4 sw=4:
