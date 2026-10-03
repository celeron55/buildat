// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/tcpsocket.h"
#include "core/log.h"
#ifdef _WIN32
	#include "ports/windows_sockets.h"
#else
	#include <unistd.h>
	#include <sys/types.h>
	#include <sys/socket.h>
	#include <errno.h>
	#include <fcntl.h>
	#include <netinet/in.h>
	#include <netdb.h>
	#define closesocket close
//typedef int socket_t;
#endif
#include <string.h> // strerror()
#include <stdlib.h> // getenv()
#include <iostream>
#include <iomanip>

namespace interface {

const unsigned char prefix[] = {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0xFF, 0xFF};

bool sockaddr_to_bytes(const sockaddr_storage *ptr, sv_<uchar> &to)
{
	if(ptr->ss_family == AF_INET)
	{
		uchar *u = (uchar*)&((struct sockaddr_in*)ptr)->sin_addr.s_addr;
		to.assign(u, u + 4);
		return true;
	}
	else if(ptr->ss_family == AF_INET6)
	{
		uchar *u = (uchar*)&((struct sockaddr_in6*)ptr)->sin6_addr.s6_addr;
		if(memcmp(prefix, u, sizeof(prefix)) == 0){
			to.assign(u + 12, u + 16);
			return true;
		}
		to.assign(u, u + 16);
		return true;
	}

	return false;
}

std::string address_bytes_to_string(const sv_<uchar> &ip)
{
	std::ostringstream os;
	for(size_t i = 0; i < ip.size(); i++){
		if(ip.size() == 4){
			os<<std::dec<<std::setfill('0')<<std::setw(0)
					<<((uint32_t)ip[i] & 0xff);
			if(i < ip.size() - 1)
				os<<".";
		} else {
			os<<std::hex<<std::setfill('0')<<std::setw(2)
					<<((uint32_t)ip[i] & 0xff);
			i++;
			if(i < ip.size())
				os<<std::hex<<std::setfill('0')<<std::setw(2)
					<<((uint32_t)ip[i] & 0xff);
			if(i < ip.size() - 1)
				os<<":";
		}
	}
	return os.str();
}


struct CTCPSocket: public TCPSocket
{
	int m_fd = -1;

	CTCPSocket(int fd = -1):
		m_fd(fd)
	{}
	~CTCPSocket()
	{
		close_fd();
	}
	int fd() const
	{
		return m_fd;
	}
	bool good() const
	{
		return (m_fd != -1);
	}
	void release_fd()
	{
		m_fd = -1;
	}
	void close_fd()
	{
		if(m_fd != -1)
			closesocket(m_fd);
		m_fd = -1;
	}
	bool listen_fd()
	{
		if(m_fd == -1)
			return false;
		if(listen(m_fd, 5) == -1){
			std::cerr<<"TCPSocket::listen_fd(): "<<strerror(errno)<<std::endl;
			return false;
		}
		return true;
	}
	static bool connect_with_timeout(int fd, const struct sockaddr *addr,
			socklen_t addrlen, int timeout_ms)
	{
#ifdef _WIN32
		u_long on = 1;
		ioctlsocket(fd, FIONBIO, &on);
#else
		const int flags = fcntl(fd, F_GETFL, 0);
		fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
		bool ok = false;
		int r = connect(fd, addr, addrlen);
		if(r == 0){
			ok = true;
		} else {
#ifdef _WIN32
			const bool pending = WSAGetLastError() == WSAEWOULDBLOCK;
#else
			const bool pending = errno == EINPROGRESS;
#endif
#ifdef __EMSCRIPTEN__
			// The web client's socket is a WebSocket ([WEB_CLIENT]): a
			// select cannot wait for it to open, and it need not, because
			// what is sent before it is open is queued for it. A server
			// that is not there shows as the connection closing.
			if(pending)
				ok = true;
			else
#endif
			if(pending){
				fd_set wfds;
				FD_ZERO(&wfds);
				FD_SET(fd, &wfds);
				struct timeval tv = {timeout_ms / 1000, (timeout_ms % 1000) * 1000};
				if(select(fd + 1, NULL, &wfds, NULL, &tv) > 0){
					int soerr = 0;
					socklen_t len = sizeof(soerr);
					if(getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&soerr,
							&len) == 0 && soerr == 0)
						ok = true;
					else
						std::cerr<<"connect: error "<<soerr<<std::endl;
				} else {
					std::cerr<<"connect: no answer in "<<timeout_ms<<" ms"<<std::endl;
				}
			} else {
#ifndef _WIN32
				// [PROCESS_SANDBOX]: the box refuses a port at once
				if(errno == EACCES && addr->sa_family != AF_UNIX){
					const int p = ntohs(addr->sa_family == AF_INET6 ?
							((const sockaddr_in6*)addr)->sin6_port :
							((const sockaddr_in*)addr)->sin_port);
					std::cerr<<"connect: the server's box refused port "<<p<<
							"; its admin allows it with --connect-ports"<<std::endl;
				} else
#endif
				std::cerr<<"connect: "<<strerror(errno)<<std::endl;
			}
		}
#ifdef _WIN32
		on = 0;
		ioctlsocket(fd, FIONBIO, &on);
#else
		fcntl(fd, F_SETFL, flags);
#endif
		return ok;
	}

	bool connect_fd(const ss_ &address, const ss_ &port)
	{
		close_fd();

		struct addrinfo hints;
		struct addrinfo *res0 = NULL;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;
		hints.ai_protocol = IPPROTO_TCP;
		if(address == "any")
			hints.ai_flags = AI_PASSIVE; // Wildcard address
		const char *address_c = (address == "any" ? NULL : address.c_str());
		const char *port_c = (port == "any" ? NULL : port.c_str());
		int err = getaddrinfo(address_c, port_c, &hints, &res0);
		if(err){
			std::cerr<<"getaddrinfo: "<<gai_strerror(err)<<std::endl;
			return false;
		}
		if(res0 == NULL){
			std::cerr<<"getaddrinfo: No results"<<std::endl;
			return false;
		}

		// Try to use one of the results
		int fd = -1;
		int i = 0;
		for(struct addrinfo *res = res0; res != NULL; res = res->ai_next, i++)
		{
			std::cerr<<"Trying addrinfo #"<<i<<std::endl;
			int try_fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
			if(try_fd == -1){
				std::cerr<<"socket: "<<strerror(errno)<<std::endl;
				continue;
			}
			// A connect with a ceiling, not a blocking one: the client's
			// main thread sat in Winsock's connect for good when it
			// connected to a local server that was not yet listening (the
			// box's dump, 2026-09-21 -- the waiting screen had read a
			// stale "Listening"); on Windows a SYN to a closed port is
			// retried for seconds, and nothing in the frame loop ran.
			// Non-blocking, a select of five seconds, then blocking again
			// for the stream the socket is used as ([WIN8_START] 14).
			if(!connect_with_timeout(try_fd, res->ai_addr, res->ai_addrlen,
					5000)){
				closesocket(try_fd);
				continue;
			}
			fd = try_fd;
			break;
		}
		freeaddrinfo(res0);

		if(fd == -1){
			std::cerr<<"Failed to create and connect socket"<<std::endl;
			return false;
		}

		int val = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&val, sizeof(val));

#ifndef _WIN32
		// Set this so that forked child processes don't prevent re-opening the
		// same port after crash
		if(fcntl(fd, F_SETFD, FD_CLOEXEC) != 0){
			std::cerr<<"Failed to set socket FD_CLOEXEC"<<std::endl;
			return false;
		}
#endif

		m_fd = fd;
		return true;
	}
	bool bind_fd(const ss_ &address, const ss_ &port)
	{
		close_fd();

		struct addrinfo hints;
		struct addrinfo *res0 = NULL;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;
		hints.ai_protocol = IPPROTO_TCP;
		std::string address1 = address;
		if(address1 == "any4"){
			address1 = "any";
			hints.ai_family = AF_INET;
		}
		if(address1 == "any6"){
			address1 = "any";
			hints.ai_family = AF_INET6;
		}
		if(address1 == "any"){
			hints.ai_flags = AI_PASSIVE; // Wildcard address
		}
		const char *address_c = (address1 == "any" ? NULL : address1.c_str());
		const char *port_c = (port == "any" ? NULL : port.c_str());
		int err = getaddrinfo(address_c, port_c, &hints, &res0);
		if(err){
			std::cerr<<"getaddrinfo: "<<gai_strerror(err)<<std::endl;
			return false;
		}
		if(res0 == NULL){
			std::cerr<<"getaddrinfo: No results"<<std::endl;
			return false;
		}

		// Try to use one of the results
		int fd = -1;
		int i = 0;
		for(struct addrinfo *res = res0; res != NULL; res = res->ai_next, i++)
		{
			//std::cerr<<"Trying addrinfo #"<<i<<std::endl;
			int try_fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
			if(try_fd == -1){
				//std::cerr<<"socket: "<<strerror(errno)<<std::endl;
				continue;
			}
			int val = 1;
			setsockopt(try_fd, SOL_SOCKET, SO_REUSEADDR, (const char*)&val,
					sizeof(val));
#ifdef SO_REUSEPORT
			// **The port shared with a stand-in** that answers browsers
			// while the server restarts (util/serve_latest_release.sh), only
			// when asked: otherwise a second server on the port fails to
			// bind, as it should
			const char *share = getenv("BUILDAT_SHARE_PORT");
			if(share && strcmp(share, "1") == 0)
				setsockopt(try_fd, SOL_SOCKET, SO_REUSEPORT, (const char*)&val,
						sizeof(val));
#endif
			if(res->ai_family == AF_INET6){
				int val = 1;
				setsockopt(try_fd, IPPROTO_IPV6, IPV6_V6ONLY, (const char*)&val,
						sizeof(val));
			}
			if(bind(try_fd, res->ai_addr, res->ai_addrlen) == -1){
				std::cerr<<"bind(): "<<strerror(errno)<<std::endl;
				closesocket(try_fd);
				continue;
			}
			fd = try_fd;
			break;
		}
		freeaddrinfo(res0);

		if(fd == -1){
			std::cerr<<"Failed to create and bind socket"<<std::endl;
			return false;
		}

#ifndef _WIN32
		// Set this so that forked child processes don't prevent re-opening the
		// same port after crash
		if(fcntl(fd, F_SETFD, FD_CLOEXEC) != 0){
			std::cerr<<"Failed to set socket FD_CLOEXEC"<<std::endl;
			return false;
		}
#endif

		m_fd = fd;
		return true;
	}
	bool accept_fd(const TCPSocket &listener)
	{
		close_fd();

		if(!listener.good())
			return false;

		struct sockaddr_storage pin;
		socklen_t pin_len = sizeof(pin);
		int fd_client = accept(listener.fd(), (struct sockaddr*)&pin, &pin_len);
		if(fd_client == -1){
			std::cerr<<"accept: "<<strerror(errno)<<std::endl;
			return false;
		}

		int val = 1;
		setsockopt(fd_client, SOL_SOCKET, SO_REUSEADDR, (const char*)&val,
				sizeof(val));
		// A small send buffer, so that what waits for a slow peer waits in
		// the network module's queue, where a LatestOnly packet can go
		// ahead of it ([NET_CHANNELS]) -- not in the kernel, where the
		// autotuned 4 MB is minutes at a lossy link's rate and nothing
		// passes it. simplified: 64 KB a round trip caps a peer at some
		// 800 kB/s over 80 ms; a transport with its own window ([TRANSPORT])
		// lifts this.
		int sndbuf = 64 * 1024;
		setsockopt(fd_client, SOL_SOCKET, SO_SNDBUF, (const char*)&sndbuf,
				sizeof(sndbuf));

		m_fd = fd_client;
		return true;
	}
#ifdef __EMSCRIPTEN__
	// The web client's socket is a WebSocket ([WEB_CLIENT]), which refuses
	// a send while it is still opening, and a browser never blocks: what
	// does not go now waits here, and goes on the next send or wait_data()
	ss_ m_web_unsent;
	bool flush_web_unsent()
	{
		if(m_web_unsent.empty())
			return true;
		ssize_t n = send(m_fd, &m_web_unsent[0], m_web_unsent.size(), 0);
		if(n < 0){
			if(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
				return true;
			std::cerr<<"send: "<<strerror(errno)<<std::endl;
			return false;
		}
		m_web_unsent.erase(0, (size_t)n);
		return true;
	}
#endif
	bool send_fd(const ss_ &data)
	{
		if(m_fd == -1)
			return false;
#ifdef __EMSCRIPTEN__
		m_web_unsent += data;
		return flush_web_unsent();
#endif
		if(send(m_fd, &data[0], data.size(), 0) == -1){
			std::cerr<<"send: "<<strerror(errno)<<std::endl;
			return false;
		}
		return true;
	}
	bool set_nonblocking(bool nonblocking)
	{
		if(m_fd == -1)
			return false;
#ifdef _WIN32
		u_long on = nonblocking ? 1 : 0;
		return ioctlsocket(m_fd, FIONBIO, &on) == 0;
#else
		int flags = fcntl(m_fd, F_GETFL, 0);
		if(flags == -1)
			return false;
		if(nonblocking)
			flags |= O_NONBLOCK;
		else
			flags &= ~O_NONBLOCK;
		return fcntl(m_fd, F_SETFL, flags) == 0;
#endif
	}
	// What fits, and how much that was. A socket whose buffer is full is not
	// an error: nothing goes, `sent` is zero and the caller keeps the rest.
	bool send_some(const ss_ &data, size_t offset, size_t *sent)
	{
		*sent = 0;
		if(m_fd == -1)
			return false;
		if(offset >= data.size())
			return true;
		ssize_t n = send(m_fd, &data[offset], data.size() - offset, 0);
		if(n < 0){
#ifdef _WIN32
			// Winsock says "would block" its own way, and errno says nothing
			if(WSAGetLastError() == WSAEWOULDBLOCK)
				return true;
#else
			if(errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
				return true;
#endif
			std::cerr<<"send: "<<strerror(errno)<<std::endl;
			return false;
		}
		*sent = (size_t)n;
		return true;
	}
	bool wait_data(int timeout_us)
	{
		if(m_fd == -1)
			return false;
#ifdef __EMSCRIPTEN__
		flush_web_unsent();
#endif

		struct timeval tv;
		tv.tv_sec = 0;
		tv.tv_usec = timeout_us;

		fd_set rfds;
		FD_ZERO(&rfds);
		int fd_max = m_fd;
		FD_SET(m_fd, &rfds);

		int r = select(fd_max + 1, &rfds, NULL, NULL, &tv);
		if(r == -1){
			// Error
			log_w("tcpsocket", "select() returned -1: %s", strerror(errno));
			return false;
		} else if(r == 0){
			// Nothing happened
			return false;
		} else {
			// Something happened
			if(FD_ISSET(m_fd, &rfds)){
				log_d("tcpsocket", "FD_ISSET: %i", m_fd);
				return true;
			}
		}
		return false;
	}
	ss_ get_local_address() const
	{
		if(m_fd == -1)
			return "";
		struct sockaddr_storage sa;
		socklen_t sa_len = sizeof(sa);
		if(getsockname(m_fd, (sockaddr*)&sa, &sa_len) == -1)
			return "";
		sv_<uchar> a;
		if(!sockaddr_to_bytes(&sa, a))
			return "";
		return address_bytes_to_string(a);
	}
	ss_ get_remote_address() const
	{
		if(m_fd == -1)
			return "";
		struct sockaddr_storage sa;
		socklen_t sa_len = sizeof(sa);
		if(getpeername(m_fd, (sockaddr*)&sa, &sa_len) == -1)
			return "";
		sv_<uchar> a;
		if(!sockaddr_to_bytes(&sa, a))
			return "";
		return address_bytes_to_string(a);
	}
};

TCPSocket* createTCPSocket(int fd)
{
	return new CTCPSocket(fd);
}

// Whether something accepts on the address, within 50 ms: a non-blocking
// connect and a select on it. A blocking connect here stalled the
// launcher's waiting screen, which asks every frame -- Winsock retries a
// SYN to a closed port for about a second, and behind the firewall's
// first-run prompt the connect timeout -- so the screen froze and the
// client never came back ([WIN8_START]). A port that is not listening
// yet answers "no" inside the 50 ms on every platform.
ss_ local_lan_address()
{
	// A UDP socket connected anywhere outside the LAN has the address the
	// route out of it uses; connect() on UDP sends nothing. 192.0.2.1 is
	// TEST-NET-1, which no one answers to.
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if(fd == -1)
		return "";
	struct sockaddr_in to;
	memset(&to, 0, sizeof(to));
	to.sin_family = AF_INET;
	to.sin_port = htons(9);
	to.sin_addr.s_addr = htonl(0xc0000201);
	ss_ out;
	if(connect(fd, (struct sockaddr*)&to, sizeof(to)) == 0){
		struct sockaddr_in me;
		socklen_t len = sizeof(me);
		if(getsockname(fd, (struct sockaddr*)&me, &len) == 0){
			const uint32_t a = ntohl(me.sin_addr.s_addr);
			if(a != 0 && (a >> 24) != 127){
				char buf[32];
				snprintf(buf, sizeof buf, "%u.%u.%u.%u", (a >> 24) & 255,
						(a >> 16) & 255, (a >> 8) & 255, a & 255);
				out = buf;
			}
		}
	}
	closesocket(fd);
	return out;
}

bool probe_connect(const ss_ &address, const ss_ &port)
{
	struct addrinfo hints;
	struct addrinfo *res0 = NULL;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_UNSPEC;
	hints.ai_socktype = SOCK_STREAM;
	hints.ai_protocol = IPPROTO_TCP;
	int err = getaddrinfo(address.c_str(), port.c_str(), &hints, &res0);
	if(err || res0 == NULL)
		return false;
	bool ok = false;
	for(struct addrinfo *res = res0; res != NULL; res = res->ai_next){
		int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
		if(fd == -1)
			continue;
#ifdef _WIN32
		u_long on = 1;
		ioctlsocket(fd, FIONBIO, &on);
#else
		fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
#endif
		int r = connect(fd, res->ai_addr, res->ai_addrlen);
		if(r == 0){
			ok = true;
		} else {
#ifdef _WIN32
			const bool pending = WSAGetLastError() == WSAEWOULDBLOCK;
#else
			const bool pending = errno == EINPROGRESS;
#endif
			if(pending){
				fd_set wfds;
				FD_ZERO(&wfds);
				FD_SET(fd, &wfds);
				struct timeval tv = {0, 50000};
				if(select(fd + 1, NULL, &wfds, NULL, &tv) > 0){
					int soerr = 0;
					socklen_t len = sizeof(soerr);
					if(getsockopt(fd, SOL_SOCKET, SO_ERROR, (char*)&soerr,
							&len) == 0 && soerr == 0)
						ok = true;
				}
			}
		}
		closesocket(fd);
		if(ok)
			break;
	}
	freeaddrinfo(res0);
	return ok;
}

}
// vim: set noet ts=4 sw=4:
