// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace server
{
	struct Config
	{
		ss_ rccpp_build_path = "../cache/rccpp_build";
		ss_ interface_path = "../src/interface";
		ss_ share_path = "..";
	};
}

