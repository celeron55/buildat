#pragma once
#include "core/types.h"

namespace Polycode {
	class PolycodeView;
}

namespace app
{
	struct App
	{
		virtual ~App(){}
		virtual bool update() = 0;
		virtual void shutdown() = 0;
		virtual void run_script(const ss_ &script) = 0;
	};

	App* createApp(Polycode::PolycodeView *view);
}
