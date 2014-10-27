// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/thread.h"
#include "interface/mutex.h"
#include "core/log.h"
#include <c55/os.h>
#include <deque>
#include <atomic>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <signal.h>
#endif
#define MODULE "thread_pool"

namespace interface {

struct CThread: public Thread
{
	std::atomic_bool m_running;
	std::atomic_bool m_stop_requested;
	ss_ m_name = "unknown"; // Read-only when thread is running (no mutex)
	up_<ThreadedThing> m_thing;
	pthread_t m_thread;

	CThread(ThreadedThing *thing):
		m_running(false),
		m_stop_requested(false),
		m_thing(thing)
	{}

	~CThread()
	{
		request_stop();
		join();
	}

	static void* run_thread(void *arg)
	{
		CThread *thread = (CThread*)arg;
		log_d(MODULE, "Thread started: %p (%s)", thread, cs(thread->m_name));

		// Set name
		if(!thread->m_name.empty()){
			ss_ limited_name = thread->m_name.size() <= 15 ?
					thread->m_name : thread->m_name.substr(0, 15);
			if(pthread_setname_np(thread->m_thread, limited_name.c_str())){
				log_w(MODULE, "Failed to set thread name (thread %p, name \"%s\")",
						thread, limited_name.c_str());
			}
		}

#ifndef _WIN32
		// Disable all signals
		sigset_t sigset;
		sigemptyset(&sigset);
		(void)pthread_sigmask(SIG_SETMASK, &sigset, NULL);
#endif

		try {
			if(thread->m_thing)
				thread->m_thing->run(thread);
		} catch(std::exception &e){
			log_w(MODULE, "ThreadThing of thread %p failed: %s",
					arg, e.what());
		}

		log_d(MODULE, "Thread %p exit", arg);
		thread->m_running = false;
		pthread_exit(NULL);
	}

	// Interface

	void set_name(const ss_ &name)
	{
		if(m_running)
			throw Exception("Cannot set name of running thread");
		m_name = name;
	}

	void start()
	{
		if(m_running){
			log_w(MODULE, "CThread::start(): Already running");
			return;
		}
		m_stop_requested = false;
		if(pthread_create(&m_thread, NULL, run_thread, (void*)this)){
			throw Exception("pthread_create() failed");
		}
		m_running = true;
	}

	bool is_running()
	{
		return m_running;
	}

	void request_stop()
	{
		m_stop_requested = true;
	}

	bool stop_requested()
	{
		return m_stop_requested;
	}

	void join()
	{
		{
			if(!m_running){
				return;
			}
			if(!m_stop_requested){
				log_w(MODULE, "Joining a thread that was not requested "
						"to stop");
			}
		}
		pthread_join(m_thread, NULL);
	}
};

Thread* createThread(ThreadedThing *thing)
{
	return new CThread(thing);
}

}
// vim: set noet ts=4 sw=4:
