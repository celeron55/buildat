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
		up_<Private> p;

		Event(): type(0){}
		Event(const Type &type): type(type){}
		Event(const Type &type, up_<Private> p);
		Event(const ss_ &name): type(t(name)){}
		Event(const ss_ &name, up_<Private> p);

		static Type t(const ss_ &name); // Shorthand function
	};

	struct EventRegistry
	{
		virtual Event::Type type(const ss_ &name) = 0;
	};

	EventRegistry* getGlobalEventRegistry();
}
