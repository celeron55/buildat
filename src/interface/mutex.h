// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface
{
	struct Mutex
	{
		// TODO
		void lock(){
		};
		void unlock(){
		};
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

