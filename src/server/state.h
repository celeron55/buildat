#pragma once
#include "core/types.h"

namespace interface
{
	struct Module;
}

namespace server
{
	struct State
	{
		virtual ~State(){}
		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual void load_modules(const ss_ &path) = 0;
		virtual interface::Module* get_module(const ss_ &module_name) = 0;
	};

	State* createState();
}
