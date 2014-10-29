// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <c55/filesys.h>
#include <c55/string_util.h>
#ifdef _WIN32
	#include "ports/windows_minimal.h"
#else
	#include <unistd.h>
#endif

namespace interface {
namespace fs {

bool check_file_extension(const char *path, const char *ext)
{
	return c55fs::checkFileExtension(path, ext);
}

ss_ strip_file_extension(const ss_ &path)
{
	return c55fs::stripFileExtension(path);
}

ss_ strip_file_name(const ss_ &path)
{
	return c55fs::stripFilename(path);
}

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
	return c55fs::CreateAllDirs(get_absolute_path(path));
}
ss_ get_cwd()
{
	char path[10000];
#ifdef _WIN32
	GetCurrentDirectory(10000, path);
#else
	getcwd(path, 10000);
#endif
	return path;
}
// Doesn't collapse .. and .
ss_ get_basic_absolute_path(const ss_ &path0)
{
	ss_ path = c55::trim(path0);
#ifdef _WIN32
	if(path.size() >= 2 && path.substr(0, 2) == "\\\\")
		return path;
	if(path.size() >= 1 && (path[0] == '/' || path[0] == '\\'))
		return path;
	if(path.size() >= 2 && path[1] == ':')
		return path;
	return get_cwd()+"/"+path;
#else
	if(path.size() >= 1 && path[0] == '/')
		return path;
	return get_cwd()+"/"+path;
#endif
}
// Collapses .. and .
ss_ get_absolute_path(const ss_ &path0)
{
	ss_ path = get_basic_absolute_path(path0);
	for(size_t i = 0; i<path.size(); i++){
		if(path[i] == '\\')
			path[i] = '/';
	}
	sv_<ss_> path_parts;
	c55::Strfnd f(path);
	for(;;){
		if(f.atend())
			break;
		ss_ part = f.next("/");
		if(part == ""){
			// Nop
		} else if(part == "."){
			// Nop
		} else if(part == ".."){
			path_parts.pop_back();
		} else {
			path_parts.push_back(part);
		}
	}
	ss_ path2;
	for(const ss_ &part : path_parts){
		path2 += "/" + part;
	}
#ifdef _WIN32
	if(path.size() >= 2 && path.substr(0, 2) == "//"){
		// Preserve network path
		path2 = "\\\\"+path2.substr(1);
	} else {
		// Path will be in a silly format like "/Z:/home/"
		path2 = path2.substr(1);
	}
#endif
	return path2;
}

bool path_exists(const ss_ &path)
{
	return c55fs::PathExists(path);
}

}}
// vim: set noet ts=4 sw=4:
