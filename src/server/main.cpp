// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include "core/log.h"
#include "server/config.h"
#include "server/state.h"
#include "interface/server.h"
#include <c55/getopt.h>
#include <c55/os.h>
#include <iostream>
#include <unistd.h>
#include <signal.h>
#include <string.h> // strerror()

server::Config g_server_config;

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

	server::Config &config = g_server_config;

	std::string module_path;

	const char opts[100] = "hm:r:i:S:c:l:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -m [module_path]     Specify module path\n"
			"  -r [rccpp_build_path]Specify runtime compiled C++ build path\n"
			"  -i [interface_path]  Specify path to interface headers\n"
			"  -S [share_path]      Specify path to share/\n"
			"  -c [command]         Set compiler command\n"
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
		case 'S':
			fprintf(stderr, "INFO: config.share_path: %s\n", c55_optarg);
			config.share_path = c55_optarg;
			break;
		case 'c':
			fprintf(stderr, "INFO: config.compiler_command: %s\n", c55_optarg);
			config.compiler_command = c55_optarg;
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

	std::cerr<<"Buildat server"<<std::endl;

	if(!config.check_paths()){
		return 1;
	}

	if(module_path.empty()){
		std::cerr<<"Module path (-m) is empty"<<std::endl;
		return 1;
	}

	up_<server::State> state(server::createState());
	state->load_modules(module_path);

	// Main loop
	uint64_t next_tick_us = get_timeofday_us();
	uint64_t t_per_tick = 1000 * 100;
	set_<int> attempt_bad_fds;
	int last_added_attempt_bad_fd = -42;
	set_<int> bad_fds;
	size_t num_consequent_valid_selects = 0;
	while(!g_sigint_received){
		uint64_t current_us = get_timeofday_us();
		int64_t delay_us = next_tick_us - current_us;
		if(delay_us < 0)
			delay_us = 0;

		struct timeval tv;
		tv.tv_sec = 0;
		tv.tv_usec = delay_us;

		fd_set rfds;
		FD_ZERO(&rfds);
		sv_<int> sockets = state->get_sockets();
		int fd_max = 0;
		if(!attempt_bad_fds.empty() || !bad_fds.empty()){
			log_w("main", "Ignoring fds %s and %s out of all %s",
					cs(dump(attempt_bad_fds)), cs(dump(bad_fds)),
					cs(dump(sockets)));
		}
		for(int fd : sockets){
			if(attempt_bad_fds.count(fd) || bad_fds.count(fd))
				continue;
			FD_SET(fd, &rfds);
			if(fd > fd_max)
				fd_max = fd;
		}

		int r = select(fd_max + 1, &rfds, NULL, NULL, &tv);
		if(r == -1){
			// Error
			num_consequent_valid_selects = 0;
			log_w("main", "select() returned -1: %s (fds: %s)",
					strerror(errno), cs(dump(sockets)));
			if(errno == EBADF || errno == EINTR){
				// These are temporary errors
				// Try to find out which socket is doing this
				if(attempt_bad_fds.size() == sockets.size()){
					throw Exception("All fds are bad");
				} else {
					for(;;){
						int fd = sockets[rand() % sockets.size()];
						if(attempt_bad_fds.count(fd) == 0){
							log_w("main", "Trying to ignore fd=%i", fd);
							attempt_bad_fds.insert(fd);
							last_added_attempt_bad_fd = fd;
							break;
						}
					}
				}
			} else {
				// Don't consume 100% CPU and flood logs
				usleep(1000 * 100);
				return 1;
			}
		} else if(r == 0){
			// Nothing happened
			num_consequent_valid_selects++;
		} else {
			// Something happened
			num_consequent_valid_selects++;
			for(int fd : sockets){
				if(FD_ISSET(fd, &rfds)){
					log_d("main", "FD_ISSET: %i", fd);
					state->emit_socket_event(fd);
				}
			}
		}

		if(!attempt_bad_fds.empty() && num_consequent_valid_selects > 5){
			log_w("main", "Found bad fd: %d", last_added_attempt_bad_fd);
			bad_fds.insert(last_added_attempt_bad_fd);
			attempt_bad_fds.clear();
		}

		if(current_us >= next_tick_us){
			next_tick_us += t_per_tick;
			if(next_tick_us < current_us - 1000 * 1000){
				log_w("main", "Skipping %zuus", current_us - next_tick_us);
				next_tick_us = current_us;
			}
			interface::Event event("core:tick");
			event.p.reset(new interface::TickEvent(1e6 / t_per_tick));
			state->emit_event(std::move(event));
		}

		state->handle_events();
	}

	return 0;
}

