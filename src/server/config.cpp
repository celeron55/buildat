// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "server/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include <fstream>
#define MODULE "config"

namespace server {

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

bool Config::check_paths()
{
	bool fail = false;

	if(!check_file_readable(share_path+"/builtin/network/network.cpp")){
		log_e(MODULE, "Static files don't seem to exist in share_path=\"%s\"",
				cs(share_path));
		fail = true;
	}

	if(!check_file_readable(interface_path+"/event.h")){
		log_e(MODULE, "Static files don't seem to exist in interface_path=\"%s\"",
				cs(interface_path));
		fail = true;
	}

	auto *fs = interface::getGlobalFilesystem();
	fs->create_directories(rccpp_build_path);
	if(!check_file_writable(rccpp_build_path+"/write.test")){
		log_e(MODULE, "Cannot write into rccpp_build_path=\"%s\"",
				cs(rccpp_build_path));
		fail = true;
	}

	return !fail;
}

}

