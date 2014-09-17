#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "network/include/api.h"
#include <iostream>

using interface::Event;

namespace network {

struct Peer
{
	typedef size_t Id;

	Id id = 0;
	sp_<interface::TCPSocket> socket;

	Peer(){}
	Peer(Id id, sp_<interface::TCPSocket> socket):
		id(id), socket(socket){}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	sm_<Peer::Id, Peer> m_peers;
	size_t m_next_peer_id = 1;

	Module(interface::Server *server):
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		std::cout<<"network construct"<<std::endl;
	}

	void init()
	{
		std::cout<<"network init"<<std::endl;
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:send"));
		m_server->sub_event(this, Event::t("network:listen_event"));
	}

	~Module()
	{
		std::cout<<"network destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		if(type == Event::t("core:start")){
			on_start();
		}
		if(type == Event::t("network:send")){
			on_send_packet(*static_cast<const Packet*>(p));
		}
		if(type == Event::t("network:listen_event")){
			on_listen_event(*static_cast<const interface::SocketEvent*>(p));
		}
	}

	void on_start()
	{
		ss_ address = "any4";
		ss_ port = "20000";

		if(!m_listening_socket->bind_fd(address, port) ||
		    !m_listening_socket->listen_fd()){
			std::cerr<<"Failed to bind to "<<address<<":"<<port<<std::endl;
		} else {
			std::cerr<<"Listening at "<<address<<":"<<port<<std::endl;
		}

		m_server->add_socket_event(m_listening_socket->fd(),
		                           Event::t("network:listen_event"));
	}

	void on_send_packet(const Packet &packet)
	{
		// TODO
	}

	void on_listen_event(const interface::SocketEvent &event)
	{
		std::cerr<<"network: on_listen_event(): fd="<<event.fd<<std::endl;
		sp_<interface::TCPSocket> socket(interface::createTCPSocket());
		socket->accept_fd(*m_listening_socket.get());
		Peer::Id peer_id = m_next_peer_id++;
		m_peers[peer_id] = Peer(peer_id, socket);
	}
};

extern "C" {
	EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
