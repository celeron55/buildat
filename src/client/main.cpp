#include "core/types.h"
#include <core/log.h>
#include "client/config.h"
#include "client/state.h"
#include "client/app.h"
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wsign-compare"
#include <PolycodeView.h>
#pragma GCC diagnostic pop
#include <c55/getopt.h>
#include <signal.h>
#define MODULE "__main"

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

	const char opts[100] = "hs:p:P:C:l:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -s [address]         Specify server address\n"
			"  -p [polycode_path]   Specify polycode path\n"
			"  -P [share_path]      Specify share/ path\n"
			"  -C [cache_path]      Specify cache/ path\n"
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
		case 'p':
			fprintf(stderr, "INFO: config.polycode_path: %s\n", c55_optarg);
			config.polycode_path = c55_optarg;
			break;
		case 'P':
			fprintf(stderr, "INFO: config.share_path: %s\n", c55_optarg);
			config.share_path = c55_optarg;
			break;
		case 'C':
			fprintf(stderr, "INFO: config.cache_path: %s\n", c55_optarg);
			config.cache_path = c55_optarg;
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

	Polycode::PolycodeView *view = new Polycode::PolycodeView("Hello Polycode!");
	sp_<app::App> app0(app::createApp(view));

	sp_<client::State> state(client::createState(app0));
	app0->set_state(state);

	if(!state->connect(config.server_address, "20000"))
		return 1;
	state->send("foo");

	while(app0->update()){
		state->update();
		if(g_sigint_received)
			app0->shutdown();
	}
	return 0;
}
