// A shim, not Luanti's: see README.txt.
#include "mapnode.h"
#include "log.h"
#include "exceptions.h"
#include <istream>
#include <string>

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

// Luanti's own, from its mapnode.cpp: the three fields are three arrays one
// after another rather than a node at a time, which is what a schematic file
// holds and what compresses well. A schematic is always content_width 2 and
// params_width 2; the one-byte form is Luanti's older mapblocks and is read
// because the code is the same size either way.
std::string MapNode::serializeBulk(int version, const MapNode *nodes,
		u32 nodecount, u8 content_width, u8 params_width)
{
	if(content_width != 2 || params_width != 2)
		throw SerializationError("serializeBulk: unsupported widths");
	std::string databuf(nodecount * (content_width + params_width), '\0');
	u8 *p = (u8*)&databuf[0];
	for(u32 i = 0; i < nodecount; i++){
		const u16 c = nodes[i].param0;
		p[i * 2] = (u8)(c >> 8);
		p[i * 2 + 1] = (u8)(c & 0xff);
	}
	const u32 start1 = content_width * nodecount;
	for(u32 i = 0; i < nodecount; i++)
		p[start1 + i] = nodes[i].param1;
	const u32 start2 = (content_width + 1) * nodecount;
	for(u32 i = 0; i < nodecount; i++)
		p[start2 + i] = nodes[i].param2;
	return databuf;
}

void MapNode::deSerializeBulk(std::istream &is, int version, MapNode *nodes,
		u32 nodecount, u8 content_width, u8 params_width)
{
	if(version < 22 || (content_width != 1 && content_width != 2) ||
			params_width != 2)
		throw SerializationError("deSerializeBulk: unsupported widths");
	const u32 len = nodecount * (content_width + params_width);
	std::string databuf(len, '\0');
	is.read(&databuf[0], len);
	if((u32)is.gcount() != len)
		throw SerializationError("deSerializeBulk: the data ran out");
	const u8 *p = (const u8*)databuf.data();
	if(content_width == 1){
		for(u32 i = 0; i < nodecount; i++)
			nodes[i].param0 = p[i];
	} else {
		for(u32 i = 0; i < nodecount; i++)
			nodes[i].param0 = (u16)((p[i * 2] << 8) | p[i * 2 + 1]);
	}
	const u32 start1 = content_width * nodecount;
	for(u32 i = 0; i < nodecount; i++)
		nodes[i].param1 = p[start1 + i];
	const u32 start2 = (content_width + 1) * nodecount;
	for(u32 i = 0; i < nodecount; i++){
		nodes[i].param2 = p[start2 + i];
		// The one-byte form keeps the top of the content id in param2's
		// high nibble, which is how Luanti's old mapblocks reached past 255
		if(content_width == 1 && nodes[i].param0 > 0x7f){
			nodes[i].param0 <<= 4;
			nodes[i].param0 |= (nodes[i].param2 & 0xf0) >> 4;
			nodes[i].param2 &= 0x0f;
		}
	}
}
