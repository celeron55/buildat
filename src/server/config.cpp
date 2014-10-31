// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "server/config.h"
#include "core/log.h"
#include "boot/autodetect.h"
#include <fstream>
#define MODULE "config"

namespace server {

Config::Config()
{
	// Paths are filled in by autodetection
	set_default("rccpp_build_path", "");
	set_default("interface_path", "");
	set_default("share_path", "");
	set_default("urho3d_path", "");
	set_default("compiler_command", "");

	set_default("skip_compiling_modules", json::object());
}

bool Config::check_paths()
{
	bool ok = boot::autodetect::check_server_paths(*this, false);
	if(!ok)
		boot::autodetect::check_server_paths(*this, true);
	return ok;
}

}
// vim: set noet ts=4 sw=4:
