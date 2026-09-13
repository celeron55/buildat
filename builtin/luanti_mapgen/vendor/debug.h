// A shim, not Luanti's: see README.txt.
//
// Luanti's assertions. A mapgen that trips one has a bug, and the server
// says so and stops rather than generating something wrong.
#pragma once
#include "exceptions.h"
#include <cassert>
#include <string>

#define FATAL_ERROR(msg) \
	throw BaseException(std::string("FATAL ERROR: ") + (msg))
#define FATAL_ERROR_IF(expr, msg) \
	((expr) ? FATAL_ERROR(msg) : (void)(0))
#define sanity_check(expr) assert(expr)
#define SANITY_CHECK(expr) assert(expr)
