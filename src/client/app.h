// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace Polycode {
	class PolycodeView;
}
namespace client {
	struct State;
}

namespace app
{
	struct App
	{
		virtual ~App(){}
		virtual void set_state(sp_<client::State> state) = 0;
		virtual bool update() = 0;
		virtual void shutdown() = 0;
		virtual void run_script(const ss_ &script) = 0;
		virtual void handle_packet(const ss_ &name, const ss_ &data) = 0;
	};

	App* createApp(Polycode::PolycodeView *view);
}
