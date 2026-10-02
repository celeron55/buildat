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
	ss_ confine(core::Config &config, const ss_ &module_path);
}
// vim: set noet ts=4 sw=4:
