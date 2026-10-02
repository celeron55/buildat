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
		// HMAC-SHA256: 32 bytes ([STARPORT]: a listing's secret proving
		// itself without being sent)
		ss_ hmac(const ss_ &key, const ss_ &msg);
	}
}
// vim: set noet ts=4 sw=4:
