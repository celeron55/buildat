// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include "ports/windows_minimal.h"

namespace interface {
namespace fs {

uint64_t file_size(const ss_ &path)
{
	WIN32_FILE_ATTRIBUTE_DATA data;
	if(!GetFileAttributesEx(path.c_str(), GetFileExInfoStandard, &data))
		return 0;
	if(data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
		return 0;
	ULARGE_INTEGER u;
	u.LowPart = data.nFileSizeLow;
	u.HighPart = data.nFileSizeHigh;
	return u.QuadPart;
}

}
}
// vim: set noet ts=4 sw=4:
