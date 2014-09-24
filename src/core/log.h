// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once

void log_set_max_level(int level);
int log_get_max_level();
void log_set_file(const char *path);
void log_close();

void log_nl();
#define LOG_FATAL 0
#define LOG_ERROR 1
#define LOG_WARNING 2
#define LOG_INFO 3
#define LOG_VERBOSE 4
#define LOG_DEBUG 5
#define LOG_TRACE 6
void log_(int level, const char *sys, const char *fmt, ...)
__attribute__((format(printf, 3, 4)));
#define log_f(sys, fmt, ...) log_(LOG_FATAL, sys, fmt, ##__VA_ARGS__)
#define log_e(sys, fmt, ...) log_(LOG_ERROR, sys, fmt, ##__VA_ARGS__)
#define log_w(sys, fmt, ...) log_(LOG_WARNING, sys, fmt, ##__VA_ARGS__)
#define log_i(sys, fmt, ...) log_(LOG_INFO, sys, fmt, ##__VA_ARGS__)
#define log_v(sys, fmt, ...) log_(LOG_VERBOSE, sys, fmt, ##__VA_ARGS__)
#define log_d(sys, fmt, ...) log_(LOG_DEBUG, sys, fmt, ##__VA_ARGS__)
#define log_t(sys, fmt, ...) log_(LOG_TRACE, sys, fmt, ##__VA_ARGS__)
void log_no_nl(int level, const char *sys, const char *fmt, ...)
__attribute__((format(printf, 3, 4)));
#define log_nf(sys, fmt, ...) log_no_nl(LOG_FATAL, sys, fmt, ##__VA_ARGS__)
#define log_ne(sys, fmt, ...) log_no_nl(LOG_ERROR, sys, fmt, ##__VA_ARGS__)
#define log_nw(sys, fmt, ...) log_no_nl(LOG_WARNING, sys, fmt, ##__VA_ARGS__)
#define log_ni(sys, fmt, ...) log_no_nl(LOG_INFO, sys, fmt, ##__VA_ARGS__)
#define log_nv(sys, fmt, ...) log_no_nl(LOG_VERBOSE, sys, fmt, ##__VA_ARGS__)
#define log_nd(sys, fmt, ...) log_no_nl(LOG_DEBUG, sys, fmt, ##__VA_ARGS__)
#define log_nt(sys, fmt, ...) log_no_nl(LOG_TRACE, sys, fmt, ##__VA_ARGS__)

// vim: set noet ts=4 sw=4:
