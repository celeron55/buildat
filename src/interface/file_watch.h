#pragma once
#include "core/types.h"
#include <functional>

namespace interface
{
	struct FileWatch
	{
		virtual ~FileWatch(){}

		// Used on Linux; no-op on Windows
		virtual sv_<int> get_fds() = 0;
		virtual void report_fd(int fd) = 0;

		// Used on Windows; no-op on Linux
		virtual void update() = 0;
	};

	// cb is called at either report_fd() or update().
	FileWatch* createFileWatch(
			const sv_<ss_> &paths, std::function<void()> cb);
}
