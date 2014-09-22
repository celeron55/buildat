// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace client
{
	struct Config
	{
		ss_ server_address;
		ss_ share_path = "..";
		ss_ cache_path = "../cache";

		bool check_paths();
	};
}
