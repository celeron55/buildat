// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/event.h"

#define BUILDAT_EXPORT __attribute__((visibility("default")))

namespace interface
{
	struct Module
	{
		const char *m_module_name = "(unknown module)";
		Module(const char *name): m_module_name(name){}
		virtual ~Module(){}
		virtual void init() = 0;
		virtual void event(const Event::Type &type, const Event::Private *p) = 0;
		virtual void* get_interface(){
			return NULL;
		}
		void* check_interface();
	};
}
// vim: set noet ts=4 sw=4:
