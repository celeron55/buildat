// A shim, not Luanti's: see README.txt.
//
// What a mapgen uses of Luanti's Map is one class: MMVManip, the
// VoxelManipulator a generated chunk is written into. Luanti's reads the
// map into it and blits it back afterwards; here the volume is handed over
// by worldgen and translated after, so both of those are nothing to do.
//
// Map itself is never dereferenced by the mapgen -- it is passed around as
// a pointer and handed to the MMVManip -- so it stays a declared type.
#ifndef LUANTI_SHIM_MAP_H
#define LUANTI_SHIM_MAP_H
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

	// Luanti reads the map into the manipulator here, block by block, and
	// clears the "no data" flag of everything it read. There is no map on
	// this side -- what generates is handed the area it is for -- so this
	// is the same thing over an empty world: every voxel of the area is
	// "ignore" and is data, which is what makes a mapgen's writes stick.
	void initialEmerge(v3s16 blockpos_min, v3s16 blockpos_max,
			bool load_if_inexistent = true)
	{
		emergeAll();
	}

	// The same over whatever area has been added, which is what this
	// build's generator calls instead
	void emergeAll()
	{
		const s32 volume = m_area.getVolume();
		for(s32 i = 0; i < volume; i++){
			m_data[i] = MapNode(CONTENT_IGNORE);
			m_flags[i] = 0;
		}
	}

	// And writes it back here, which is the translation into a voxelworld
	// volume and happens outside the mapgen.
	void blitBackAll(std::map<v3s16, MapBlock*> *modified_blocks,
			bool overwrite_generated = true) const {}

	bool m_is_dirty = false;

protected:
	Map *m_map = nullptr;
};

#endif
