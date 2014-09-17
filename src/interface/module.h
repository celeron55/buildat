#pragma once
#include "core/types.h"

#define EXPORT __attribute__ ((visibility ("default")))

namespace interface
{
	struct Event;

	struct Module
	{
		virtual ~Module(){};
		virtual void init() = 0;
		// Never call directly; this is not thread-safe
		virtual void event(const interface::Event &event) = 0;
	};
}
