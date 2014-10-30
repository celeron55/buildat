// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "log.h"
#include "interface/mutex.h"
//#include "interface/thread.h"
#include "c55/os.h"
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <cstdarg>
#ifdef _WIN32
	#include "ports/windows_compat.h"
#else
	#include <pthread.h>
#endif

const int CORE_FATAL = 0;
const int CORE_ERROR = 1;
const int CORE_WARNING = 2;
const int CORE_INFO = 3;
const int CORE_VERBOSE = 4;
const int CORE_DEBUG = 5;
const int CORE_TRACE = 6;

#ifdef _WIN32
static const bool use_colors = false;
#else
static const bool use_colors = true;
#endif

static interface::Mutex log_mutex;
//static interface::Thread *log_active_thread = nullptr;

static std::atomic_bool disable_bloat(false);
static std::atomic_bool line_begin(true);
static std::atomic_int current_level(0);
static std::atomic_int max_level(CORE_INFO);

static FILE *file = NULL;

void log_init()
{
}

void log_set_max_level(int level)
{
	max_level = level;
}

int log_get_max_level()
{
	return max_level;
}

void log_set_file(const char *path)
{
	log_mutex.lock();
	file = fopen(path, "a");
	if(file)
		fprintf(stderr, "Opened log file \"%s\"\n", path);
	else
		log_w("__log", "Failed to open log file \"%s\"", path);
	log_mutex.unlock();
}

void log_close()
{
	log_mutex.lock();
	if(file){
		fclose(file);
		file = NULL;
	}
	log_mutex.unlock();
}

void log_disable_bloat()
{
	disable_bloat = true;
}

void log_nl_nolock()
{
	if(current_level <= max_level){
		if(file){
			fprintf(file, "\n");
			fflush(file);
		} else {
			fprintf(stderr, "\n");
			if(use_colors)
				fprintf(stderr, "\033[0m");
		}
	}
	line_begin = true;
}

void log_nl()
{
	if(current_level > max_level){ // Fast path
		line_begin = true;
		return;
	}
	interface::MutexScope ms(log_mutex);
	log_nl_nolock();
}

static void print(int level, const char *sys, const char *fmt, va_list va_args)
{
	if(use_colors && !file &&
			(level != current_level || line_begin) && level <= max_level){
		if(level == CORE_FATAL)
			fprintf(stderr, "\033[0m\033[0;1;41m"); // reset, bright red bg
		else if(level == CORE_ERROR)
			fprintf(stderr, "\033[0m\033[1;31m"); // bright red fg, black bg
		else if(level == CORE_WARNING)
			fprintf(stderr, "\033[0m\033[1;33m"); // bright yellow fg, black bg
		else if(level == CORE_INFO)
			fprintf(stderr, "\033[0m"); // reset
		else if(level == CORE_VERBOSE)
			fprintf(stderr, "\033[0m\033[0;36m"); // cyan fg, black bg
		else if(level == CORE_DEBUG)
			fprintf(stderr, "\033[0m\033[1;30m"); // bright black fg, black bg
		else if(level == CORE_TRACE)
			fprintf(stderr, "\033[0m\033[0;35m"); //
		else
			fprintf(stderr, "\033[0m"); // reset
	}
	current_level = level;
	if(level > max_level)
		return;
	if(line_begin){
		time_t now = time(NULL);
		char timestr[30];
		if(disable_bloat){
			timestr[0] = 0;
		} else {
			size_t timestr_len = strftime(timestr, sizeof(timestr),
						"%b %d %H:%M:%S", localtime(&now));
			if(timestr_len == 0)
				timestr[0] = '\0';
			int ms = (get_timeofday_us() % 1000000) / 1000;
			timestr_len += snprintf(timestr + timestr_len,
						sizeof(timestr) - timestr_len, ".%03i", ms);
		}
		char sysstr[9];
		snprintf(sysstr, 9, "%s        ", sys);
		const char *levelcs = "FEWIVDT";
		if(file)
			fprintf(file, "%s %c %s: ", timestr, levelcs[level], sysstr);
		else
			fprintf(stderr, "%s %c %s: ", timestr, levelcs[level], sysstr);
		line_begin = false;
	}
	if(file)
		vfprintf(file, fmt, va_args);
	else
		vfprintf(stderr, fmt, va_args);
}

// Does not require any locking
/*static void fallback_print(int level, const char *sys, const char *fmt,
		va_list va_args)
{
	FILE *f = file;
	if(f == NULL)
		f = stderr;
	if(use_colors && !file)
		fprintf(f, "\033[0m"); // reset
	vfprintf(f, fmt, va_args);
	fprintf(f, "\n");
}*/

void log_(int level, const char *sys, const char *fmt, ...)
{
	if(level > max_level){ // Fast path
		return;
	}
	interface::MutexScope ms(log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	log_nl_nolock();
	va_end(va_args);
}

void log_no_nl(int level, const char *sys, const char *fmt, ...)
{
	if(level > max_level){ // Fast path
		return;
	}
	interface::MutexScope ms(log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	va_end(va_args);
}
// vim: set noet ts=4 sw=4:
