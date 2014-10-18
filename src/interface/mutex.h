// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
#endif

namespace interface
{
	// A recursive mutex
	struct Mutex
	{
		pthread_mutex_t mutex;
		pthread_mutexattr_t attr;

		Mutex(){
			pthread_mutexattr_init(&attr);
			pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
			pthread_mutex_init(&mutex, &attr);
		}
		~Mutex(){
			pthread_mutex_destroy(&mutex);
			pthread_mutexattr_destroy(&attr);
		}
		void lock(){
			pthread_mutex_lock(&mutex);
		}
		void unlock(){
			pthread_mutex_unlock(&mutex);
		}
	};

	struct MutexScope
	{
		Mutex &m_mutex;
		MutexScope(Mutex &m): m_mutex(m){
			m_mutex.lock();
		}
		~MutexScope(){
			m_mutex.unlock();
		}
	};
}

// vim: set noet ts=4 sw=4:
