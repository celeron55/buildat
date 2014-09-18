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
				const std::string &in_path, const std::string &out_path) = 0;

		virtual void* construct(const char *name, interface::Server *server) = 0;

		virtual void unload(const std::string &module_name) = 0;

		std::vector<std::string> include_directories;
		std::vector<std::string> library_directories;
	};

	Compiler* createCompiler();
};
