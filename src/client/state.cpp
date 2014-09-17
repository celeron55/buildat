#include "client/state.h"
#include "interface/tcpsocket.h"
#include <iostream>

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
};

State* createState()
{
	return new CState();
}
}
