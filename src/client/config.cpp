// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "client/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include "boot/autodetect.h"
#include <fstream>
#define MODULE "config"

namespace client {

Config::Config()
{
	// Paths are filled in by autodetection
	set_default("share_path", "");
	set_default("cache_path", "");
	set_default("urho3d_path", "");

	set_default("server_address", "");
	set_default("boot_to_menu", false);
	set_default("menu_extension_name", "__menu");
}

bool Config::check_paths()
{
	bool ok = boot::autodetect::check_client_paths(*this, false);
	if(!ok)
		boot::autodetect::check_client_paths(*this, true);
	return ok;
}

}
// vim: set noet ts=4 sw=4:
