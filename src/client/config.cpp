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
	set_default("root_path", "");
	set_default("user_path", "");
	set_default("urho3d_path", "");

	set_default("server_address", "");
	set_default("boot_to_menu", false);
	// The launch menu: local games, remote servers, and the extensions that
	// say they can be launched. See extensions/__menu.
	set_default("menu_extension_name", "__menu");
	// -a kind/name/id: one launch-grid action run on boot ([LAUNCH_GRID])
	set_default("launch_action", "");
	set_default("ui_scale", 0.0); // 0 = auto from short side / 1080
	// Where -L put the client's own log, kept so that a local server this
	// client starts can be given one beside it; see l_start_local_server()
	set_default("log_file", "");
	set_default("log_level_given", false);
	set_default("log_path", "");
	// Passed on to a local server this client starts, the way the log path
	// is: the server restarts a module when its source changes only if it
	// was asked to. See -R, and "reload_modules" in server/config.cpp.
	set_default("reload_modules", false);
	set_default("command_seq", "");
	set_default("command_seq_enabled", false);
	set_default("command_seq_stdin", false);
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
