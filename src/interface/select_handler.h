// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include "ports/windows_compat.h" // usleep()
#else
	#include <sys/socket.h>
	#include <unistd.h> // usleep()
#endif
#include <cstring> // strerror()
#include <cstdlib> // rand()

namespace interface
{
	struct SelectHandler
	{
		static constexpr const char *MODULE = "SelectHandler";

		set_<int> attempt_bad_fds;
		int last_added_attempt_bad_fd = -42;
		set_<int> bad_fds;
		size_t num_consequent_valid_selects = 0;

		// Returns false if there is some sort of error (no errors are fatal)
		bool check(int timeout_us, const sv_<int> &sockets,
				sv_<int> &active_sockets)
		{
#ifdef _WIN32
			// On Windows select() returns an error if no sockets are supplied
			if(sockets.empty()){
				usleep(timeout_us);
				return true;
			}
#endif

			struct timeval tv;
			tv.tv_sec = 0;
			tv.tv_usec = timeout_us;

			fd_set rfds;
			FD_ZERO(&rfds);
			int fd_max = 0;
			if(!attempt_bad_fds.empty() || !bad_fds.empty()){
				log_w(MODULE, "Ignoring fds %s and %s out of all %s",
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
				if(errno == EINTR){
					// The process is probably quitting
					return false;
				}
				// Error
				num_consequent_valid_selects = 0;
				log_w(MODULE, "select() returned -1: %s (fds: %s)",
						strerror(errno), cs(dump(sockets)));
				if(errno == EBADF){
					// These are temporary errors
					// Try to find out which socket is doing this
					if(attempt_bad_fds.size() == sockets.size()){
						throw Exception("All fds are bad");
					} else {
						for(;;){
							int fd = sockets[rand() % sockets.size()];
							if(attempt_bad_fds.count(fd) == 0){
								log_w(MODULE, "Trying to ignore fd=%i", fd);
								attempt_bad_fds.insert(fd);
								last_added_attempt_bad_fd = fd;
								return false;
							}
						}
					}
				} else {
					// Don't consume 100% CPU and flood logs
					usleep(1000 * 100);
					return false;
				}
			} else if(r == 0){
				// Nothing happened
				num_consequent_valid_selects++;
			} else {
				// Something happened
				num_consequent_valid_selects++;
				for(int fd : sockets){
					if(FD_ISSET(fd, &rfds)){
						log_d(MODULE, "FD_ISSET: %i", fd);
						active_sockets.push_back(fd);
					}
				}
			}
			if(!attempt_bad_fds.empty() && num_consequent_valid_selects > 5){
				log_w(MODULE, "Found bad fd: %d", last_added_attempt_bad_fd);
				bad_fds.insert(last_added_attempt_bad_fd);
				attempt_bad_fds.clear();
			}
			return true;
		}
	};
}
// vim: set noet ts=4 sw=4:
