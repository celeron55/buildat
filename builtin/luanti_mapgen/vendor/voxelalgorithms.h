// A shim, not Luanti's: see README.txt.
//
// Luanti's mapgen lights what it generates through these; voxelworld owns
// the light here and floods it as the map is written, so a second pass
// would be work done twice. See "Mapgen stage 3" in
// doc/plan/luanti_module_plan.md.
#pragma once
#include "irrlichttypes_bloated.h"
#include "voxel.h"

class MMVManip;
class NodeDefManager;

namespace voxalgo {

inline void blit_back_with_light(class ServerMap *map, MMVManip *vm,
		void *modified_blocks){}

// The two the mapgen calls directly, and both are voxelworld's job
inline void setLightingDay(MMVManip *vm, const VoxelArea &a,
		const NodeDefManager *ndef){}

inline void propagateSunlight(MMVManip *vm, const VoxelArea &a,
		bool inexistent_top_provides_sunlight, const NodeDefManager *ndef){}

} // namespace voxalgo
