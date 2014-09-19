// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	struct Filesystem
	{
		virtual ~Filesystem(){}

		struct Node {
			ss_ name;
			bool is_directory;
		};

		virtual sv_<Node> list_directory(const ss_ &path) = 0;

		virtual bool create_directories(const ss_ &path) = 0;
	};

	Filesystem* getGlobalFilesystem();
}
