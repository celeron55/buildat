// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace server
{
	struct Config
	{
		ss_ rccpp_build_path = "../cache/rccpp_build";
		ss_ interface_path = "../src/interface";
		ss_ share_path = "..";
		ss_ urho3d_path = "../../Urho3D";
		ss_ compiler_command = "c++";
		set_<ss_> skip_compiling_modules;

		bool check_paths();
	};
}

// vim: set noet ts=4 sw=4:
