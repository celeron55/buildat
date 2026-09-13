// A shim, not Luanti's: see README.txt and serialization.h.
#include "serialization.h"
#include "log.h"
#include "interface/compress.h"
#include <sstream>

// What a .mts file's node data is wrapped in. Luanti wrote a mapblock with
// zlib before its serialization version 29 and with zstd after, and a
// schematic is pinned at 28 -- so this is zlib in practice and zstd is here
// because the version says which. buildat has both in interface/compress.h.
void compress(const u8 *data, size_t len, std::ostream &os, u8 version,
		int level)
{
	const ss_ in((const char*)data, len);
	if(version >= 29)
		interface::compress_zstd(in, os, level);
	else
		interface::compress_zlib(in, os, level);
}

void compress(const std::string &data, std::ostream &os, u8 version,
		int level)
{
	compress((const u8*)data.c_str(), data.size(), os, version, level);
}

void decompress(std::istream &is, std::ostream &os, u8 version)
{
	if(version >= 29){
		// zstd takes the bytes rather than the stream, and answers how many
		// of them the frame took, so that what follows it can still be read
		std::ostringstream rest;
		rest<<is.rdbuf();
		const ss_ data = rest.str();
		const size_t used = interface::decompress_zstd(data, os);
		// Put back what was not part of the frame
		if(used < data.size()){
			for(size_t i = data.size(); i > used; i--)
				is.putback(data[i - 1]);
		}
		return;
	}
	interface::decompress_zlib(is, os);
}
