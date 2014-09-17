#include "client/state.h"
#include "core/log.h"
#include "interface/tcpsocket.h"
//#include <cereal/archives/binary.hpp>
//#include <cereal/types/string.hpp>
#include <cstring>
#include <deque>
#include <sys/socket.h>
#define MODULE "__state"

namespace client {

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;
	std::deque<char> m_socket_buffer;

	CState():
		m_socket(interface::createTCPSocket())
	{}

	bool connect(const ss_ &address, const ss_ &port)
	{
		bool ok = m_socket->connect_fd(address, port);
		if(ok)
			log_i(MODULE, "client::State: Connect succeeded (%s:%s)",
					cs(address), cs(port));
		else
			log_i(MODULE, "client::State: Connect failed (%s:%s)",
					cs(address), cs(port));
		return ok;
	}

	bool send(const ss_ &data)
	{
		return m_socket->send_fd(data);
	}

	void update()
	{
		if(m_socket->wait_data(0)){
			read_socket();
			handle_socket_buffer();
		}
	}

	void read_socket()
	{
		int fd = m_socket->fd();
		char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1)
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		if(r == 0){
			log_i(MODULE, "Peer disconnected");
			return;
		}
		log_i(MODULE, "Received %zu bytes", r);
		m_socket_buffer.insert(m_socket_buffer.end(), buf, buf + r);
	}

	void handle_socket_buffer()
	{
		for(;;){
			if(m_socket_buffer.size() < 6)
				return;
			size_t type =
					m_socket_buffer[0]<<0 |
					m_socket_buffer[1]<<8;
			size_t size =
					m_socket_buffer[2]<<0 |
					m_socket_buffer[3]<<8 |
					m_socket_buffer[4]<<16 |
					m_socket_buffer[5]<<24;
			log_i(MODULE, "size=%zu", size);
			if(m_socket_buffer.size() < 6 + size)
				return;
			log_i(MODULE, "Received full packet; type=%zu, length=6+%zu",
					type, size);
			ss_ data(&m_socket_buffer[6], size);
			m_socket_buffer.erase(m_socket_buffer.begin(),
					m_socket_buffer.begin() + 6 + size);
			handle_packet(type, data);
		}
	}

	void handle_packet(size_t type, const ss_ &data)
	{
	}
};

State* createState()
{
	return new CState();
}
}
