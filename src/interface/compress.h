// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	void compress_zlib(const ss_ &data_in, std::ostream &os, int level = 6);
	void decompress_zlib(std::istream &is, std::ostream &os);

	void compress_zstd(const ss_ &data_in, std::ostream &os, int level = 3);
	// Decompresses the one zstd frame at the front of data_in and returns how
	// many of its bytes that frame took. Concatenated frames are read by
	// calling this again from where the last one ended, which is what a Luanti
	// mapblock at serialization version 28 needs.
	size_t decompress_zstd(const ss_ &data_in, std::ostream &os);
}
// vim: set noet ts=4 sw=4:
