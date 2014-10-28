// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "server/config.h"
#include "core/log.h"
#include "interface/fs.h"
#include "interface/process.h"
#include <fstream>
#define MODULE "config"

namespace server {

static bool check_file_readable(const ss_ &path)
{
	std::ifstream ifs(path);
	bool readable = ifs.good();
	if(!readable)
		log_e(MODULE, "File is not readable: \"%s\"", cs(path));
	else
		log_v(MODULE, "File is readable: \"%s\"", cs(path));
	return readable;
}

static bool check_file_writable(const ss_ &path)
{
	std::ofstream ofs(path);
	bool writable = ofs.good();
	if(!writable)
		log_e(MODULE, "File is not writable: \"%s\"", cs(path));
	else
		log_v(MODULE, "File is writable: \"%s\"", cs(path));
	return writable;
}

static bool check_runnable(const ss_ &command)
{
	int exit_status = interface::process::shell_exec(command);
	if(exit_status != 0){
		log_e(MODULE, "Command failed: \"%s\"", cs(command));
		return false;
	} else {
		log_v(MODULE, "Command succeeded: \"%s\"", cs(command));
		return true;
	}
}

Config::Config()
{
	set_default("rccpp_build_path", "../cache/rccpp_build");
	set_default("interface_path", "../src/interface");
	set_default("share_path", "..");
	set_default("urho3d_path", "../../Urho3D");
	set_default("compiler_command", "c++");
	set_default("skip_compiling_modules", json::object());
}

bool Config::check_paths()
{
	ss_ rccpp_build_path = get<ss_>("rccpp_build_path");
	ss_ interface_path = get<ss_>("interface_path");
	ss_ share_path = get<ss_>("share_path");
	ss_ urho3d_path = get<ss_>("urho3d_path");
	ss_ compiler_command = get<ss_>("compiler_command");

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

	if(!check_file_readable(urho3d_path +
			"/Bin/CoreData/Shaders/GLSL/Basic.glsl")){
		log_e(MODULE, "Urho3D doesn't seem to exist in urho3d_path=\"%s\"",
				cs(urho3d_path));
		fail = true;
	}

	auto *fs = interface::getGlobalFilesystem();
	fs->create_directories(rccpp_build_path);
	if(!check_file_writable(rccpp_build_path+"/write.test")){
		log_e(MODULE, "Cannot write into rccpp_build_path=\"%s\"",
				cs(rccpp_build_path));
		fail = true;
	}

	ss_ test_command = compiler_command+" --version";
	if(!check_runnable(test_command)){
		log_e(MODULE, "Cannot run compiler with compiler_command=\"%s\"",
				cs(compiler_command));
		fail = true;
	}

	return !fail;
}

}
// vim: set noet ts=4 sw=4:
