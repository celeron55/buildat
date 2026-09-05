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

		// Long-running child. Does not wait. path is the executable.
		struct Handle {
			intptr_t impl = 0;
			bool valid() const;
		};

		Handle start(const std::string &path, const sv_<ss_> &args);
		void terminate(Handle &h);
		bool is_running(const Handle &h);
	}
}
// vim: set noet ts=4 sw=4:
