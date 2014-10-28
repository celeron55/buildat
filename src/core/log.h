// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once

// The numeric values of these go from fatal=0 to trace=6 in ascending order.
extern const int CORE_FATAL;
extern const int CORE_ERROR;
extern const int CORE_WARNING;
extern const int CORE_INFO;
extern const int CORE_VERBOSE;
extern const int CORE_DEBUG;
extern const int CORE_TRACE;

void log_init();

void log_set_max_level(int level);
int log_get_max_level();
void log_set_file(const char *path);
void log_close();

void log_nl();
void log_(int level, const char *sys, const char *fmt, ...)
__attribute__((format(printf, 3, 4)));
#define log_f(sys, fmt, ...) log_(CORE_FATAL, sys, fmt, ##__VA_ARGS__)
#define log_e(sys, fmt, ...) log_(CORE_ERROR, sys, fmt, ##__VA_ARGS__)
#define log_w(sys, fmt, ...) log_(CORE_WARNING, sys, fmt, ##__VA_ARGS__)
#define log_i(sys, fmt, ...) log_(CORE_INFO, sys, fmt, ##__VA_ARGS__)
#define log_v(sys, fmt, ...) log_(CORE_VERBOSE, sys, fmt, ##__VA_ARGS__)
#define log_d(sys, fmt, ...) log_(CORE_DEBUG, sys, fmt, ##__VA_ARGS__)
#define log_t(sys, fmt, ...) log_(CORE_TRACE, sys, fmt, ##__VA_ARGS__)
void log_no_nl(int level, const char *sys, const char *fmt, ...)
__attribute__((format(printf, 3, 4)));
#define log_nf(sys, fmt, ...) log_no_nl(CORE_FATAL, sys, fmt, ##__VA_ARGS__)
#define log_ne(sys, fmt, ...) log_no_nl(CORE_ERROR, sys, fmt, ##__VA_ARGS__)
#define log_nw(sys, fmt, ...) log_no_nl(CORE_WARNING, sys, fmt, ##__VA_ARGS__)
#define log_ni(sys, fmt, ...) log_no_nl(CORE_INFO, sys, fmt, ##__VA_ARGS__)
#define log_nv(sys, fmt, ...) log_no_nl(CORE_VERBOSE, sys, fmt, ##__VA_ARGS__)
#define log_nd(sys, fmt, ...) log_no_nl(CORE_DEBUG, sys, fmt, ##__VA_ARGS__)
#define log_nt(sys, fmt, ...) log_no_nl(CORE_TRACE, sys, fmt, ##__VA_ARGS__)

// vim: set noet ts=4 sw=4:
