// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	struct ModuleDependency
	{
		ss_ module;
		bool optional = false;
	};

	struct ModuleMeta
	{
		bool disable_cpp = false;
		ss_ cxxflags;
		ss_ ldflags;
		ss_ cxxflags_linux;
		ss_ ldflags_linux;
		ss_ cxxflags_windows;
		ss_ ldflags_windows;
		sv_<ModuleDependency> dependencies;
		sv_<ModuleDependency> reverse_dependencies;
	};

	struct ModuleInfo
	{
		ss_ name;
		ss_ path;
		ModuleMeta meta;
	};
}
// vim: set noet ts=4 sw=4:
