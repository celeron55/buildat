// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace core {
	struct Config;
}

namespace server
{
	// [PROCESS_SANDBOX]: the server confines itself before it loads an
	// app, so an app from an untrusted source and a malicious client reach
	// nothing of the user's beyond what the app keeps. Called once, from
	// main(), with the paths settled and no thread started. Points the
	// config's cache_path and rccpp_build_path at the app's own cache
	// first.
	//
	// Linux: Landlock (the filesystem by an allow-list; abstract unix
	// sockets and signals scoped where the kernel has it) and seccomp
	// (no unix socket, no io_uring). Returns "" when the box is made, or
	// why not.
	//
	// Windows: an AppContainer per app and a job object. The process
	// started unboxed is a thin parent: it starts itself again in the box
	// (its own command line and --boxed), carries the child's output into its own log
	// and sets *exit_code to the child's; started --boxed, it checks it is
	// in its container. Elsewhere *exit_code is left alone.
	ss_ confine(core::Config &config, const ss_ &module_path,
			int *exit_code);

	// The app's name, as the server's get_app_id() takes it
	inline ss_ app_of(const ss_ &module_path)
	{
		ss_ app = module_path;
		while(!app.empty() && (app.back() == '/' || app.back() == '\\'))
			app.pop_back();
		const size_t sep = app.find_last_of("/\\");
		if(sep != ss_::npos)
			app = app.substr(sep + 1);
		if(app.empty() || app == "." || app == "..")
			app = "unnamed";
		return app;
	}
}
// vim: set noet ts=4 sw=4:
