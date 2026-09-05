// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <sys/stat.h>

namespace interface {
namespace fs {

uint64_t file_size(const ss_ &path)
{
	struct stat st;
	if(lstat(path.c_str(), &st) != 0)
		return 0;
	if(!S_ISREG(st.st_mode))
		return 0;
	return (uint64_t)st.st_size;
}

}
}
// vim: set noet ts=4 sw=4:
