#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/mutex.h"
#include "network/include/api.h"
#include "core/log.h"
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

struct PacketTypeRegistry
{
	sm_<ss_, Packet::Type> m_types;
	Packet::Type m_next_type = 100;

	Packet::Type get(const ss_ &name){
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		Packet::Type type = m_next_type++;
		m_types[name] = type;
		return type;
	}
};

struct Module: public interface::Module, public network::Interface
{
	interface::Mutex m_interface_mutex;
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	sm_<Peer::Id, Peer> m_peers;
	size_t m_next_peer_id = 1;
	PacketTypeRegistry m_packet_types;

	Module(interface::Server *server):
		interface::Module("network"),
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		log_v(MODULE, "network construct");
	}

	void init()
	{
		interface::MutexScope ms(m_interface_mutex);

		log_v(MODULE, "network init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:listen_event"));
	}

	~Module()
	{
		log_v(MODULE, "network destruct");
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		interface::MutexScope ms(m_interface_mutex);

		EVENT_VOIDN("core:start",           on_start)
		EVENT_TYPEN("network:listen_event", on_listen_event, interface::SocketEvent)
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}

	void on_start()
	{
		ss_ address = "any4";
		ss_ port = "20000";

		if(!m_listening_socket->bind_fd(address, port) ||
				!m_listening_socket->listen_fd()){
			log_i(MODULE, "Failed to bind to %s:%s", cs(address), cs(port));
		} else {
			log_i(MODULE, "Listening at %s:%s", cs(address), cs(port));
		}

		m_server->add_socket_event(m_listening_socket->fd(),
				Event::t("network:listen_event"));
	}

	void on_listen_event(const interface::SocketEvent &event)
	{
		log_i(MODULE, "network: on_listen_event(): fd=%i", event.fd);
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

	// Interface

	Packet::Type packet_type(const ss_ &name)
	{
		interface::MutexScope ms(m_interface_mutex);

		return m_packet_types.get(name);
	}

	void send(PeerInfo::Id recipient, const Packet::Type &type, const ss_ &data)
	{
		log_i(MODULE, "network::send()");
		interface::MutexScope ms(m_interface_mutex);

		auto it = m_peers.find(recipient);
		if(it == m_peers.end()){
			throw Exception(ss_()+"network::send(): Peer "+itos(recipient) +
					" doesn't exist");
		}
		Peer &peer = it->second;
		// TODO: Create actual packet including type and length
		peer.socket->send_fd(data);
	}

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		send(recipient, m_packet_types.get(name), data);
	}
};

extern "C" {
	EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
