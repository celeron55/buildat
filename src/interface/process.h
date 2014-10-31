#pragma once
#include "core/types.h"

namespace interface
{
	namespace process
	{
		// I have no idea why ss_ doesn't work here in mingw-w64

		std::string get_environment_variable(const std::string &name);

		struct ExecOptions {
			sm_<ss_, ss_> env;
		};

		int shell_exec(const std::string &command,
				const ExecOptions &opts = ExecOptions());
	}
}
// vim: set noet ts=4 sw=4:
