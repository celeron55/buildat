// A shim, not Luanti's: see README.txt and serialization.h.
#include "serialization.h"
#include "log.h"

// simplified: a .mts file's node data stays compressed and unread. Luanti
// wrote it with zlib before its version 29 and zstd after; buildat has
// both, and what is missing to finish this is MapNode::serializeBulk, which
// is in Luanti's mapnode.cpp and a shim here. A schematic a mod defines in
// Lua does not come through here at all.
void compress(const u8 *data, size_t len, std::ostream &os, u8 version,
		int level)
{
	warningstream<<"A schematic file is not written by this build"
			<<std::endl;
}

void compress(const std::string &data, std::ostream &os, u8 version,
		int level)
{
	compress((const u8*)data.c_str(), data.size(), os, version, level);
}

void decompress(std::istream &is, std::ostream &os, u8 version)
{
	warningstream<<"A schematic file is not read by this build"<<std::endl;
}
