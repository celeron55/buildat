// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	// TODO: Get some sanity into this; what's up with the virtual methods?
	struct Filesystem
	{
		virtual ~Filesystem(){}

		struct Node {
			ss_ name;
			bool is_directory;
		};

		virtual sv_<Node> list_directory(const ss_ &path) = 0;

		virtual bool create_directories(const ss_ &path) = 0;

		virtual ss_ get_cwd() = 0;

		virtual ss_ get_absolute_path(const ss_ &path) = 0;

		// "image.png", "png" -> true
		static bool check_file_extension(const char *path, const char *ext);
		static ss_ strip_file_extension(const ss_ &path);
		static ss_ strip_file_name(const ss_ &path);
	};

	Filesystem* getGlobalFilesystem();
}
