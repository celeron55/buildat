// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/json.h"
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace interface
{
	struct ModuleInfo;
}

namespace loader
{
	struct Interface
	{
		virtual void activate() = 0;
		virtual interface::ModuleInfo* get_module_info(const ss_ &name) = 0;
	};

	inline bool access(interface::Server *server,
	        std::function<void(loader::Interface*)> cb)
	{
		return server->access_module("loader", [&](interface::Module *module){
		                   cb((loader::Interface*)module->check_interface());
					   });
	}
}
// vim: set noet ts=4 sw=4:
