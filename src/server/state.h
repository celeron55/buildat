#pragma once
#include "core/types.h"

namespace server
{
	struct State
	{
		virtual ~State(){}
		virtual void load_module(const ss_ &path) = 0;
	};

	State* createState();
}
