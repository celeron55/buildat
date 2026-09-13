// A shim, not Luanti's: the tables are Luanti's own. See ../README.txt.
#pragma once
#include "../irrlichttypes_bloated.h"

// The six directions, in Luanti's own order
const v3s16 g_6dirs[6] = {
	v3s16( 0, 0, 1), // back
	v3s16( 0, 1, 0), // top
	v3s16( 1, 0, 0), // right
	v3s16( 0, 0,-1), // front
	v3s16( 0,-1, 0), // bottom
	v3s16(-1, 0, 0), // left
};

const v3s16 g_7dirs[7] = {
	v3s16( 0, 0, 1),
	v3s16( 0, 1, 0),
	v3s16( 1, 0, 0),
	v3s16( 0, 0,-1),
	v3s16( 0,-1, 0),
	v3s16(-1, 0, 0),
	v3s16( 0, 0, 0),
};

const v3s16 g_4dirs[4] = {
	v3s16( 0, 0, 1),
	v3s16( 1, 0, 0),
	v3s16( 0, 0,-1),
	v3s16(-1, 0, 0),
};
