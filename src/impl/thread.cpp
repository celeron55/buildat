// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/thread.h"
#include "interface/mutex.h"
//#include "interface/semaphore.h"
#include "core/log.h"
#include <c55/os.h>
#include <deque>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
	#include <signal.h>
#endif
#define MODULE "thread"

namespace interface {

int g_thread_name_counter = 0;
interface::Mutex g_thread_name_counter_mutex;

struct CThread: public Thread
{
	bool m_running = false;
	bool m_stop_requested = false;
	ss_ m_name;
	interface::Mutex m_mutex; // Protects the former variables
	ThreadedThing *m_thing;
	pthread_t m_thread;
	bool m_thread_exists = false;
	//interface::Semaphore m_thread_exit_sem;

	CThread(ThreadedThing *thing)
	{
		m_thing = thing;
		//m_thread_exit_sem.post();
	}

	~CThread()
	{
		// You must call request_stop() and join() explicitly; it seems that
		// Helgrind and DRD are unhappy if they are called from here.
		if(m_thread_exists){
			interface::MutexScope ms(m_mutex);
			log_e(MODULE, "Thread %p (%s) destructed but not stopped",
					this, cs(m_name));
		}
		/*request_stop();
		join();*/
		//m_thread_exit_sem.wait();
		delete m_thing;
	}

	static void* run_thread(void *arg)
	{
		CThread *thread = (CThread*)arg;
		ss_ thread_name;
		{
			interface::MutexScope ms(thread->m_mutex);
			thread_name = thread->m_name;
		}
		log_d(MODULE, "Thread started: %p (%s)", thread, cs(thread_name));

		// Set name
		if(!thread_name.empty()){
			ss_ limited_name = thread_name.size() <= 15 ?
					thread_name : thread_name.substr(0, 15);
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

		log_d(MODULE, "Thread %p (%s) exit", arg, cs(thread_name));
		{
			interface::MutexScope ms(thread->m_mutex);
			thread->m_running = false;
		}
		//thread->m_thread_exit_sem.post();
		pthread_exit(NULL);
	}

	// Interface

	void set_name(const ss_ &name)
	{
		{
			interface::MutexScope ms(m_mutex);
			if(m_running)
				throw Exception("Cannot set name of running thread");
			m_name = name;
		}
	}

	void start()
	{
		//m_thread_exit_sem.wait();
		if(m_name.empty()){
			// Generate a name
			interface::MutexScope ms(g_thread_name_counter_mutex);
			m_name = "unknown "+itos(g_thread_name_counter++);
		}
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
		m_thread_exists = true;
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
			if(!m_stop_requested){
				log_w(MODULE, "Joining a thread that was not requested "
						"to stop");
			}
		}
		if(m_thread_exists){
			pthread_join(m_thread, NULL);
			m_thread_exists = false;
		}
	}
};

Thread* createThread(ThreadedThing *thing)
{
	return new CThread(thing);
}

// ThreadLocalKey

struct ThreadLocalKeyPrivate
{
	pthread_key_t key;
};

ThreadLocalKey::ThreadLocalKey():
	m_private(new ThreadLocalKeyPrivate)
{
	pthread_key_create(&m_private->key, NULL);
}

ThreadLocalKey::~ThreadLocalKey()
{
	pthread_key_delete(m_private->key);
}

void ThreadLocalKey::set(void *p)
{
	pthread_setspecific(m_private->key, p);
}

void* ThreadLocalKey::get()
{
	return pthread_getspecific(m_private->key);
}

}
// vim: set noet ts=4 sw=4:
