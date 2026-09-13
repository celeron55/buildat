// A shim, not Luanti's: see README.txt.
//
// What the vendored code wants out of Luanti's platform layer, which here
// is nothing: buildat has its own and the mapgen does not use it.
#pragma once
#include "irrlichttypes.h"
#include <string>

namespace porting {
	// Luanti's mapgen only ever asks this to decide whether to be chatty
	inline void TrackFreedMemory(size_t bytes = 0){ (void)bytes; }
	
}
