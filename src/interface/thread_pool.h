// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	namespace thread_pool
	{
		struct Task
		{
			virtual ~Task(){}
			// Called repeatedly from main thread until returns true
			virtual bool pre() = 0;
			// Called repeatedly from worker thread until returns true
			virtual bool thread() = 0;
			// Called repeatedly from main thread until returns true
			virtual bool post() = 0;
		};

		struct ThreadPool
		{
			virtual ~ThreadPool(){}
			virtual void add_task(up_<Task> task) = 0;
			virtual void start(size_t num_threads) = 0;
			virtual void request_stop() = 0;
			virtual void join() = 0;
			virtual void run_post() = 0;
		};

		ThreadPool* createThreadPool();
	}
}
// vim: set noet ts=4 sw=4:
