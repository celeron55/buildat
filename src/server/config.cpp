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
	set_default("cache_path", "");
	set_default("user_path", "");
	set_default("urho3d_path", "");
	set_default("compiler_command", "");
	set_default("network_address", "any4");
	set_default("network_port", "29500");

	set_default("skip_compiling_modules", json::object());

	// Whether client_file watches the files it serves and pushes an updated
	// one to connected clients. That is what makes a game's client Lua
	// editable while a client is running, and it is what the feature is for
	// -- but it is an inotify watch per directory, which does not scale to a
	// game whose media is a few hundred megabytes, and it is not something a
	// production server wants at all. On for development, off otherwise.
	set_default("watch_client_files", false);
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
