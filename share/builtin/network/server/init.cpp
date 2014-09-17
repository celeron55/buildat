#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
//#include "network/include/api.h"
#include <iostream>

using interface::Event;

namespace network {

struct Module: public interface::Module
{
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_socket;

	Module(interface::Server *server):
		m_server(server),
		m_socket(interface::createTCPSocket())
	{
		std::cout<<"network construct"<<std::endl;

		ss_ address = "any";
		ss_ port = "20000";

		if(!m_socket->bind_fd(address, port)){
			std::cerr<<"Failed to bind to "<<address<<":"<<port<<std::endl;
		} else {
			std::cerr<<"Listening at "<<address<<":"<<port<<std::endl;
		}
	}

	~Module()
	{
		std::cout<<"network destruct"<<std::endl;
	}

	void event(const interface::Event &event)
	{
	}
};

extern "C" {
	EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
