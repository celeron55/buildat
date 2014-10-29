// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "client/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include <fstream>
#define MODULE "config"

namespace client {

static bool check_file_readable(const ss_ &path)
{
	std::ifstream ifs(path);
	bool readable = ifs.good();
	if(!readable)
		log_e(MODULE, "File is not readable: \"%s\"", cs(path));
	return readable;
}

static bool check_file_writable(const ss_ &path)
{
	std::ofstream ofs(path);
	bool writable = ofs.good();
	if(!writable)
		log_e(MODULE, "File is not writable: \"%s\"", cs(path));
	return writable;
}

void Config::make_paths_absolute()
{
	share_path = interface::fs::get_absolute_path(share_path);
	cache_path = interface::fs::get_absolute_path(cache_path);
	urho3d_path = interface::fs::get_absolute_path(urho3d_path);
}

bool Config::check_paths()
{
	bool fail = false;

	if(!check_file_readable(share_path+"/extensions/test/init.lua")){
		log_e(MODULE, "Static files don't seem to exist in share_path=\"%s\"",
				cs(share_path));
		fail = true;
	}
	else if(!check_file_readable(share_path+"/client/init.lua")){
		log_e(MODULE, "Static files don't seem to exist in share_path=\"%s\"",
				cs(share_path));
		fail = true;
	}

	if(!check_file_readable(urho3d_path +
			"/Bin/CoreData/Shaders/GLSL/Basic.glsl")){
		log_e(MODULE, "Urho3D doesn't seem to exist in urho3d_path=\"%s\"",
				cs(urho3d_path));
		fail = true;
	}

	if(!interface::fs::create_directories(cache_path)){
		log_e(MODULE, "Could not create directory \"%s\"", cs(cache_path));
		fail = true;
	}
	if(!check_file_writable(cache_path+"/write.test")){
		log_e(MODULE, "Cannot write into cache_path=\"%s\"", cs(cache_path));
		fail = true;
	}

	return !fail;
}

}
// vim: set noet ts=4 sw=4:
