// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#ifndef _WIN32
	#include "core/log.h"
	#include <stdio.h>
	#define __GNU_SOURCE // RTLD_NEXT
	#ifndef __USE_GNU
		#define __USE_GNU // RTLD_NEXT
	#endif
	#include <dlfcn.h>
	#define MODULE "guard"
extern "C"
{
	void (*r_buildat_guard_add_valid_base_path)(const char *path) = NULL;
	void (*r_buildat_guard_enable)(int enable) = NULL;
	void (*r_buildat_guard_clear_paths)(void) = NULL;
	
	int buildat_guard_init()
	{
		r_buildat_guard_add_valid_base_path = (void (*)(const char*))
				dlsym(RTLD_NEXT, "buildat_guard_add_valid_base_path");
		r_buildat_guard_enable = (void (*)(int))
				dlsym(RTLD_NEXT, "buildat_guard_enable");
		r_buildat_guard_clear_paths = (void (*)(void))
				dlsym(RTLD_NEXT, "buildat_guard_clear_paths");
		int succesful = (r_buildat_guard_add_valid_base_path != NULL);
		log_v(MODULE, "buildat_guard_init(): %s", succesful?"succesful":"failed");
		return !succesful;
	}

	void buildat_guard_add_valid_base_path(const char *path)
	{
		if(!r_buildat_guard_add_valid_base_path)
			return;
		log_v(MODULE, "buildat_guard_add_valid_base_path(\"%s\")", path);
		(*r_buildat_guard_add_valid_base_path)(path);
	}

	void buildat_guard_enable(int enable)
	{
		if(!r_buildat_guard_enable)
			return;
		log_v(MODULE, "buildat_guard_enable(%s)", enable?"true":"false");
		(*r_buildat_guard_enable)(enable);
	}

	void buildat_guard_clear_paths(void)
	{
		if(!r_buildat_guard_clear_paths)
			return;
		log_v(MODULE, "buildat_guard_clear_paths()");
		(*r_buildat_guard_clear_paths)();
	}
}
#else // #ifndef _WIN32
extern "C"
{
	// Not supported on platform
	int buildat_guard_init(){ return 0; }
	void buildat_guard_add_valid_base_path(const char *path){}
	void buildat_guard_enable(int enable){}
	void buildat_guard_clear_paths(void){}
}
#endif // #ifndef _WIN32
