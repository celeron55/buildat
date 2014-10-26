// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace server
{
	sv_<ss_> list_includes(const ss_ &path, const sv_<ss_> &include_dirs);
	ss_ hash_files(const sv_<ss_> &paths);
}
// vim: set noet ts=4 sw=4:
