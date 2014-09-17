#pragma once
#include "core/types.h"
#include "interface/event.h"

namespace interface
{
	struct Module;
}

namespace server
{
	struct ModuleNotFoundException: public Exception {
		ss_ msg;
		ModuleNotFoundException(const ss_ &msg): Exception(msg){}
	};

	struct State
	{
		virtual ~State(){}
		virtual void load_module(const ss_ &module_name, const ss_ &path) = 0;
		virtual void load_modules(const ss_ &path) = 0;
		//virtual interface::Module* get_module_u(const ss_ &module_name) = 0;
		//virtual interface::Module* check_module_u(const ss_ &module_name) = 0;
		virtual void sub_event(struct interface::Module *module,
				const interface::Event::Type &type) = 0;
		virtual void emit_event(const interface::Event &event) = 0;
		virtual void handle_events() = 0;
	};

	State* createState();
}
