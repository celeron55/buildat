// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/file_watch.h"
#include "core/log.h"
#include <cstring>
#define MODULE "__filewatch"

namespace interface {

struct CMultiFileWatch: MultiFileWatch
{
	CMultiFileWatch()
	{
		log_e(MODULE, "CMultiFileWatch not implemented");
	}

	~CMultiFileWatch()
	{
	}

	void add(const ss_ &path, std::function<void(const ss_ &path)> cb)
	{
		log_e(MODULE, "CMultiFileWatch::add() not implemented");
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
		log_e(MODULE, "CMultiFileWatch::update() not implemented");
	}
};

MultiFileWatch* createMultiFileWatch()
{
	return new CMultiFileWatch();
}

}
