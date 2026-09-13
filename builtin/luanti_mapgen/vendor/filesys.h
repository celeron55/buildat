// A shim, not Luanti's: see README.txt.
//
// A schematic file is opened through this. buildat has its own filesystem
// layer (interface/fs.h) and this answers the little of Luanti's that the
// schematic reader uses.
#pragma once
#include "irrlichttypes.h"
#include <string>
#include <fstream>

namespace fs {

inline bool PathExists(const std::string &path)
{
	std::ifstream ifs(path.c_str());
	return ifs.good();
}

inline bool IsFile(const std::string &path){ return PathExists(path); }

inline bool safeWriteToFile(const std::string &path,
		const std::string &content)
{
	std::ofstream ofs(path.c_str(), std::ios::binary);
	if(!ofs.good())
		return false;
	ofs<<content;
	return ofs.good();
}

} // namespace fs

// An input stream on a file, which is how a schematic is read. Luanti's
// returns the stream; a caller checks it with good().
inline std::ifstream open_ifstream(const std::string &path,
		bool warn_on_fail = true)
{
	return std::ifstream(path.c_str(), std::ios::binary);
}
