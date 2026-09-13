// A shim, not Luanti's: see README.txt.
//
// What a mapgen uses of Luanti's Map is one class: MMVManip, the
// VoxelManipulator a generated chunk is written into. Luanti's reads the
// map into it and blits it back afterwards; here the volume is handed over
// by worldgen and translated after, so both of those are nothing to do.
//
// Map itself is never dereferenced by the mapgen -- it is passed around as
// a pointer and handed to the MMVManip -- so it stays a declared type.
#pragma once
#include "voxel.h"
#include "util/basic_macros.h"
#include <map>

class Map;
class MapBlock;

struct MapEditEvent;

class MMVManip: public VoxelManipulator
{
public:
	MMVManip(Map *map = nullptr): m_map(map){}
	~MMVManip() override = default;
	DISABLE_CLASS_COPY(MMVManip)

	// Luanti reads the map into the manipulator here. What generates in
	// this build is handed a volume that is already the area it is for.
	void initialEmerge(v3s16 blockpos_min, v3s16 blockpos_max,
			bool load_if_inexistent = true){}

	// And writes it back here, which is the translation into a voxelworld
	// volume and happens outside the mapgen.
	void blitBackAll(std::map<v3s16, MapBlock*> *modified_blocks,
			bool overwrite_generated = true) const {}

	bool m_is_dirty = false;

protected:
	Map *m_map = nullptr;
};
