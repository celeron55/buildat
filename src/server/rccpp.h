#pragma once
#include "core/types.h"

namespace rccpp
{
	struct Compiler {
		virtual ~Compiler(){}

		virtual void build(const std::string &module_name,
				const std::string &in_path, const std::string &out_path) = 0;
		
		virtual void *construct(const char *name) = 0;
		
		std::vector<std::string> include_directories;
		std::vector<std::string> library_directories;
	};

	Compiler* createCompiler();
};
