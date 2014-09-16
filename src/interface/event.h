#pragma once
#include "core/types.h"

namespace interface
{
	struct Event
	{
		enum class Type {
			START,
		} type;
		std::stringstream data;
	};
}

