// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Urho3D {
	class Context;
}
namespace client {
	struct State;
}

namespace app
{
	struct AppStartupError: public Exception {
		ss_ msg;
		AppStartupError(const ss_ &msg): Exception(msg){}
	};

	struct App
	{
		virtual ~App(){}
		virtual void set_state(sp_<client::State> state) = 0;
		virtual int run() = 0;
		virtual void shutdown() = 0;
		virtual bool reboot_requested() = 0;
		virtual void run_script(const ss_ &script) = 0;
		virtual bool run_script_no_sandbox(const ss_ &script) = 0;
		virtual void handle_packet(const ss_ &name, const ss_ &data) = 0;
		virtual void file_updated_in_cache(const ss_ &file_name,
				const ss_ &file_hash, const ss_ &cached_path) = 0;
	};

	App* createApp(Urho3D::Context *context);
}
// vim: set noet ts=4 sw=4:
