// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace worldgen
{
	struct QueueModifiedEvent: public interface::Event::Private
	{
		size_t queue_size;

		QueueModifiedEvent(size_t queue_size):
			queue_size(queue_size)
		{}
	};

	struct Interface
	{
		virtual size_t get_num_sections_queued() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(worldgen::Interface*)> cb)
	{
		return server->access_module("worldgen", [&](interface::Module *module){
			cb((worldgen::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:

