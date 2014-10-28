// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/config.h"

namespace server
{
	struct Config: public core::Config
	{
		Config();

		bool check_paths();
	};
}

// vim: set noet ts=4 sw=4:
