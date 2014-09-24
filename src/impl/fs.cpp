// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <c55/filesys.h>
#include <c55/string_util.h>
#ifdef _WIN32
#define _WIN32_WINNT 0x0501
#include <windows.h>
#else
#include <unistd.h>
#endif

namespace interface {

bool Filesystem::check_file_extension(const char *path, const char *ext)
{
	return c55fs::checkFileExtension(path, ext);
}

ss_ Filesystem::strip_file_extension(const ss_ &path)
{
	return c55fs::stripFileExtension(path);
}

ss_ Filesystem::strip_file_name(const ss_ &path)
{
	return c55fs::stripFilename(path);
}

struct CFilesystem : public Filesystem
{
	sv_<Node> list_directory(const ss_ &path)
	{
		sv_<Node> result;
		auto list = c55fs::GetDirListing(path);
		for(auto n2 : list){
			Node n;
			n.name = n2.name;
			n.is_directory = n2.dir;
			result.push_back(n);
		}
		return result;
	}
	bool create_directories(const ss_ &path)
	{
		return c55fs::CreateAllDirs(path);
	}
	ss_ get_cwd()
	{
		char path[10000];
#ifdef _WIN32
		GetCurrentDirectory(path, 10000);
#else
		getcwd(path, 10000);
#endif
		return path;
	}
	ss_ get_absolute_path(const ss_ &path0)
	{
		ss_ path = c55::trim(path0);
#ifdef _WIN32
		if(path.size() >= 1 && (path[0] == '/' || path[0] == '\\'))
			return path;
		if(path.size() >= 2 && path[2] == ':')
			return path;
		return get_cwd()+"/"+path;
#else
		if(path.size() >= 1 && path[0] == '/')
			return path;
		return get_cwd()+"/"+path;
#endif
	}
};

Filesystem* getGlobalFilesystem()
{
	static CFilesystem fs;
	return &fs;
}

}
