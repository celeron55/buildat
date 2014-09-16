#include "core/types.h"
#include "server/config.h"
#include "server/state.h"
#include <iostream>
#include <c55_getopt.h>

server::Config g_server_config;

int main(int argc, char *argv[])
{
	server::Config &config = g_server_config;

	std::string module_path;

	const char opts[100] = "hm:r:i:";
	const char usagefmt[1000] =
	"Usage: %s [OPTION]...\n"
	"  -h                   Show this help\n"
	"  -m [module_path]     Specify module path (for testing a single module)\n"
	"  -r [rccpp_build_path]Specify runtime compiled C++ build path\n"
	"  -i [interface_path]  Specify path to interface headers\n"
	;

	int c;
	while((c = c55_getopt(argc, argv, opts)) != -1)
	{  
		switch(c)
		{
		case 'h':
			printf(usagefmt, argv[0]);
			return 1;
		case 'm':
			fprintf(stderr, "INFO: module_path: %s\n", c55_optarg);
			module_path = c55_optarg;
			break;
		case 'r':
			fprintf(stderr, "INFO: config.rccpp_build_path: %s\n", c55_optarg);
			config.rccpp_build_path = c55_optarg;
			break;
		case 'i':
			fprintf(stderr, "INFO: config.interface_path: %s\n", c55_optarg);
			config.interface_path = c55_optarg;
			break;
		default:
			fprintf(stderr, "ERROR: Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	std::cerr<<"Buildat server"<<std::endl;

	up_<server::State> state(server::createState());
	state->load_module(module_path);

	return 0;
}

