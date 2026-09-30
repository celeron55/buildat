// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	// A zip archive read by its central directory ([CONTENTDB]): the two
	// methods a zip's entries are stored with -- stored, and the raw
	// deflate decompress_deflate_raw() reads. Anything else (encryption,
	// zip64, other methods) throws with the entry's name.
	struct ZipEntry {
		ss_ name; // as in the archive, '/' separated; a directory ends in '/'
		uint64_t size = 0; // uncompressed
	};
	sv_<ZipEntry> zip_list(const ss_ &zip_path);

	// Every entry under into_dir, directories made as needed. An entry
	// whose path would land outside into_dir ("../", an absolute path, a
	// drive letter) throws before anything is written. Returns the number
	// of files written.
	size_t zip_extract(const ss_ &zip_path, const ss_ &into_dir);
}
// vim: set noet ts=4 sw=4:
