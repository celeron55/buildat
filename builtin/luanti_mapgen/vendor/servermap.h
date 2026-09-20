// A shim, not Luanti's: see README.txt.
//
// Schematic::placeOnMap() puts a schematic straight into a running map,
// which is what a mod's core.place_schematic() does. Nothing in this build
// calls it -- a mapgen places its decorations into the VoxelManipulator it
// is generating, not into the map -- so this is the smallest ServerMap that
// lets the file compile.
//
// When a mod's place_schematic() is wired up, this is where it lands: the
// map here is voxelworld, and the module on the other side of
// luanti_mapgen/api.h is what can reach it.
#pragma once
#include "map.h"
#include "irrlichttypes_bloated.h"
#include <map>
#include <set>

enum MapEditEventType {
	MEET_OTHER,
	MEET_ADDNODE,
	MEET_REMOVENODE,
	MEET_SWAPNODE,
	MEET_BLOCK_POPPED,
};

struct MapEditEvent
{
	MapEditEventType type = MEET_OTHER;
	std::set<v3s16> modified_blocks;

	void setModifiedBlocks(const std::map<v3s16, MapBlock*> &blocks){
		for(const auto &pair : blocks)
			modified_blocks.insert(pair.first);
	}
};

class Map
{
public:
	virtual ~Map() = default;
	void dispatchEvent(const MapEditEvent &event){}
};

class ServerMap: public Map
{
};
