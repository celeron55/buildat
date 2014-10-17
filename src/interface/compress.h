// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	void compress_zlib(const ss_ &data_in, std::ostream &os, int level = 6);
	void decompress_zlib(std::istream &is, std::ostream &os);
}
// vim: set noet ts=4 sw=4:
