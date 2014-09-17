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
	};

	Filesystem* getGlobalFilesystem();
}
