#pragma once
#include "server/rccpp.h"

namespace interface
{
	struct Server
	{
		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
	};
}
