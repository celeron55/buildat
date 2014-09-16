#pragma once
#include "core/types.h"

namespace interface
{
	struct Server
	{
		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual ss_ get_modules_path() = 0;
	};
}
