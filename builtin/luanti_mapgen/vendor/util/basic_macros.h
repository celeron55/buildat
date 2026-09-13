// A shim, not Luanti's: see README.txt.
#pragma once

#define ARRLEN(x) (sizeof(x) / sizeof((x)[0]))
#define MYMIN(a, b) ((a) < (b) ? (a) : (b))
#define MYMAX(a, b) ((a) > (b) ? (a) : (b))
#define DISABLE_CLASS_COPY(C) \
	C(const C &) = delete; \
	C &operator=(const C &) = delete;
#define ALLOW_CLASS_COPY(C) \
	C(const C &) = default; \
	C &operator=(const C &) = default;
