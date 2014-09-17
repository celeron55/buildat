#pragma once
#include "core/types.h"

namespace interface
{
	struct Module;

	struct Server
	{
		virtual ~Server(){}
		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual ss_ get_modules_path() = 0;
		virtual ss_ get_builtin_modules_path() = 0;
		virtual SafeModule* get_module(const ss_ &module_name) = 0;
	};
}
