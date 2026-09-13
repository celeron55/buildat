// A shim, not Luanti's: the numbers are Luanti's own. See README.txt.
#pragma once
#include "irrlichttypes.h"

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
