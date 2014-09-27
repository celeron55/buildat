// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include <stdio.h>
#include <string.h>
#define __GNU_SOURCE // RTLD_NEXT
#ifndef __USE_GNU
	#define __USE_GNU // RTLD_NEXT
#endif
#include <dlfcn.h>

// API

// Only absolute paths allowed.
// Remember to add / to end of base path if it is a directory
void buildat_guard_add_valid_base_path(const char *path);

void buildat_guard_enable(int enable);

void buildat_guard_clear_paths();

// The API shall be made available to the main program by LD_PRELOADing this
// library.

// Implementation

static int guard_enabled = 1;

#define MAX_allowed_base_paths 50
#define MAX_allowed_base_path_size 1000
static char allowed_base_paths[MAX_allowed_base_paths][MAX_allowed_base_path_size] = {0};
static size_t allowed_base_paths_next_i = 0;

void buildat_guard_add_valid_base_path(const char *path)
{
	// Don't add more paths than what fit the static storage
	if(allowed_base_paths_next_i >= MAX_allowed_base_paths){
		fprintf(stderr, "### guard: Will not add base path: %s (storage full)\n", path);
		return;
	}
	// Require absolute path
	if(path[0] != '/'){
		fprintf(stderr, "### guard: Will not add base path: %s (not absolute path)\n", path);
		return;
	}
	// Limit length to that of static storage
	if(strlen(path) > MAX_allowed_base_path_size - 1){
		fprintf(stderr, "### guard: Will not add base path: %s (path too long)\n", path);
		return;
	}
	// Path ok; Copy it and return
	strncpy(allowed_base_paths[allowed_base_paths_next_i], path, MAX_allowed_base_path_size-1);
	allowed_base_paths[allowed_base_paths_next_i][MAX_allowed_base_path_size-1] = '\0';
	allowed_base_paths_next_i++;
}

void buildat_guard_enable(int enable)
{
	guard_enabled = enable;
}

void buildat_guard_clear_paths()
{
	allowed_base_paths_next_i = 0;
}

// Returns non-zero value if path is allowed
static int path_allowed(const char *path)
{
	size_t i;
	const size_t path_len = strlen(path);
	for(i=0; i<allowed_base_paths_next_i && i<MAX_allowed_base_paths; i++){
		const char *base = allowed_base_paths[i];
		const size_t base_len = strlen(base);
		// Must start with base path
		if(path_len < base_len)
			continue;
		if(memcmp(path, base, base_len) != 0)
			continue;
		// The rest of it must not contain '..'
		if(strstr(path + base_len, "..") != NULL)
			continue;
		// Path is ok
		//fprintf(stderr, "### guard: Path %s allowed within base %s\n", path, base);
		return 1;
	}
	fprintf(stderr, "### guard: Path not allowed: %s\n", path);
	return 0;
}

static FILE* (*r_fopen)(const char *path, const char *mode) = NULL;

static int initialized = 0;

static void ensure_initialized()
{
	if(initialized)
		return;
	initialized = 1;
	r_fopen = dlsym(RTLD_NEXT, "fopen");
	fprintf(stderr, "### guard: Initialized.\n");
}

// Urho3D's File uses fopen() on Linux and _wfopen() on Windows
FILE* fopen(const char *path, const char *mode)
{
	if(guard_enabled && !path_allowed(path)){
		return NULL;
	}
	ensure_initialized();
	return (*r_fopen)(path, mode);
}
