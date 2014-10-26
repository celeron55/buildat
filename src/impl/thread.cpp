// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/thread.h"
#include "interface/mutex.h"
#include "core/log.h"
#include <c55/os.h>
#include <deque>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <semaphore.h>
	#include <signal.h>
#endif
#define MODULE "thread_pool"

namespace interface {

struct CThread: public Thread
{
	// TODO: Use std::atomic_bool
	bool m_running = false;
	bool m_stop_requested = false;
	interface::Mutex m_mutex; // Protects each of the former variables
	up_<ThreadedThing> m_thing;
	pthread_t m_thread;

	CThread(ThreadedThing *thing):
		m_thing(thing)
	{}

	~CThread()
	{
		request_stop();
		join();
	}

	static void* run_thread(void *arg)
	{
		log_d(MODULE, "Thread %p start", arg);
#ifndef _WIN32
		// Disable all signals
		sigset_t sigset;
		sigemptyset(&sigset);
		(void)pthread_sigmask(SIG_SETMASK, &sigset, NULL);
#endif
		// Go on
		CThread *thread = (CThread*)arg;

		try {
			if(thread->m_thing)
				thread->m_thing->run(thread);
		} catch(std::exception &e){
			log_w(MODULE, "ThreadThing of thread %p failed: %s",
					arg, e.what());
		}

		log_d(MODULE, "Thread %p exit", arg);
		interface::MutexScope ms(thread->m_mutex);
		thread->m_running = false;
		pthread_exit(NULL);
	}

	// Interface
	
	void start()
	{
		interface::MutexScope ms(m_mutex);
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
		interface::MutexScope ms(m_mutex);
		return m_running;
	}

	void request_stop()
	{
		interface::MutexScope ms(m_mutex);
		m_stop_requested = true;
	}

	bool stop_requested()
	{
		interface::MutexScope ms(m_mutex);
		return m_stop_requested;
	}

	void join()
	{
		{
			interface::MutexScope ms(m_mutex);
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
