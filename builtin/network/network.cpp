// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "network/api.h"
#include "core/log.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
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
	std::deque<char> socket_buffer;
	interface::PacketStream packet_stream;

	Peer(){}
	Peer(Id id, sp_<interface::TCPSocket> socket):
		id(id), socket(socket){}
};

struct Module: public interface::Module, public network::Interface
{
	interface::Server *m_server;
	sp_<interface::TCPSocket> m_listening_socket;
	sm_<Peer::Id, Peer> m_peers;
	sm_<int, Peer*> m_peers_by_socket;
	size_t m_next_peer_id = 1;
	bool m_will_restore_after_unload = false;

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
		if(m_listening_socket->good()){
			m_server->remove_socket_event(m_listening_socket->fd());
			if(m_will_restore_after_unload)
				m_listening_socket->release_fd();
		}
		for(auto pair : m_peers){
			const Peer &peer = pair.second;
			if(peer.socket->good()){
				m_server->remove_socket_event(peer.socket->fd());
				if(m_will_restore_after_unload)
					peer.socket->release_fd();
			}
		}
	}

	void init()
	{
		log_v(MODULE, "network init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:listen_event"));
		m_server->sub_event(this, Event::t("network:incoming_data"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start",           on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:listen_event", on_listen_event, interface::SocketEvent)
		EVENT_TYPEN("network:incoming_data", on_incoming_data, interface::SocketEvent)
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

	void on_unload()
	{
		log_v(MODULE, "on_unload");
		m_will_restore_after_unload = true;

		int listening_fd = m_listening_socket->fd();
		sv_<std::tuple<Peer::Id, int>> peer_restore_info;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			peer_restore_info.push_back(std::tuple<Peer::Id, int>(
					peer.id, peer.socket->fd()));
		}

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(listening_fd);
			ar(peer_restore_info);
		}
		m_server->tmp_store_data("network:restore_info", os.str());
	}

	void on_continue()
	{
		log_v(MODULE, "on_continue");
		ss_ data = m_server->tmp_restore_data("network:restore_info");
		// name, content, path
		int listening_fd;
		sv_<std::tuple<Peer::Id, int>> peer_restore_info;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(listening_fd);
			ar(peer_restore_info);
		}

		m_listening_socket.reset(interface::createTCPSocket(listening_fd));

		for(auto &tuple : peer_restore_info){
			Peer::Id peer_id = std::get<0>(tuple);
			int fd = std::get<1>(tuple);
			log_i(MODULE, "Restoring peer %i: fd=%i", peer_id, fd);
			sp_<interface::TCPSocket> socket(interface::createTCPSocket(fd));
			m_peers[peer_id] = Peer(peer_id, socket);
			m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
			m_server->add_socket_event(socket->fd(),
					Event::t("network:incoming_data"));
		}
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
		if(r == -1){
			if(errno == ECONNRESET){
				log_w(MODULE, "Peer %zu: Connection reset by peer", peer.id);
				return;
			}
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		}
		if(r == 0){
			log_i(MODULE, "Peer %zu disconnected", peer.id);

			PeerInfo pinfo;
			pinfo.id = peer.id;
			pinfo.address = peer.socket->get_remote_address();
			m_server->emit_event("network:client_disconnected", new OldClient(pinfo));

			m_server->remove_socket_event(peer.socket->fd());
			m_peers_by_socket.erase(peer.socket->fd());
			m_peers.erase(peer.id);
			return;
		}
		log_i(MODULE, "Received %zu bytes", r);
		peer.socket_buffer.insert(peer.socket_buffer.end(), buf, buf + r);

		peer.packet_stream.input(peer.socket_buffer,
		[&](const ss_ & name, const ss_ & data){
			// Emit event
			m_server->emit_event(ss_()+"network:packet_received/"+name,
					new Packet(peer.id, name, data));
		});
	}

	void send_u(Peer &peer, const ss_ &name, const ss_ &data)
	{
		peer.packet_stream.output(name, data, [&](const ss_ & packet_data){
			peer.socket->send_fd(packet_data);
		});
	}

	void send_u(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		// Grab Peer (which contains socket)
		auto it = m_peers.find(recipient);
		if(it == m_peers.end()){
			throw Exception(ss_()+"network::send(): Peer "+itos(recipient) +
					" doesn't exist");
		}
		Peer &peer = it->second;

		send_u(peer, name, data);
	}

	// Interface

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		log_i(MODULE, "network::send()");
		send_u(recipient, name, data);
	}

	sv_<PeerInfo::Id> list_peers()
	{
		sv_<PeerInfo::Id> result;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			result.push_back(peer.id);
		}
		return result;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
