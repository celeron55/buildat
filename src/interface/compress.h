// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	// What a decompressor writes at most, unless its caller says otherwise:
	// past it is an exception. Compressed data comes from servers, saves,
	// zips and imported worlds, and a few kilobytes of it inflated without
	// end ([SECURITY_RUN_1]). The packet ceiling's size.
	static const size_t DECOMPRESS_MAX = 256 * 1024 * 1024;

	void compress_zlib(const ss_ &data_in, std::ostream &os, int level = 6);
	void decompress_zlib(std::istream &is, std::ostream &os,
			size_t max_out = DECOMPRESS_MAX);

	// The same deflate stream without zlib's header and checksum around it,
	// which is Luanti's "raw_deflate" and what core.compress() calls it
	void compress_deflate_raw(const ss_ &data_in, std::ostream &os,
			int level = 6);
	void decompress_deflate_raw(std::istream &is, std::ostream &os,
			size_t max_out = DECOMPRESS_MAX);

	void compress_zstd(const ss_ &data_in, std::ostream &os, int level = 3);
	// Decompresses the one zstd frame at the front of data_in and returns how
	// many of its bytes that frame took. Concatenated frames are read by
	// calling this again from where the last one ended, which is what a Luanti
	// mapblock at serialization version 28 needs.
	size_t decompress_zstd(const ss_ &data_in, std::ostream &os,
			size_t max_out = DECOMPRESS_MAX);
	// The same frame straight into a buffer of a size that is already known,
	// which is what reading a chunk back in has: no stream object, no
	// scratch buffer and no copy on the way out. Returns how many bytes came
	// out, and throws if the frame does not fit in what was given.
	size_t decompress_zstd(const ss_ &data_in, uint8_t *out, size_t out_size);
	// The size the frame at the front of data_in says it decompresses to
	// (compress_zstd writes it), or -1 when it says none: what a buffer for
	// the one above is checked against before it is allocated
	int64_t zstd_frame_size(const ss_ &data_in);
}
// vim: set noet ts=4 sw=4:
