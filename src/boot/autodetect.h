// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/config.h"

namespace boot
{
	namespace autodetect
	{
		// Return value: true if paths seem alright
		bool check_server_paths(const core::Config &config, bool log_issues);
		bool check_client_paths(const core::Config &config, bool log_issues);

		// Return value: true if succesful, false if failed
		bool detect_server_paths(core::Config &config);
		bool detect_client_paths(core::Config &config);
	}
}
// vim: set noet ts=4 sw=4:
