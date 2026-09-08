// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace sha256
	{
		// 32 bytes of digest
		ss_ calculate(const ss_ &data);
		ss_ hex(const ss_ &raw);
	}
}
// vim: set noet ts=4 sw=4:
