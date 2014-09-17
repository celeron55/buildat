#include "client/state.h"
#include "interface/tcpsocket.h"
#include <iostream>
#include <cstring>
#include <sys/socket.h>

namespace client {

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;

	CState():
		m_socket(interface::createTCPSocket())
	{}

	bool connect(const ss_ &address, const ss_ &port)
	{
		bool ok = m_socket->connect_fd(address, port);
		if(ok)
			std::cerr<<"client::State: Connect succeeded ("
					<<address<<":"<<port<<")"<<std::endl;
		else
			std::cerr<<"client::State: Connect failed ("
					<<address<<":"<<port<<")"<<std::endl;
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
		}
	}

	void read_socket()
	{
		int fd = m_socket->fd();
		char buf[1000];
		ssize_t r = recv(fd, buf, 1000, 0);
		if(r == -1)
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		if(r == 0){
			std::cerr<<"Peer disconnected"<<std::endl;
			return;
		}
		std::cerr<<"Received "<<r<<" bytes"<<std::endl;
	}
};

State* createState()
{
	return new CState();
}
}
