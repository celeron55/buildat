#pragma once
#include "core/types.h"
#include "interface/event.h"

#define EXPORT __attribute__ ((visibility ("default")))

namespace interface
{
	struct Module
	{
		virtual ~Module(){};
		virtual void init() = 0;
		// Never call directly; this is not thread-safe
		virtual void event(const Event::Type &type, const Event::Private *p) = 0;
	};
}
