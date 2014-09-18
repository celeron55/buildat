#pragma once
#include "core/types.h"

namespace interface
{
	namespace sha1
	{
		ss_ calculate(const ss_ &data);
		ss_ hex(const ss_ &raw);
	}
}
