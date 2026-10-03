// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// interface/file_watch.h in the web client ([WEB_CLIENT]): its files are the
// bundle's and never change under it, so nothing is watched.
#include "interface/file_watch.h"

namespace interface {

struct CFileWatch: FileWatch
{
	void add(const ss_ &path, std::function<void(const ss_&path)> cb){}
	sv_<int> get_fds(){ return {}; }
	void report_fd(int fd){}
	void update(){}
};

FileWatch* createFileWatch()
{
	return new CFileWatch();
}

}
// vim: set noet ts=4 sw=4:
