// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
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
		void post(){
			sem_post(&sem);
		}
	};
}

// vim: set noet ts=4 sw=4:
