// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

// Arbitrary-precision unsigned integer arithmetic, for the few operations that
// are too slow or too fiddly to do in Lua: modular exponentiation and what
// goes with it. Numbers are byte strings, big-endian, and come back with no
// leading zero bytes ("" is zero).

namespace interface
{
	namespace bignum
	{
		ss_ add(const ss_ &a, const ss_ &b);
		ss_ mul(const ss_ &a, const ss_ &b);
		ss_ mod(const ss_ &a, const ss_ &m);
		// (a - b) mod m, however the two compare
		ss_ sub_mod(const ss_ &a, const ss_ &b, const ss_ &m);
		ss_ mul_mod(const ss_ &a, const ss_ &b, const ss_ &m);
		ss_ mod_exp(const ss_ &base, const ss_ &exponent, const ss_ &m);

		// Bytes from the platform's cryptographic random source
		ss_ random_bytes(size_t n);
	}
}
// vim: set noet ts=4 sw=4:
