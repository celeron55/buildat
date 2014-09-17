#include "interface/fs.h"
#include <c55/filesys.h>

namespace interface {

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
};

Filesystem* getGlobalFilesystem()
{
	static CFilesystem fs;
	return &fs;
}

}
