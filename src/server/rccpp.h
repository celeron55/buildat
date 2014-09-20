// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface {
	struct Server;
}

namespace rccpp
{
	struct Compiler {
		virtual ~Compiler(){}

		virtual bool build(const std::string &module_name,
				const std::string &in_path, const std::string &out_path,
				const ss_ &extra_cxxflags="", const ss_ &extra_ldflags="") = 0;

		virtual void* construct(const char *name, interface::Server *server) = 0;

		virtual void unload(const std::string &module_name) = 0;

		std::vector<std::string> include_directories;
		std::vector<std::string> library_directories;
	};

	Compiler* createCompiler(const ss_ &compiler_command);
};
