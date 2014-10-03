// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "windows_minimal.h"

static inline void usleep(unsigned int us)
{
	Sleep(us/1000);
}

// Prefer using mingw-w64 with pthreads!
#ifndef __WINPTHREADS_VERSION

typedef HANDLE pthread_mutex_t;
typedef HANDLE pthread_t;

static int pthread_mutex_init(pthread_mutex_t *mutex, void *unused)
{
    (void) unused;
    *mutex = CreateMutex(NULL, FALSE, NULL);
    return *mutex == NULL ? -1 : 0;
}

static int pthread_mutex_destroy(pthread_mutex_t *mutex)
{
    return CloseHandle(*mutex) == 0 ? -1 : 0;
}

static int pthread_mutex_lock(pthread_mutex_t *mutex)
{
    return WaitForSingleObject(*mutex, INFINITE) == WAIT_OBJECT_0? 0 : -1;
}

static int pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    return ReleaseMutex(*mutex) == 0 ? -1 : 0;
}

#endif

// vim: set noet ts=4 sw=4:
