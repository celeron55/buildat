#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "network/include/api.h"
#include "core/log.h"
//#include <cereal/archives/binary.hpp>
//#include <cereal/types/string.hpp>
#include <deque>
#include <sys/socket.h>
#include <cstring> // strerror()

using interface::Event;

namespace network {

struct Peer
{
	typedef size_t Id;

	Id id = 0;
	sp_<interface::TCPSocket> socket;
	Packet::Type highest_known_type = 99;
	std::deque<char> socket_buffer;

	Peer(){}
	Peer(Id id, sp_<interface::TCPSocket> socket):
		id(id), socket(socket){}
};

struct PacketTypeRegistry
{
	sm_<ss_, Packet::Type> m_types;
	sm_<Packet::Type, ss_> m_names;
	Packet::Type m_next_type = 100;

	Packet::Type get(const ss_ &name){
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		Packet::Type type = m_next_type++;
		m_types[name] = type;
		m_names[type] = name;
		return type;
	}
	ss_ get_name(Packet::Type type){
		auto it = m_names.find(type);
		if(it != m_names.end())
			return it->second;
		return "";
	}
};

struct Module: public interface::Module, public network::Interface
{
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	sm_<Peer::Id, Peer> m_peers;
	sm_<int, Peer*> m_peers_by_socket;
	size_t m_next_peer_id = 1;
	PacketTypeRegistry m_packet_types;

	Module(interface::Server *server):
		interface::Module("network"),
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		log_v(MODULE, "network construct");
	}

	~Module()
	{
		log_v(MODULE, "network destruct");
		if(m_listening_socket->good())
			m_server->remove_socket_event(m_listening_socket->fd());
	}

	void init()
	{
		log_v(MODULE, "network init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:listen_event"));
		m_server->sub_event(this, Event::t("network:incoming_data"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",           on_start)
		EVENT_TYPEN("network:listen_event", on_listen_event, interface::SocketEvent)
		EVENT_TYPEN("network:incoming_data", on_incoming_data, interface::SocketEvent)
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
			log_i(MODULE, "Failed to bind to %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
		} else {
			log_i(MODULE, "Listening at %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
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
		m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
		// Emit event
		PeerInfo pinfo;
		pinfo.id = peer_id;
		pinfo.address = socket->get_remote_address();
		m_server->emit_event("network:new_client", new NewClient(pinfo));
		m_server->add_socket_event(socket->fd(),
				Event::t("network:incoming_data"));
	}

	void on_incoming_data(const interface::SocketEvent &event)
	{
		log_i(MODULE, "network: on_incoming_data(): fd=%i", event.fd);

		auto it = m_peers_by_socket.find(event.fd);
		if(it == m_peers_by_socket.end()){
			log_w(MODULE, "network: Peer with fd=%i not found", event.fd);
			return;
		}
		Peer &peer = *it->second;

		int fd = peer.socket->fd();
		if(fd != event.fd)
			throw Exception("on_incoming_data: fds don't match");
		char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1)
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		if(r == 0){
			log_i(MODULE, "Peer %zu disconnected", peer.id);
			m_server->remove_socket_event(peer.socket->fd());
			m_peers_by_socket.erase(peer.socket->fd());
			m_peers.erase(peer.id);
			return;
		}
		log_i(MODULE, "Received %zu bytes", r);
		peer.socket_buffer.insert(peer.socket_buffer.end(), buf, buf + r);

		for(;;){
			if(peer.socket_buffer.size() < 6)
				return;
			size_t type =
					peer.socket_buffer[0]<<0 |
					peer.socket_buffer[1]<<8;
			size_t size =
					peer.socket_buffer[2]<<0 |
					peer.socket_buffer[3]<<8 |
					peer.socket_buffer[4]<<16 |
					peer.socket_buffer[5]<<24;
			log_i(MODULE, "size=%zu", size);
			if(peer.socket_buffer.size() < 6 + size)
				return;
			log_i(MODULE, "Received full packet; type=%zu, length=6+%zu",
					type, size);
			ss_ data(&peer.socket_buffer[6], size);
			peer.socket_buffer.erase(peer.socket_buffer.begin(),
					peer.socket_buffer.begin() + 6 + size);

			// Emit event
			m_server->emit_event("network:packet_received",
					new Packet(0, type, data));
		}
	}

	void send_u(Peer &peer, const Packet::Type &type, const ss_ &data)
	{
		// Send new packet types if needed
		if(m_packet_types.m_next_type > peer.highest_known_type + 1){
			Packet::Type highest_known_type_was = peer.highest_known_type;
			peer.highest_known_type = m_packet_types.m_next_type - 1;
			for(Packet::Type t1 = highest_known_type_was;
					t1 < m_packet_types.m_next_type; t1++){
				std::ostringstream os(std::ios::binary);
				os<<(char)((t1>>0) & 0xff);
				os<<(char)((t1>>8) & 0xff);
				ss_ name = m_packet_types.get_name(t1);
				os<<(char)((name.size()>>0) & 0xff);
				os<<(char)((name.size()>>8) & 0xff);
				os<<(char)((name.size()>>16) & 0xff);
				os<<(char)((name.size()>>24) & 0xff);
				os<<name;
				send_u(peer, 0, os.str());
			}
		}

		// Create actual packet including type and length
		std::ostringstream os(std::ios::binary);
		os<<(char)((type>>0) & 0xff);
		os<<(char)((type>>8) & 0xff);
		os<<(char)((data.size()>>0) & 0xff);
		os<<(char)((data.size()>>8) & 0xff);
		os<<(char)((data.size()>>16) & 0xff);
		os<<(char)((data.size()>>24) & 0xff);
		os<<data;

		// Send packet
		peer.socket->send_fd(os.str());
	}

	void send_u(PeerInfo::Id recipient, const Packet::Type &type, const ss_ &data)
	{
		// Grab Peer (which contains socket)
		auto it = m_peers.find(recipient);
		if(it == m_peers.end()){
			throw Exception(ss_()+"network::send(): Peer "+itos(recipient) +
					" doesn't exist");
		}
		Peer &peer = it->second;

		send_u(peer, type, data);
	}

	// Interface

	Packet::Type packet_type(const ss_ &name)
	{
		return m_packet_types.get(name);
	}

	void send(PeerInfo::Id recipient, const Packet::Type &type, const ss_ &data)
	{
		log_i(MODULE, "network::send()");
		send_u(recipient, type, data);
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
