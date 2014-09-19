// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#ifndef FILESYS_HEADER
#define FILESYS_HEADER

#include <string>
#include <vector>

#ifdef _WIN32 // WINDOWS
#define DIR_DELIM "\\"
#define DIR_DELIM_C '\\'
#else // POSIX
#define DIR_DELIM "/"
#define DIR_DELIM_C '/'
#endif

namespace c55fs
{

/* "image.png", "png" -> true */
bool checkFileExtension(const char *path, const char *ext);
std::string stripFileExtension(const std::string &path);
std::string stripFilename(const std::string &path);

struct DirListNode
{
	std::string name;
	bool dir;
};

std::vector<DirListNode> GetDirListing(std::string path);

// Returns true if already exists
bool CreateDir(std::string path);

// Create all directories on the given path that don't already exist.
bool CreateAllDirs(std::string path);

bool PathExists(std::string path);

// Only pass full paths to this one. True on success.
// NOTE: The WIN32 version returns always true.
bool RecursiveDelete(std::string path);

// Only pass full paths to this one. True on success.
bool RecursiveDeleteContent(std::string path);

}//fs

#endif

