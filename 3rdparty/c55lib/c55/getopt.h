// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
/*
 * Copyright 2012 Perttu Ahola, celeron55@gmail.com (all rights reserved)
 */

#ifndef __GETOPT_H__
#define __GETOPT_H__

extern const char *c55_optarg;
//extern int c55_optind;

extern int c55_argi;
extern const char *c55_cp;

int c55_getopt(int argc, char *argv[], const char *argspec);

#endif

// vim: set noet ts=4 sw=4:
