// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "boot/autodetect.h"
#include "core/log.h"
#include "interface/os.h"
#include "interface/fs.h"
#include "interface/process.h"
#include "interface/mutex.h"
#include <fstream>
#define MODULE "boot"

namespace boot {
namespace autodetect {

// Filesystem helpers

static bool check_file_readable(const ss_ &path)
{
	std::ifstream ifs(path);
	bool readable = ifs.good();
	if(!readable)
		log_d(MODULE, "File is not readable: [%s]", cs(path));
	else
		log_d(MODULE, "File is readable: [%s]", cs(path));
	return readable;
}

static bool check_file_writable(const ss_ &path)
{
	std::ofstream ofs(path);
	bool writable = ofs.good();
	if(!writable)
		log_d(MODULE, "File is not writable: [%s]", cs(path));
	else
		log_d(MODULE, "File is writable: [%s]", cs(path));
	return writable;
}

static set_<ss_> m_valid_commands;
static interface::Mutex m_valid_commands_mutex;

static bool check_runnable(const ss_ &command)
{
	interface::MutexScope ms(m_valid_commands_mutex);
	if(m_valid_commands.count(command))
		return true;

	int exit_status = interface::process::shell_exec(command);
	if(exit_status != 0){
		log_d(MODULE, "Command failed: [%s]", cs(command));
		return false;
	} else {
		log_d(MODULE, "Command succeeded: [%s]", cs(command));
		m_valid_commands.insert(command);
		return true;
	}
}

enum PathDefinitionType {PD_END, PD_READ, PD_WRITE, PD_RUN};
struct PathDefinition {
	PathDefinitionType type; // Type of check
	const char *path_name; // Name in configuration
	const char *default_subpath; // Default value is root + default_subpath
	const char *check_path; // Path to check under $path_name
	const char *description; // Description of this definition
};

static bool check_path(const core::Config &config, const PathDefinition &def,
		bool log_issues, bool enable_mkdir)
{
	ss_ base_path = config.get<ss_>(def.path_name);
	if(def.type == PD_READ){
		bool ok = check_file_readable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not found in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* File is not readable: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else if(def.type == PD_WRITE){
		// Create path
		if(enable_mkdir)
			interface::fs::create_directories(base_path);
		// Check path
		bool ok = check_file_writable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not writable in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* File is not writable: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else if(def.type == PD_RUN){
		bool ok = check_runnable(base_path + def.check_path);
		if(!ok && log_issues){
			log_e(MODULE, "%s not runnable in %s=[%s]",
					def.description, def.path_name, cs(base_path));
			log_e(MODULE, "* Command failed: [%s]",
					cs(base_path + def.check_path));
		}
		return ok;
	} else {
		throw Exception("Unknown PathDefinition::type "+itos(def.type));
	}
}

static bool check_paths(const core::Config &config, const PathDefinition *defs,
		bool log_issues)
{
	bool ok = true;
	const PathDefinition *def = defs;
	while(def->type != PD_END){
		// Don't create directories if something already failed
		bool enable_mkdir = ok;
		if(!check_path(config, *def, log_issues, enable_mkdir))
			ok = false;
		def++;
	}
	return ok;
}

static void set_default_subpaths(core::Config &config, const PathDefinition *defs,
		const ss_ &root)
{
	const PathDefinition *def = defs;
	while(def->type != PD_END){
		if(def->default_subpath[0] == '|') // Disables root
			config.set_default(def->path_name, &def->default_subpath[1]);
		else
			config.set_default(def->path_name, root + def->default_subpath);
		def++;
	}
}

// If not found, returns empty string and logs issues
static ss_ find_root(const sv_<ss_> &roots, const PathDefinition *defs,
		const char *description)
{
	log_d(MODULE, "Searching root: %s", description);
	// Try to find root
	for(const ss_ &root : roots)
	{
		log_d(MODULE, "Checking root [%s]", cs(root));
		core::Config config;
		set_default_subpaths(config, defs, root);
		if(check_paths(config, defs, false)){
			log_d(MODULE, "-> Root [%s] matches (%s)", cs(root), description);
			return root;
		}
	}
	// Not found; Log issues and return
	log_e(MODULE, "Could not find root: %s", description);
	for(const ss_ &root : roots)
	{
		log_e(MODULE, "Checked [%s]:", cs(root));
		core::Config config;
		set_default_subpaths(config, defs, root);
		check_paths(config, defs, true);
	}
	return "";
}

static bool detect_paths(core::Config &config, const sv_<ss_> &roots,
		const PathDefinition *defs, const char *description)
{
	ss_ root = find_root(roots, defs, description);
	if(root.empty()){
		log_w(MODULE, "Could not determine %s path (tried %s)",
				description, cs(roots));
		return false;
	}

	log_v(MODULE, "%s detected: [%s]", description, cs(root));
	set_default_subpaths(config, defs, root);
	return true;
}

// Common functions

static void generate_buildat_root_alternatives(sv_<ss_> &roots)
{
	// Use executable path to find root suggestions
	ss_ exe_path = interface::os::get_current_exe_path();
	ss_ exe_dir = interface::fs::strip_file_name(exe_path);
	ss_ root_path = exe_dir + "/..";
	root_path = interface::fs::get_absolute_path(root_path);
	roots.push_back(root_path);
	root_path = interface::fs::get_absolute_path(root_path+"/..");
	roots.push_back(root_path);

	//roots.push_back(".");
	//roots.push_back("..");
}

static void generate_urho3d_root_alternatives(sv_<ss_> &roots)
{
	sv_<ss_> buildat_roots;
	generate_buildat_root_alternatives(buildat_roots);

	for(const ss_ &buildat_root : buildat_roots){
		roots.push_back(buildat_root + "/Urho3D");
		roots.push_back(buildat_root + "/../Urho3D");
	}
}

// Server-only paths

PathDefinition server_paths[] = {
	{PD_READ, "share_path",
		"",
		"/builtin/network/network.cpp",
		"Static files"
	},
	{PD_READ, "interface_path",
		"/src/interface",
		"/event.h",
		"Interface files"
	},
	{PD_WRITE, "rccpp_build_path",
		"/cache/rccpp_build",
		"/write.test",
		"RCC++ build directory"
	},
	{PD_RUN, "compiler_command",
		"|c++",
		" --version",
		"Compiler command"
	},
	{PD_END,  "", "", "", ""},
};

static bool detect_buildat_server_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_buildat_root_alternatives(roots);
	return detect_paths(config, roots, server_paths, "Buildat server root");
}

// Client-only paths

PathDefinition client_paths[] = {
	{PD_READ, "share_path",
		"",
		"/client/init.lua",
		"Static files"
	},
	{PD_WRITE, "cache_path",
		"/cache",
		"/write.test",
		"Cache directory"
	},
	{PD_END,  "", "", "", ""},
};

static bool detect_buildat_client_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_buildat_root_alternatives(roots);
	return detect_paths(config, roots, client_paths, "Buildat client root");
}

// Server Urho3D paths

PathDefinition server_urho3d_paths[] = {
	{PD_READ, "urho3d_path",
		"",
		"/Bin/CoreData/Shaders/GLSL/Basic.glsl",
		"Urho3D path"
	},
	{PD_END,  "", "", "", ""},
};

static bool detect_server_urho3d_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_urho3d_root_alternatives(roots);
	return detect_paths(config, roots, server_urho3d_paths, "Server Urho3D root");
}

// Client Urho3D paths

PathDefinition client_urho3d_paths[] = {
	{PD_READ, "urho3d_path",
		"",
		"/Bin/CoreData/Shaders/GLSL/Basic.glsl",
		"Urho3D path"
	},
	{PD_END,  "", "", "", ""},
};

static bool detect_client_urho3d_paths(core::Config &config)
{
	sv_<ss_> roots;
	generate_urho3d_root_alternatives(roots);
	return detect_paths(config, roots, client_urho3d_paths, "Client Urho3D root");
}

// Public interface

bool check_server_paths(const core::Config &config, bool log_issues)
{
	bool ok = true;
	if(!check_paths(config, server_paths, log_issues))
		ok = false;
	if(!check_paths(config, server_urho3d_paths, log_issues))
		ok = false;
	return ok;
}

bool check_client_paths(const core::Config &config, bool log_issues)
{
	bool ok = true;
	if(!check_paths(config, client_paths, log_issues))
		ok = false;
	if(!check_paths(config, client_urho3d_paths, log_issues))
		ok = false;
	return ok;
}

bool detect_server_paths(core::Config &config)
{
	bool ok = true;

	if(!detect_buildat_server_paths(config))
		ok = false;
	if(!detect_server_urho3d_paths(config))
		ok = false;

	return ok;
}

bool detect_client_paths(core::Config &config)
{
	bool ok = true;

	if(!detect_buildat_client_paths(config))
		ok = false;
	if(!detect_client_urho3d_paths(config))
		ok = false;

	return ok;
}

}}
// vim: set noet ts=4 sw=4:
