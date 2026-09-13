// A shim, not Luanti's: see README.txt.
#include "mapnode.h"
#include "log.h"
#include <istream>

// simplified: only facedir, which is the one a schematic's rotation
// actually turns in devtest and in most games. Luanti also turns
// wallmounted, degrotate and the coloured kinds; the upgrade path is its
// own mapnode.cpp, which is not vendored because this file is a shim.
void MapNode::rotateAlongYAxis(const NodeDefManager *nodemgr, Rotation rot)
{
	// The four facedirs that stand upright, in Luanti's own order
	static const u8 rotate_facedir[4] = {0, 1, 2, 3};
	if(rot == ROTATE_RAND)
		return;
	const u8 turns = (u8)rot;
	if(param2 < 4){
		param2 = rotate_facedir[(param2 + turns) & 3];
	} else {
		// A facedir that is not upright keeps the face it is on and turns
		// around it, which is four values per face
		const u8 face = param2 / 4;
		const u8 dir = param2 % 4;
		param2 = (u8)(face * 4 + ((dir + turns) & 3));
	}
}

std::string MapNode::serializeBulk(int version, const MapNode *nodes,
		u32 nodecount, u8 content_width, u8 params_width)
{
	warningstream<<"A block of nodes is not serialized by this build"
			<<std::endl;
	return std::string();
}

// simplified: with a schematic file unread, nothing arrives here. Luanti's
// own is in its mapnode.cpp, which is not vendored because mapnode.h here
// is a shim; the two would have to land together.
void MapNode::deSerializeBulk(std::istream &is, int version, MapNode *nodes,
		u32 nodecount, u8 content_width, u8 params_width)
{
	warningstream<<"A block of nodes is not deserialized by this build"
			<<std::endl;
	for(u32 i = 0; i < nodecount; i++)
		nodes[i] = MapNode(CONTENT_IGNORE);
}
