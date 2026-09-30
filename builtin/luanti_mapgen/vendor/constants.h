// A shim, not Luanti's: the numbers are Luanti's own. See README.txt.
#ifndef LUANTI_SHIM_CONSTANTS_H
#define LUANTI_SHIM_CONSTANTS_H
#include "irrlichttypes.h"
#include <cmath>

// Urho3D has an M_PI of its own in a namespace, and the vendored code wants
// the plain one
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// The size of a MapBlock, which is what Luanti's mapgens count in
#define MAP_BLOCKSIZE 16
// One node is this many "units" in Luanti's float coordinates
#define BS 10.0f
// How far a world goes, in nodes
#define MAX_MAP_GENERATION_LIMIT (31000)
// The most map a single call may work on at once
#define MAX_WORKING_VOLUME 4096000

#define MYMIN(a, b) ((a) < (b) ? (a) : (b))
#define MYMAX(a, b) ((a) > (b) ? (a) : (b))

#endif
