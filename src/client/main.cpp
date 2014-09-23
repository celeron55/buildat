// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include <core/log.h>
#include "client/config.h"
#include "client/state.h"
#include "client/app.h"
#include <c55/getopt.h>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Context.h>
#pragma GCC diagnostic pop
#include <signal.h>
#define MODULE "__main"
namespace u3d = Urho3D;

client::Config g_client_config;

bool g_sigint_received = false;
void sigint_handler(int sig)
{
	if(!g_sigint_received){
		fprintf(stdout, "\n"); // Newline after "^C"
		log_i("process", "SIGINT");
		g_sigint_received = true;
	} else {
		(void)signal(SIGINT, SIG_DFL);
	}
}

void signal_handler_init()
{
	(void)signal(SIGINT, sigint_handler);
}

void basic_init()
{
	signal_handler_init();

	// Force '.' as decimal point
	std::locale::global(std::locale(std::locale(""), "C", std::locale::numeric));
	setlocale(LC_NUMERIC, "C");

	log_set_max_level(LOG_VERBOSE);
}

int main(int argc, char *argv[])
{
	basic_init();

	client::Config &config = g_client_config;

	const char opts[100] = "hs:P:C:U:l:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -s [address]         Specify server address\n"
			"  -P [share_path]      Specify share/ path\n"
			"  -C [cache_path]      Specify cache/ path\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -l [integer]         Set maximum log level (0...5)\n"
	;

	int c;
	while((c = c55_getopt(argc, argv, opts)) != -1)
	{
		switch(c)
		{
		case 'h':
			printf(usagefmt, argv[0]);
			return 1;
		case 's':
			fprintf(stderr, "INFO: config.server_address: %s\n", c55_optarg);
			config.server_address = c55_optarg;
			break;
		case 'P':
			fprintf(stderr, "INFO: config.share_path: %s\n", c55_optarg);
			config.share_path = c55_optarg;
			break;
		case 'C':
			fprintf(stderr, "INFO: config.cache_path: %s\n", c55_optarg);
			config.cache_path = c55_optarg;
			break;
		case 'U':
			fprintf(stderr, "INFO: config.urho3d_path: %s\n", c55_optarg);
			config.urho3d_path = c55_optarg;
			break;
		case 'l':
			log_set_max_level(atoi(c55_optarg));
			break;
		default:
			fprintf(stderr, "ERROR: Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	if(!config.check_paths()){
		return 1;
	}

	u3d::Context context;
	sp_<app::App> app0(app::createApp(&context));
	sp_<client::State> state(client::createState(app0));
	app0->set_state(state);

	if(!state->connect(config.server_address, "20000"))
		return 1;

	return app0->run();
}
