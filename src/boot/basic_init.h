// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "interface/debug.h"
#include "interface/os.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include "ports/windows_compat.h"
#else
	#include <unistd.h>
#endif

void signal_handler_init();

namespace boot
{
	struct BasicInitScope
	{
		BasicInitScope(){
			signal_handler_init();

			// Force '.' as decimal point
			try {
				std::locale::global(std::locale(std::locale(""), "C",
						std::locale::numeric));
			} catch(std::runtime_error &e){
				// mingw's std::locale("") throws on every Windows, and the
				// line was noise in front of a real fault's ([WIN8_START]);
				// setlocale() below is what the number formatting needs
#ifndef _WIN32
				fprintf(stderr, "Failed to set numeric C++ locale\n");
#endif
			}
			setlocale(LC_NUMERIC, "C");

			log_init();
			log_set_max_level(CORE_VERBOSE);

			interface::debug::SigConfig debug_sig_config;
			interface::debug::init_signal_handlers(debug_sig_config);

			srand(interface::os::time_us());

#ifdef _WIN32
			WORD version_request = MAKEWORD(2, 2);
			WSADATA wsa_data;
			if(int err = WSAStartup(version_request, &wsa_data))
				throw Exception("WSAStartup failed; err="+itos(err));
#endif
		}
		~BasicInitScope(){
#ifdef _WIN32
			WSACleanup();
#endif
		}
	};
}
// vim: set noet ts=4 sw=4:
