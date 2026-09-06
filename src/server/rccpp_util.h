// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace server
{
	sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs);
	// extra is hashed along with the files, for things that change what the
	// build produces without being in any of them
	ss_ hash_files(const sv_<ss_> &paths, const ss_ &extra = "");
}
// vim: set noet ts=4 sw=4:
