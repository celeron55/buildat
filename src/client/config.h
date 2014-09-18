#pragma once
#include "core/types.h"

namespace client
{
	struct Config
	{
		ss_ server_address;
		ss_ polycode_path = "/home/celeron55/softat/polycode/";
		ss_ share_path = "../share";
		ss_ cache_path = "../cache";
	};
}
