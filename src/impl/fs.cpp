// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/fs.h"
#include <c55/filesys.h>
#include <c55/string_util.h>
#include <fstream>
#include "core/log.h"
#define MODULE "fs"
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
			// A path that climbs past the root stays at the root, which is
			// what every filesystem answers and what keeps this from
			// walking off the front of the list
			if(!path_parts.empty())
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

static bool is_inside_path_unchecked(const ss_ &path0, const ss_ &dir0)
{
	ss_ path = get_absolute_path(path0);
	ss_ dir = get_absolute_path(dir0);
	if(dir.empty())
		return false;
	// A directory of its own counts as inside itself; anything else has to
	// be under it and not merely start with its name, or "/cache_evil"
	// would pass for "/cache"
	if(path == dir)
		return true;
	if(path.size() <= dir.size())
		return false;
	if(path.substr(0, dir.size()) != dir)
		return false;
	return path[dir.size()] == '/' || dir[dir.size() - 1] == '/';
}

// The one runnable check this leaves behind. It decides what sandboxed code
// is allowed to write to, so what it is checked for is the paths that look
// like they are inside and are not.
static bool is_inside_path_self_test()
{
	struct Case { const char *path; const char *dir; bool want; };
	static const Case cases[] = {
		{"/cache/a", "/cache", true},
		{"/cache", "/cache", true},
		{"/cache/", "/cache", true},
		{"/cache/a/b/c.png", "/cache", true},
		{"/cache/a/../b", "/cache", true},
		{"/cache/a", "/cache/", true},
		{"/cache_evil/a", "/cache", false},
		{"/cacheevil", "/cache", false},
		{"/cache/../etc/passwd", "/cache", false},
		{"/cache/a/../../etc", "/cache", false},
		{"/etc/passwd", "/cache", false},
		{"/", "/cache", false},
		{"/cache/a", "", false},
	};
	for(const Case &c : cases){
		bool got = is_inside_path_unchecked(c.path, c.dir);
		if(got != c.want){
			log_w(MODULE, "is_inside_path(\"%s\", \"%s\") is %s and should "
					"be %s", c.path, c.dir, got ? "true" : "false",
					c.want ? "true" : "false");
			return false;
		}
	}
	return true;
}

bool is_inside_path(const ss_ &path0, const ss_ &dir0)
{
	// Cheap, once per process, and every caller passes through here
	static const bool tested = is_inside_path_self_test();
	if(!tested)
		return false; // Nothing is inside anything if the rule is broken
	return is_inside_path_unchecked(path0, dir0);
}

bool copy_file(const ss_ &from, const ss_ &to)
{
	if(from == to)
		return true;
	std::ifstream in(from.c_str(), std::ios::binary);
	if(!in)
		return false;
	std::ofstream out(to.c_str(), std::ios::binary);
	if(!out)
		return false;
	out << in.rdbuf();
	return (bool)out;
}

uint64_t directory_tree_size(const ss_ &path)
{
	uint64_t total = 0;
	for(const Node &n : list_directory(path)){
		ss_ child = path + "/" + n.name;
		if(n.is_directory)
			total += directory_tree_size(child);
		else
			total += file_size(child);
	}
	return total;
}

}
}
// vim: set noet ts=4 sw=4:
