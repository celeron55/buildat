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
	};

	App* createApp(Polycode::PolycodeView *view);
}
