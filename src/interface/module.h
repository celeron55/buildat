#pragma once
#include "core/types.h"

#define EXPORT __attribute__ ((visibility ("default")))

namespace interface
{
	struct Event;

	struct Module
	{
		virtual ~Module(){};
		// Never call directly; this is not thread-safe
		virtual void event(const interface::Event &event) = 0;
	};

	struct SafeModule
	{
		virtual ~ModuleInterface(){};
		virtual void event(const interface::Event &event) = 0;
	};
}
