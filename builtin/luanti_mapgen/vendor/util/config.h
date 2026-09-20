// A shim, not Luanti's: see ../README.txt.
#ifndef LUANTI_SHIM_UTIL_CONFIG_H
#define LUANTI_SHIM_UTIL_CONFIG_H
// glibc's <endian.h>: what Luanti's CMake detects per platform, here
// frozen at the Linux answer -- and mingw has none, so serialize.h takes
// its own byte-swapping branch there ([WIN_MAPGEN_BUILD])
#ifndef _WIN32
#define HAVE_ENDIAN_H 1
#endif

#endif
