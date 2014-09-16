/*
 * Copyright 2012 Perttu Ahola, celeron55@gmail.com (all rights reserved)
 */

#include "c55_getopt.h"
#include <stdio.h>

const char *c55_optarg = NULL;
//int c55_optind = -1;

int c55_argi = 0;
const char *c55_cp = NULL;

int c55_getopt(int argc, char *argv[], const char *argspec)
{
	if(c55_cp == NULL || *c55_cp == 0){
		for(;;){
			c55_argi++;
			if(c55_argi >= argc)
				return -1;
			c55_cp = &argv[c55_argi][0];
			if(*c55_cp == '-'){
				c55_cp++;
				if(*c55_cp != 0)
					break;
			}
			fprintf(stderr, "getopt: skipping \"%s\"\n", argv[c55_argi]);
		}
	}
	char cc = *c55_cp;
	c55_cp++;
	const char *specp = argspec;
	while(*specp){
		if(*specp == cc)
			break;
		specp++;
	}
	if(*specp == 0){
		fprintf(stderr, "getopt: Invalid argument: %c\n", cc);
		return '?';
	}
	specp++;
	if(*specp != ':')
		return cc;
	if(*c55_cp == 0){
		c55_argi++;
		if(c55_argi >= argc){
			fprintf(stderr, "getopt: Argument requires value: %c\n", cc);
			return '?';
		}
		c55_optarg = argv[c55_argi];
		c55_cp = NULL;
	} else {
		c55_optarg = c55_cp;
		c55_cp = NULL;
	}
	return cc;
}


