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
	}
}
// vim: set noet ts=4 sw=4:
