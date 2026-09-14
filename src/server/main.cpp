// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include "core/log.h"
#include "core/config.h"
#include "boot/basic_init.h"
#include "boot/autodetect.h"
#include "server/config.h"
#include "server/state.h"
#include "interface/server.h"
#include "interface/debug.h"
#include "interface/os.h"
#include <c55/getopt.h>
#include <c55/os.h>
#include <iostream>
#include <climits>
#include <cstdlib> // srand()
#include <signal.h>
#include <malloc.h> // mallopt(), M_PERTURB
#include <string.h> // strerror()
#include <time.h> // struct timeval
#define MODULE "main"

server::Config g_server_config;

// The signal that asked for shutdown, read by the main loop. Only things a
// signal handler may touch belong in here: no logging, no locking, no
// allocation. The loop does all of that once it sees this.
volatile sig_atomic_t g_shutdown_signal = 0;

void shutdown_signal_handler(int sig)
{
	if(g_shutdown_signal == 0){
		g_shutdown_signal = sig;
	} else {
		// Asked twice: the shutdown is not getting anywhere, so let the
		// default action have the process
		(void)signal(sig, SIG_DFL);
		(void)raise(sig);
	}
}

void signal_handler_init()
{
	(void)signal(SIGINT, shutdown_signal_handler);
	(void)signal(SIGTERM, shutdown_signal_handler);
#ifndef _WIN32
	(void)signal(SIGPIPE, SIG_IGN);
#endif
}

int main(int argc, char *argv[])
{
	boot::BasicInitScope basic_init_scope;

	// glibc fills a freed block with 0x5a and a fresh one with 0xa5 when
	// this is set, which turns a read of a freed object from a value that
	// looks plausible into one that names itself: 0x5a5a5a5a5a5a5a5a in a
	// backtrace says "freed" at a glance and 0xa5a5... says "never
	// written". It costs a memset per allocation and nothing else, so it is
	// on in every build that has its asserts -- which is every ordinary one,
	// the default build type being Debug. MALLOC_PERTURB_=90 does the same
	// for a binary already built.
	//
	// Measured here rather than assumed, because two things about it are not
	// what one would guess: a small free goes to the tcache and is *not*
	// poisoned while that bin has room -- seven per size class -- and the
	// first sixteen bytes of a poisoned small chunk hold glibc's own links
	// rather than the pattern. A large block is poisoned from its first
	// byte. So this catches a great deal and promises nothing; the
	// quarantine is a sanitizer's job. See doc/plan/master_plan.md,
	// "Catching a use-after-free before it is a mystery".
#ifndef NDEBUG
	mallopt(M_PERTURB, 0x5a);
#endif

	server::Config &config = g_server_config;

	std::string module_path;

	const char opts[100] = "hm:r:i:S:D:U:c:l:L:C:A:P:wR";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -m [module_path]     Specify module path\n"
			"  -r [rccpp_build_path]Specify runtime compiled C++ build path\n"
			"  -i [interface_path]  Specify path to interface headers\n"
			"  -S [share_path]      Specify path to share/\n"
			"  -D [user_path]       Specify user/ path (saves live here)\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -c [command]         Set compiler command\n"
			"  -l [integer]         Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file\n"
			"  -C [module_name]     Skip compiling specified module\n"
			"  -A [address]         Set listening address (default any4)\n"
			"  -P [port]            Set network port (default 29500)\n"
			"  -w                   Watch served files and push changes to\n"
			"                       connected clients (for development)\n"
			"  -R                   Restart a module when its source changes\n"
			"                       (for development; off by default)\n"
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
		case 'D':
			log_i(MODULE, "config.user_path: %s", c55_optarg);
			config.set("user_path", c55_optarg);
			break;
		case 'U':
			log_i(MODULE, "config.urho3d_path: %s", c55_optarg);
			config.set("urho3d_path", c55_optarg);
			break;
		case 'c':
			log_i(MODULE, "config.compiler_command: %s", c55_optarg);
			config.set("compiler_command", c55_optarg);
			break;
		case 'A':
			log_i(MODULE, "config.network_address: %s", c55_optarg);
			config.set("network_address", c55_optarg);
			break;
		case 'P':
			log_i(MODULE, "config.network_port: %s", c55_optarg);
			config.set("network_port", c55_optarg);
			break;
		case 'w':
			config.set("watch_client_files", true);
			break;
		case 'R':
			config.set("reload_modules", true);
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

	// The whole fault this warns about is a restart nobody was told about,
	// so it says once that it can happen; "reload_module" in the log is
	// where it did
	if(config.get<bool>("reload_modules")){
		log_i(MODULE, "Module hot-reload is on: a module is restarted when "
				"its source changes, and whatever it was holding goes with "
				"it");
	}

	signal_handler_init();

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
			if(g_shutdown_signal != 0){
				// SIGINT leaves a "^C" on the terminal to write past
				if(g_shutdown_signal == SIGINT)
					fprintf(stdout, "\n");
				log_i(MODULE, "%s; shutting down",
						g_shutdown_signal == SIGINT ? "SIGINT" : "SIGTERM");
				shutdown_reason = "Signal";
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

		// Whatever a module is holding gets one last chance to reach the
		// disk. Synchronous, because the main loop is over and a queued
		// event would never be handled; before the module threads stop,
		// because a module's work happens in one.
		state->emit_event_synchronously(interface::Event("core:shutdown"));

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
