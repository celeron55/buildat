// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/types.h"
#include "core/log.h"
#include "boot/basic_init.h"
#include "boot/autodetect.h"
#include "client/config.h"
#include "client/state.h"
#include "client/app.h"
#include "client/command_seq.h"
#include "interface/os.h"
#include <c55/getopt.h>
#include <Context.h>
#include <cstdio> // sscanf()
#include <cstdlib> // srand()
#include <fstream>
#include <sstream>
#include <signal.h>
#define MODULE "__main"
namespace magic = Urho3D;

client::Config g_client_config;

// The signal that asked for shutdown, read by App::on_update(). Only things a
// signal handler may touch belong in here: no logging, no locking, no
// allocation. The frame that sees this does all of that.
volatile sig_atomic_t g_shutdown_signal = 0;

void shutdown_signal_handler(int sig)
{
	if(g_shutdown_signal == 0){
		g_shutdown_signal = sig;
	} else {
		// Asked twice: the shutdown is not getting anywhere -- or the frame
		// loop is not running yet -- so let the default action have the
		// process
		(void)signal(sig, SIG_DFL);
		(void)raise(sig);
	}
}

void signal_handler_init()
{
	(void)signal(SIGINT, shutdown_signal_handler);
	(void)signal(SIGTERM, shutdown_signal_handler);
#ifndef _WIN32
	// A write to a socket the server has dropped must not kill the client
	(void)signal(SIGPIPE, SIG_IGN);
#endif
}

int main(int argc, char *argv[])
{
	boot::BasicInitScope basic_init_scope;

	client::Config &config = g_client_config;

	const char opts[100] = "hs:P:C:D:U:l:L:m:u:w:o:c:";
	const char usagefmt[1000] =
			"Usage: %s [OPTION]...\n"
			"  -h                   Show this help\n"
			"  -s [address]         Specify server address\n"
			"  -P [share_path]      Specify share/ path\n"
			"  -C [cache_path]      Specify cache/ path\n"
			"  -D [user_path]       Specify user/ path\n"
			"  -U [urho3d_path]     Specify Urho3D path\n"
			"  -l [level number]    Set maximum log level (0...5)\n"
			"  -L [log file path]   Append log to a specified file\n"
			"  -m [name]            Choose menu extension name\n"
			"  -u [scale]           UI scale (0 = auto from short side / 1080)\n"
			"  -w [WxH]             Windowed at this size; not remembered\n"
			"  -o [k=v,...]         Set preferences; not remembered. Keys:\n"
			"                       render_scale, vsync, max_fps,\n"
			"                       multisampling, sound_volume, sound_mute\n"
			"  -c [commands]        Run command sequence and exit\n"
			"                       One command per line. @file reads a file,\n"
			"                       - reads standard input as it arrives.\n"
			"                       See doc/client_commands.txt\n"
			;

	int forced_w = 0, forced_h = 0;
	ss_ preference_overrides;

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
		case 'D':
			log_i(MODULE, "config.user_path: %s", c55_optarg);
			config.set("user_path", c55_optarg);
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
		case 'u':
			log_i(MODULE, "config.ui_scale: %s", c55_optarg);
			config.set("ui_scale", atof(c55_optarg));
			break;
		case 'w':
			if(sscanf(c55_optarg, "%dx%d", &forced_w, &forced_h) != 2 ||
					forced_w <= 0 || forced_h <= 0){
				fprintf(stderr, "-w: expected WxH, got \"%s\"\n", c55_optarg);
				return 1;
			}
			log_i(MODULE, "window size: %ix%i", forced_w, forced_h);
			break;
		case 'o': {
			// Repeatable, and later items win, so that a wrapper script's -o
			// can be overridden on the command line after it
			ss_ items = c55_optarg ? c55_optarg : "";
			ss_ merged = preference_overrides.empty() ? items :
					preference_overrides + "," + items;
			// Accepted here so that a typo is a usage error rather than a
			// startup failure; applied in the app, on top of the saved file
			app::Options probe;
			ss_ err;
			if(!app::parse_preference_options(merged, &probe, &err)){
				fprintf(stderr, "-o: %s\n", err.c_str());
				return 1;
			}
			log_i(MODULE, "preferences: %s", merged.c_str());
			preference_overrides = merged;
			break;
		}
		case 'c': {
			ss_ arg = c55_optarg ? c55_optarg : "";
			ss_ text;
			// A single dash means standard input, read as it arrives rather
			// than up front: what the next command should be is often
			// something only a screenshot of the running client can say.
			if(arg == "-" || arg == "@-"){
				log_i(MODULE, "config.command_seq: from stdin");
				config.set("command_seq", "");
				config.set("command_seq_enabled", true);
				config.set("command_seq_stdin", true);
				break;
			}
			if(!arg.empty() && arg[0] == '@'){
				ss_ path = arg.substr(1);
				if(path.empty()){
					fprintf(stderr, "-c @file: empty path\n");
					return 1;
				}
				std::ifstream in(path.c_str());
				if(!in){
					fprintf(stderr, "Failed to read command file: %s\n",
							path.c_str());
					return 1;
				}
				std::ostringstream ss;
				ss<<in.rdbuf();
				text = ss.str();
			} else {
				text = arg;
			}
			sv_<client::command_seq::Command> parsed;
			ss_ err;
			if(!client::command_seq::parse(text, &parsed, &err)){
				fprintf(stderr, "Invalid -c command sequence: %s\n",
						err.c_str());
				return 1;
			}
			log_i(MODULE, "config.command_seq: %zu commands", parsed.size());
			config.set("command_seq", text);
			config.set("command_seq_enabled", true);
			break;
		}
		default:
			fprintf(stderr, "Invalid command-line argument\n");
			fprintf(stderr, usagefmt, argv[0]);
			return 1;
		}
	}

	signal_handler_init();

	if(!boot::autodetect::detect_client_paths(config))
		return 1;

	if(!config.check_paths()){
		return 1;
	}

	app::Options app_options;
	app_options.preference_overrides = preference_overrides;
	if(forced_w > 0){
		app_options.graphics.window_w = forced_w;
		app_options.graphics.window_h = forced_h;
		app_options.graphics.size_forced = true;
	}

	int exit_status = 0;
	{
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
	}
	log_v(MODULE, "Succesful shutdown");
	return exit_status;
}
// vim: set noet ts=4 sw=4:
