// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

#define EVENT_DISPATCH_VOID(event_type, handler) \
	if(type == event_type){handler(); }
#define EVENT_DISPATCH_TYPE(event_type, handler, param_type) \
	if(type == event_type){ \
		auto p0 = dynamic_cast<const param_type*>(p); \
		if(p0) handler(*p0); \
		else if(p == nullptr) Exception(ss_()+"Missing parameter to "+ \
				__PRETTY_FUNCTION__+"::" #handler " (parameter type: " \
				#param_type ")"); \
		else throw Exception(ss_()+"Invalid parameter to "+__PRETTY_FUNCTION__+ \
					  "::" #handler " (expected " #param_type ")"); \
	}
#define EVENT_VOID EVENT_DISPATCH_VOID
#define EVENT_TYPE EVENT_DISPATCH_TYPE
#define EVENT_VOIDN(name, handler) \
	EVENT_DISPATCH_VOID(interface::Event::t(name), handler)
#define EVENT_TYPEN(name, handler, param_type) \
	EVENT_DISPATCH_TYPE(interface::Event::t(name), handler, param_type)

namespace interface
{
	// NOTE: Event has no copy constructor due to up_<Private> p; just pass it
	// by non-const value if it will be placed in a container by the receiver.
	struct Event
	{
		typedef size_t Type;
		struct Private {
			virtual ~Private(){}
		};
		Type type;
		sp_<const Private> p;

		Event():
			type(0){}
		Event(const Type &type):
			type(type){}
		Event(const Type &type, Private *p):
			type(type), p(p){}
		Event(const Type &type, up_<Private> p):
			type(type), p(std::move(p)){}
		Event(const ss_ &name):
			type(t(name)){}
		Event(const ss_ &name, up_<Private> p):
			type(t(name)), p(std::move(p)){}
		template<typename PrivateT>
				Event(const ss_ &name, PrivateT *p):
			type(t(name)), p(up_<Private>(p))
		{}

		static Type t(const ss_ &name); // Shorthand function
	};

	struct EventRegistry
	{
		// Allocates new type if needed
		virtual Event::Type type(const ss_ &name) = 0;
		// Returns "" if type is not allocated to a name
		virtual ss_ name(const Event::Type &type) = 0;
	};

	EventRegistry* getGlobalEventRegistry();
}
// vim: set noet ts=4 sw=4:
