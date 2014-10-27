// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	struct Thread;

	struct ThreadedThing
	{
		virtual ~ThreadedThing(){}
		// Shall run until finished or until thread->stop_requested()
		virtual void run(interface::Thread *thread) = 0;
	};

	struct Thread
	{
		virtual ~Thread(){}
		virtual void set_name(const ss_ &name) = 0; // Useful for debugging
		virtual void start() = 0;
		virtual bool is_running() = 0;
		virtual void request_stop() = 0;
		virtual bool stop_requested() = 0;
		virtual void join() = 0;
	};

	Thread* createThread(ThreadedThing *thing);
}
// vim: set noet ts=4 sw=4:
