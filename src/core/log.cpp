#include "log.h"
#include "c55/os.h"
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <cstdarg>
#include <pthread.h>

pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

bool line_begin = true;
int current_level = 0;
//int max_level = LOG_DEBUG;
int max_level = LOG_INFO;
FILE *file = NULL;

void log_set_max_level(int level)
{
	pthread_mutex_lock(&log_mutex);
	max_level = level;
	pthread_mutex_unlock(&log_mutex);
}

int log_get_max_level()
{
	pthread_mutex_lock(&log_mutex);
	int l = max_level;
	pthread_mutex_unlock(&log_mutex);
	return l;
}

void log_set_file(const char *path)
{
	pthread_mutex_lock(&log_mutex);
	file = fopen(path, "a");
	if(file)
		fprintf(stderr, "Opened log file \"%s\"\n", path);
	else
		log_w("__log", "Failed to open log file \"%s\"", path);
	pthread_mutex_unlock(&log_mutex);
}

void log_close()
{
	pthread_mutex_lock(&log_mutex);
	if(file){
		fclose(file);
		file = NULL;
	}
	pthread_mutex_unlock(&log_mutex);
}

void log_nl_nolock()
{
	if(current_level <= max_level){
		if(file){
			fprintf(file, "\n");
			fflush(file);
		} else{
			fprintf(stderr, "\n");
			fprintf(stderr, "\033[0m");
		}
	}
	line_begin = true;
}

void log_nl()
{
	pthread_mutex_lock(&log_mutex);
	log_nl_nolock();
	pthread_mutex_unlock(&log_mutex);
}

static void print(int level, const char *sys, const char *fmt, va_list va_args)
{
	if(!file && (level != current_level || line_begin) && level <= max_level){
		if(level == LOG_FATAL)
			fprintf(stderr, "\033[0m\033[0;1;41m"); // reset, bright red bg
		else if(level == LOG_ERROR)
			fprintf(stderr, "\033[0m\033[1;31m"); // bright red fg, black bg
		else if(level == LOG_WARNING)
			fprintf(stderr, "\033[0m\033[1;33m"); // bright yellow fg, black bg
		else if(level == LOG_INFO)
			fprintf(stderr, "\033[0m"); // reset
		else if(level == LOG_VERBOSE)
			fprintf(stderr, "\033[0m\033[0;36m"); // cyan fg, black bg
		else if(level == LOG_DEBUG)
			fprintf(stderr, "\033[0m\033[1;30m"); // bright black fg, black bg
		else if(level == LOG_TRACE)
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
		size_t timestr_len = strftime(timestr, sizeof(timestr),
				"%b %d %H:%M:%S", localtime(&now));
		if(timestr_len == 0)
			timestr[0] = '\0';
		int ms = (get_timeofday_us() % 1000000)/1000;
		timestr_len += snprintf(timestr+timestr_len,
				sizeof(timestr)-timestr_len, ".%03i", ms);
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

void log_(int level, const char *sys, const char *fmt, ...)
{
	pthread_mutex_lock(&log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	log_nl_nolock();
	va_end(va_args);
	pthread_mutex_unlock(&log_mutex);
}

void log_no_nl(int level, const char *sys, const char *fmt, ...)
{
	pthread_mutex_lock(&log_mutex);
	va_list va_args;
	va_start(va_args, fmt);
	print(level, sys, fmt, va_args);
	va_end(va_args);
	pthread_mutex_unlock(&log_mutex);
}
