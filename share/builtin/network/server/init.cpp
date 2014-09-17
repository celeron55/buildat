#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/mutex.h"
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

struct Module: public interface::Module, public network::Direct
{
	interface::Mutex m_interface_mutex;
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	sm_<Peer::Id, Peer> m_peers;
	size_t m_next_peer_id = 1;

	Module(interface::Server *server):
		interface::Module("network"),
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		std::cout<<"network construct"<<std::endl;
	}

	void init()
	{
		interface::MutexScope ms(m_interface_mutex);

		std::cout<<"network init"<<std::endl;
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:send"));
		m_server->sub_event(this, Event::t("network:listen_event"));
		m_server->sub_event(this, Event::t("network:get_packet_type"));
	}

	~Module()
	{
		std::cout<<"network destruct"<<std::endl;
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		interface::MutexScope ms(m_interface_mutex);

		EVENT_VOIDN("core:start",           on_start)
		EVENT_TYPEN("network:send",         on_send_packet,  Packet)
		EVENT_TYPEN("network:listen_event", on_listen_event, interface::SocketEvent)
		EVENT_TYPEN("network:get_packet_type", on_get_packet_type, Req_get_packet_type)
	}

	void* get_interface()
	{
		return dynamic_cast<Direct*>(this);
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
		// Create socket
		sp_<interface::TCPSocket> socket(interface::createTCPSocket());
		// Accept connection
		socket->accept_fd(*m_listening_socket.get());
		// Store socket
		Peer::Id peer_id = m_next_peer_id++;
		m_peers[peer_id] = Peer(peer_id, socket);
		// Emit event
		PeerInfo pinfo;
		pinfo.id = peer_id;
		pinfo.address = socket->get_remote_address();
		m_server->emit_event("network:new_client", new NewClient(pinfo));
	}

	void on_get_packet_type(const Req_get_packet_type &event)
	{
		std::cerr<<"network::on_get_packet_type(): name="<<event.name<<std::endl;
		Packet::Type type = 42;
		m_server->emit_event("network:get_packet_type_resp",
		                     new Resp_get_packet_type(type));
	}

	// Direct interface

	Packet::Type packet_type(const ss_ &name)
	{
		interface::MutexScope ms(m_interface_mutex);
	}

	void send(PeerInfo::Id recipient, const Packet::Type &type, const ss_ &data)
	{
		interface::MutexScope ms(m_interface_mutex);

		// TODO
	}
};

extern "C" {
	EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
