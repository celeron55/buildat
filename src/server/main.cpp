// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include "core/log.h"
#include "core/config.h"
#include "boot/autodetect.h"
#include "boot/cmem.h"
#include "server/config.h"
#include "server/state.h"
#include "interface/server.h"
#include "interface/debug.h"
#include "interface/mutex.h"
#include "interface/os.h"
#include <c55/getopt.h>
#include <c55/os.h>
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include "ports/windows_compat.h"
#else
	#include <unistd.h>
#endif
#include <iostream>
#include <climits>
#include <cstdlib> // srand()
#include <signal.h>
#include <string.h> // strerror()
#include <time.h> // struct timeval
#define MODULE "main"

server::Config g_server_config;

bool g_sigint_received = false;
interface::Mutex g_sigint_received_mutex;

void sigint_handler(int sig)
{
	interface::MutexScope ms(g_sigint_received_mutex);
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
#ifndef _WIN32
	(void)signal(SIGPIPE, SIG_IGN);
#endif
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

	interface::debug::SigConfig debug_sig_config;
	interface::debug::init_signal_handlers(debug_sig_config);

	srand(interface::os::time_us());
}

int main(int argc, char *argv[])
{
	basic_init();

	server::Config &config = g_server_config;

	std::string module_path;

	const char opts[100] = "hm:r:i:S:U:c:l:L:C:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -m [module_path]     Specify module path\n"
			"  -r [rccpp_build_path]Specify runtime compiled C++ build path\n"
			"  -i [interface_path]  Specify path to interface headers\n"
			"  -S [share_path]      Specify path to share/\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -c [command]         Set compiler command\n"
			"  -l [integer]         Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file\n"
			"  -C [module_name]     Skip compiling specified module\n"
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
			log_i(MODULE, "module_path: %s", c55_optarg);
			module_path = c55_optarg;
			break;
		case 'r':
			log_i(MODULE, "config.rccpp_build_path: %s", c55_optarg);
			config.set("rccpp_build_path", c55_optarg);
			break;
		case 'i':
			log_i(MODULE, "config.interface_path: %s", c55_optarg);
			config.set("interface_path", c55_optarg);
			break;
		case 'S':
			log_i(MODULE, "config.share_path: %s", c55_optarg);
			config.set("share_path", c55_optarg);
			break;
		case 'U':
			log_i(MODULE, "config.urho3d_path: %s", c55_optarg);
			config.set("urho3d_path", c55_optarg);
			break;
		case 'c':
			log_i(MODULE, "config.compiler_command: %s", c55_optarg);
			config.set("compiler_command", c55_optarg);
			break;
		case 'l':
			log_set_max_level(atoi(c55_optarg));
			break;
		case 'L':
			log_set_file(c55_optarg);
			break;
		case 'C':
			log_i(MODULE, "config.skip_compiling_modules += %s",
					c55_optarg);
			{
				auto v = config.get<json::Value>("skip_compiling_modules");
				v.set(c55_optarg, json::Value(true));
				config.set("skip_compiling_modules", v);
			}
			break;
		default:
			fprintf(stderr, "ERROR: Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	std::cerr<<"Buildat server"<<std::endl;

	if(!boot::autodetect::detect_server_paths(config))
		return 1;

	if(!config.check_paths()){
		return 1;
	}

	if(module_path.empty()){
		std::cerr<<"Module path (-m) is empty"<<std::endl;
		return 1;
	}

	int exit_status = 0;
	ss_ shutdown_reason;

	try {
		up_<server::State> state(server::createState());

		state->load_modules(module_path);

		// Main loop
		uint64_t next_tick_us = get_timeofday_us();
		uint64_t t_per_tick = 1000000 / 30; // Same as physics FPS

		for(;;){
			{
				interface::MutexScope ms(g_sigint_received_mutex);
				if(g_sigint_received)
					break;
			}
			uint64_t current_us = get_timeofday_us();
			int64_t delay_us = next_tick_us - current_us;
			if(delay_us < 0)
				delay_us = 0;

			usleep(delay_us);

			state->handle_events();

			if(current_us >= next_tick_us){
				next_tick_us += t_per_tick;
				if(next_tick_us < current_us - 1000 * 1000){
					log_w("main", "Skipping %zuus", current_us - next_tick_us);
					next_tick_us = current_us;
				}
				interface::Event event("core:tick",
					new interface::TickEvent(t_per_tick / 1e6));
				state->emit_event(std::move(event));
			}

			if(state->is_shutdown_requested(&exit_status, &shutdown_reason))
				break;
		}

		state->thread_request_stop();
		state->thread_join();
	} catch(server::ServerShutdownRequest &e){
		log_v(MODULE, "ServerShutdownRequest: %s", e.what());
	}

	if(shutdown_reason != ""){
		if(exit_status != 0)
			log_w(MODULE, "Shutdown: %s", cs(shutdown_reason));
		else
			log_v(MODULE, "Shutdown: %s", cs(shutdown_reason));
	}

	return exit_status;
}

// vim: set noet ts=4 sw=4:
