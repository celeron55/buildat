// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace client
{
	struct Config
	{
		ss_ server_address;
		ss_ share_path = "..";
		ss_ cache_path = "../cache";
		ss_ urho3d_path = "../../Urho3D";
		bool boot_to_menu = false;
		ss_ menu_extension_name = "__menu";

		void make_paths_absolute();
		bool check_paths();
	};
}
// vim: set noet ts=4 sw=4:
