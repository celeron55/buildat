// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace fs
	{
		struct Node {
			ss_ name;
			bool is_directory;
		};

		sv_<Node> list_directory(const ss_ &path);

		bool create_directories(const ss_ &path);

		ss_ get_cwd();

		ss_ get_absolute_path(const ss_ &path);

		bool path_exists(const ss_ &path);

		// "image.png", "png" -> true
		bool check_file_extension(const char *path, const char *ext);
		ss_ strip_file_extension(const ss_ &path);
		ss_ strip_file_name(const ss_ &path);
	};
}
// vim: set noet ts=4 sw=4:
