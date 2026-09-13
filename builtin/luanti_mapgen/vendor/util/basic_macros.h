// A shim, not Luanti's: see README.txt.
#ifndef LUANTI_SHIM_UTIL_BASIC_MACROS_H
#define LUANTI_SHIM_UTIL_BASIC_MACROS_H

#include <algorithm>

// Whether a container holds a value, which is Luanti's own one-liner
#define CONTAINS(c, v) (std::find((c).begin(), (c).end(), (v)) != (c).end())

#define ARRLEN(x) (sizeof(x) / sizeof((x)[0]))
#define MYMIN(a, b) ((a) < (b) ? (a) : (b))
#define MYMAX(a, b) ((a) > (b) ? (a) : (b))
#define DISABLE_CLASS_COPY(C) \
	C(const C &) = delete; \
	C &operator=(const C &) = delete;
#define ALLOW_CLASS_COPY(C) \
	C(const C &) = default; \
	C &operator=(const C &) = default;

#endif
