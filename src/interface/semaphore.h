// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <cerrno>
#include <ctime>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <semaphore.h>
#endif

namespace interface
{
	struct Semaphore
	{
		sem_t sem;

		Semaphore(unsigned int value = 0){
			sem_init(&sem, 0, value);
		}
		~Semaphore(){
			sem_destroy(&sem);
		}
		void wait(){
			sem_wait(&sem);
		}
		// Waits for at most this long; false if it timed out. What wants it
		// is a wait that should never be long: waiting in slices and saying
		// who is waiting for what turns a hang from a silent one into a line
		// in the log. See ModuleContainer::execute_direct_cb().
		bool wait_us(int64_t timeout_us){
#ifdef _WIN32
			// No sem_timedwait in the compat header; the caller gets the
			// plain wait and no timeout, which is what it did before this
			sem_wait(&sem);
			return true;
#else
			struct timespec until;
			clock_gettime(CLOCK_REALTIME, &until);
			until.tv_sec += (time_t)(timeout_us / 1000000);
			until.tv_nsec += (long)((timeout_us % 1000000) * 1000);
			if(until.tv_nsec >= 1000000000L){
				until.tv_sec += 1;
				until.tv_nsec -= 1000000000L;
			}
			while(sem_timedwait(&sem, &until) != 0){
				if(errno == EINTR)
					continue;
				return false;
			}
			return true;
#endif
		}
		void post(){
			sem_post(&sem);
		}
	};
}

// vim: set noet ts=4 sw=4:
