// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include "core/log.h"
#include "boot/autodetect.h"
#include "boot/cmem.h"
#include "client/config.h"
#include "client/state.h"
#include "client/app.h"
#include <c55/getopt.h>
#include <Context.h>
#include <signal.h>
#define MODULE "__main"
namespace magic = Urho3D;

client::Config g_client_config;

// TODO: This isn't thread-safe
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
	boot::buildat_mem_libc_enable();

	signal_handler_init();

	// Force '.' as decimal point
	try {
		std::locale::global(std::locale(std::locale(""), "C", std::locale::numeric));
	} catch(std::runtime_error &e){
		// Can happen on Wine
		fprintf(stderr, "Failed to set numeric C++ locale\n");
	}
	setlocale(LC_NUMERIC, "C");

	log_init();
	log_set_max_level(CORE_VERBOSE);
}

int main(int argc, char *argv[])
{
	basic_init();

	client::Config &config = g_client_config;

	const char opts[100] = "hs:P:C:U:l:L:m:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -s [address]         Specify server address\n"
			"  -P [share_path]      Specify share/ path\n"
			"  -C [cache_path]      Specify cache/ path\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -l [level number]    Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file\n"
			"  -m [name]            Choose menu extension name\n"
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
			log_i(MODULE, "config.server_address: %s", c55_optarg);
			config.set("server_address", c55_optarg);
			break;
		case 'P':
			log_i(MODULE, "config.share_path: %s", c55_optarg);
			config.set("share_path", c55_optarg);
			break;
		case 'C':
			log_i(MODULE, "config.cache_path: %s", c55_optarg);
			config.set("cache_path", c55_optarg);
			break;
		case 'U':
			log_i(MODULE, "config.urho3d_path: %s", c55_optarg);
			config.set("urho3d_path", c55_optarg);
			break;
		case 'l':
			log_set_max_level(atoi(c55_optarg));
			break;
		case 'L':
			log_set_file(c55_optarg);
			break;
		case 'm':
			log_i(MODULE, "config.menu_extension_name: %s", c55_optarg);
			config.set("menu_extension_name", c55_optarg);
			break;
		default:
			fprintf(stderr, "Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	if(!boot::autodetect::detect_client_paths(config))
		return 1;

	if(!config.check_paths()){
		return 1;
	}

	app::Options app_options;

	int exit_status = 0;
	while(exit_status == 0){
		magic::Context context;
		sp_<app::App> app0(app::createApp(&context, app_options));
		sp_<client::State> state(client::createState(app0));
		app0->set_state(state);

		if(config.get<ss_>("server_address") != ""){
			ss_ error;
			if(!state->connect(config.get<ss_>("server_address"), &error)){
				log_e(MODULE, "Connect failed: %s", cs(error));
				return 1;
			}
		} else {
			config.set("boot_to_menu", true);
		}

		exit_status = app0->run();

		if(!app0->reboot_requested())
			break;

		app_options = app0->get_current_options();
	}
	log_v(MODULE, "Succesful shutdown");
	return exit_status;
}
// vim: set noet ts=4 sw=4:
