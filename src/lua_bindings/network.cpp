// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
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
	#include <netinet/tcp.h>
	#include <netdb.h>
#endif
#include <luabind/luabind.hpp>
#include <string.h>
#include <vector>
#define MODULE "lua_bindings"

// Sockets for Lua. This is the raw layer; it does not ask the user about
// anything. The extension environment guards it (extensions/network).
//
// The connect functions always return a socket object; if the connection could
// not be made, socket:good() is false and socket:error() tells why.

namespace lua_bindings {

// TCP connect blocks for up to this long. simplified: no connecting state to
// poll from Lua; a slow peer stalls one frame. Upgrade path if that shows up:
// keep the socket in a connecting state and finish it in receive()/send().
static const int TCP_CONNECT_TIMEOUT_MS = 5000;

static const size_t RECEIVE_BUFFER_SIZE = 65536;

static void close_socket_fd(int fd)
{
#ifdef _WIN32
	closesocket(fd);
#else
	::close(fd);
#endif
}

static ss_ last_socket_error()
{
#ifdef _WIN32
	char buf[128];
	snprintf(buf, sizeof buf, "winsock error %i", WSAGetLastError());
	return buf;
#else
	return strerror(errno);
#endif
}

static bool would_block()
{
#ifdef _WIN32
	int e = WSAGetLastError();
	return e == WSAEWOULDBLOCK || e == WSAEINPROGRESS;
#else
	return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR;
#endif
}

static bool connect_in_progress()
{
#ifdef _WIN32
	return WSAGetLastError() == WSAEWOULDBLOCK;
#else
	return errno == EINPROGRESS;
#endif
}

static bool set_nonblocking(int fd)
{
#ifdef _WIN32
	u_long on = 1;
	return ioctlsocket(fd, FIONBIO, &on) == 0;
#else
	int flags = fcntl(fd, F_GETFL, 0);
	if(flags == -1)
		return false;
	return fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
#endif
}

struct LuaSocket
{
	int m_fd = -1;
	bool m_udp = false;
	ss_ m_remote; // "host:port" as given by the caller
	ss_ m_error;

	LuaSocket(bool udp, const ss_ &remote):
		m_udp(udp), m_remote(remote)
	{}

	~LuaSocket()
	{
		close();
	}

	void fail(const ss_ &error)
	{
		m_error = error;
		close();
	}

	// Waits until the non-blocking connect() on m_fd finishes
	bool wait_connected()
	{
		struct timeval tv;
		tv.tv_sec = TCP_CONNECT_TIMEOUT_MS / 1000;
		tv.tv_usec = (TCP_CONNECT_TIMEOUT_MS % 1000) * 1000;
		fd_set wfds;
		FD_ZERO(&wfds);
		FD_SET(m_fd, &wfds);
		int r = select(m_fd + 1, NULL, &wfds, NULL, &tv);
		if(r == 0){
			m_error = "connect timed out";
			return false;
		}
		if(r < 0){
			m_error = "select: "+last_socket_error();
			return false;
		}
		int so_error = 0;
		socklen_t len = sizeof(so_error);
		if(getsockopt(m_fd, SOL_SOCKET, SO_ERROR, (char*)&so_error, &len) != 0){
			m_error = "getsockopt: "+last_socket_error();
			return false;
		}
		if(so_error != 0){
			m_error = "connect: "+ss_(strerror(so_error));
			return false;
		}
		return true;
	}

	bool connect_to(const ss_ &host, const ss_ &port)
	{
		struct addrinfo hints;
		memset(&hints, 0, sizeof(hints));
		hints.ai_family = AF_UNSPEC;
		hints.ai_socktype = m_udp ? SOCK_DGRAM : SOCK_STREAM;
		struct addrinfo *res0 = NULL;
		int err = getaddrinfo(host.c_str(), port.c_str(), &hints, &res0);
		if(err || res0 == NULL){
			m_error = ss_("getaddrinfo: ")+gai_strerror(err);
			return false;
		}
		m_error = "no address to connect to";
		for(struct addrinfo *res = res0; res != NULL; res = res->ai_next){
			int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
			if(fd == -1){
				m_error = "socket: "+last_socket_error();
				continue;
			}
			if(!set_nonblocking(fd)){
				m_error = "failed to set socket non-blocking";
				close_socket_fd(fd);
				continue;
			}
			m_fd = fd;
			// UDP connect() only sets the default peer; it does not block.
			// It also makes the socket drop datagrams from anyone else.
			if(connect(fd, res->ai_addr, res->ai_addrlen) == 0)
				break;
			if(!m_udp && connect_in_progress()){
				if(wait_connected()) // Sets m_error if it fails
					break;
			} else {
				m_error = "connect: "+last_socket_error();
			}
			close();
		}
		freeaddrinfo(res0);
		if(m_fd == -1)
			return false;
		m_error = "";
		if(!m_udp){
			int val = 1;
			setsockopt(m_fd, IPPROTO_TCP, TCP_NODELAY, (const char*)&val,
					sizeof(val));
		}
		return true;
	}

	// Lua interface

	bool good() const
	{
		return m_fd != -1;
	}

	ss_ error() const
	{
		return m_error;
	}

	ss_ address() const
	{
		return m_remote;
	}

	// send(data) -> was everything sent
	bool send(const ss_ &data)
	{
		if(m_fd == -1)
			return false;
		size_t sent_total = 0;
		while(sent_total < data.size()){
			int sent = ::send(m_fd, &data[sent_total], data.size() - sent_total, 0);
			if(sent < 0){
				if(would_block()){
					// simplified: no send queue. TCP writers should retry with
					// what wasn't sent; UDP datagrams are all-or-nothing anyway.
					return false;
				}
				fail("send: "+last_socket_error());
				return false;
			}
			if(m_udp)
				return (size_t)sent == data.size();
			sent_total += sent;
		}
		return true;
	}

	// receive() -> data; "" means nothing was available. If the peer closed the
	// connection or the socket errored, good() turns false.
	ss_ receive()
	{
		if(m_fd == -1)
			return "";
		std::vector<char> buf(RECEIVE_BUFFER_SIZE);
		int r = recv(m_fd, &buf[0], buf.size(), 0);
		if(r == 0){
			if(!m_udp){
				fail("peer closed the connection");
				return "";
			}
			return ""; // Empty datagram; indistinguishable from nothing
		}
		if(r < 0){
			if(would_block())
				return "";
			fail("recv: "+last_socket_error());
			return "";
		}
		return ss_(&buf[0], r);
	}

	void close()
	{
		if(m_fd != -1){
			close_socket_fd(m_fd);
			m_fd = -1;
		}
	}
};

static sp_<LuaSocket> connect_socket(bool udp, const ss_ &host, const ss_ &port)
{
	sp_<LuaSocket> socket(new LuaSocket(udp, host+":"+port));
	if(!socket->connect_to(host, port)){
		log_w(MODULE, "%s connect to %s:%s failed: %s", udp ? "udp" : "tcp",
				cs(host), cs(port), cs(socket->error()));
	} else {
		log_v(MODULE, "%s socket connected to %s:%s", udp ? "udp" : "tcp",
				cs(host), cs(port));
	}
	return socket;
}

static sp_<LuaSocket> tcp_connect(const ss_ &host, const ss_ &port)
{
	return connect_socket(false, host, port);
}

static sp_<LuaSocket> udp_connect(const ss_ &host, const ss_ &port)
{
	return connect_socket(true, host, port);
}

void init_network(lua_State *L)
{
	using namespace luabind;

	module(L)[
		class_<LuaSocket, bases<>, sp_<LuaSocket>>("Socket")
			.def("good", &LuaSocket::good)
			.def("error", &LuaSocket::error)
			.def("address", &LuaSocket::address)
			.def("send", &LuaSocket::send)
			.def("receive", &LuaSocket::receive)
			.def("close", &LuaSocket::close),
		def("__buildat_tcp_connect", &tcp_connect),
		def("__buildat_udp_connect", &udp_connect)
	];
}

} // namespace lua_bindings

// codestyle:disable (currently util/codestyle.sh screws up the .def formatting)
// vim: set noet ts=4 sw=4:
