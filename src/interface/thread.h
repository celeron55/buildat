// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/debug.h"
#include <list>

namespace interface
{
	struct Thread;

	struct ThreadedThing
	{
		virtual ~ThreadedThing(){}
		// Shall run until finished or until thread->stop_requested()
		virtual void run(interface::Thread *thread) = 0;
		// Called if thread crashes due to an uncaught exception or a signal
		virtual void on_crash(interface::Thread *thread) = 0;
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

		// Debugging interface (not thread-safe; access only from thread itself)
		virtual ss_ get_name() = 0;
		virtual std::list<debug::ThreadBacktrace>& ref_backtraces() = 0;
		virtual void set_caller_thread(Thread *thread) = 0;
		virtual Thread* get_caller_thread() = 0;

		static Thread* get_current_thread();
	};

	Thread* createThread(ThreadedThing *thing);

	struct ThreadLocalKeyPrivate;

	struct ThreadLocalKey
	{
		ThreadLocalKey();
		~ThreadLocalKey();
		void set(void *p);
		void* get();
	private:
		up_<ThreadLocalKeyPrivate> m_private;
	};
}
// vim: set noet ts=4 sw=4:
