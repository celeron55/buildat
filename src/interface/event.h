#pragma once
#include "core/types.h"

namespace interface
{
	struct Event
	{
		typedef size_t Type;
		struct Private {
			virtual ~Private(){}
		};
		Type type;
		sp_<Private> p;

		Event(): type(0) {}
		Event(const Type &type): type(type) {}
		Event(const Type &type, const sp_<Private> &p): type(type), p(p) {}
		Event(const ss_ &name, const sp_<Private> &p=NULL);
	};

	struct EventRegistry
	{
		virtual Event::Type type(const ss_ &name) = 0;
	};

	EventRegistry* getGlobalEventRegistry();
}
