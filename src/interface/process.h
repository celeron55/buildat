#pragma once
#include "core/types.h"

namespace interface
{
	namespace process
	{
		// I have no idea why ss_ doesn't work here in mingw-w64
		int shell_exec(const std::string &command);
	}
}
// vim: set noet ts=4 sw=4:
