// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/file_watch.h"
#include "core/log.h"
#include <cstring>
#define MODULE "__filewatch"

namespace interface {

struct CFileWatch: FileWatch
{
	CFileWatch()
	{
		log_e(MODULE, "CFileWatch not implemented");
	}

	~CFileWatch()
	{
	}

	void add(const ss_ &path, std::function<void(const ss_ &path)> cb)
	{
		log_e(MODULE, "CFileWatch::add() not implemented");
	}

	// Used on Linux; no-op on Windows
	sv_<int> get_fds()
	{
		return {};
	}
	void report_fd(int fd)
	{
	}

	// Used on Windows; no-op on Linux
	void update()
	{
		log_e(MODULE, "CFileWatch::update() not implemented");
	}
};

FileWatch* createFileWatch()
{
	return new CFileWatch();
}

}
