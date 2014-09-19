// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
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
