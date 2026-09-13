// A shim, not Luanti's: see README.txt.
#include "mapnode.h"
#include "log.h"
#include <istream>

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
