// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/thread.h"
#include "interface/select_handler.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
#include <deque>
#ifdef _WIN32
	#include "ports/windows_sockets.h"
	#include "ports/windows_compat.h" // usleep()
#else
	#include <sys/socket.h>
	#include <unistd.h> // usleep()
#endif
#include <errno.h>
#define MODULE "network"

using interface::Event;

namespace network {

struct Module;

struct NetworkThread: public interface::ThreadedThing
{
	Module *m_module = nullptr;

	NetworkThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

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
	up_<interface::Thread> m_thread;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server),
		m_listening_socket(interface::createTCPSocket())
	{
		log_d(MODULE, "network construct");
	}

	~Module()
	{
		log_d(MODULE, "network destruct");

		m_thread->request_stop();
		m_thread->join();

		if(m_will_restore_after_unload){
			if(m_listening_socket->good()){
				m_listening_socket->release_fd();
			}
			for(auto pair : m_peers){
				const Peer &peer = pair.second;
				if(peer.socket->good()){
					peer.socket->release_fd();
				}
			}
		}
	}

	void init()
	{
		log_d(MODULE, "network init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));

		// Don't start thread in constructor because in there this module is not
		// guaranteed to be available by server->access_module()
		m_thread.reset(interface::createThread(new NetworkThread(this)));
		m_thread->set_name("network/select");
		m_thread->start();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
	}

	void on_start()
	{
		ss_ address = "any4";
		ss_ port = "20000";

		if(!m_listening_socket->bind_fd(address, port) ||
				!m_listening_socket->listen_fd()){
			log_i(MODULE, "Failed to bind to %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
			// We don't want to be in this state for any amount of time; it will
			// confuse the hell out of everybody otherwise
			m_server->shutdown(1, "Failed to bind socket");
			throw Exception("Failed to bind socket");
			return;
		} else {
			log_i(MODULE, "Listening at %s:%s, fd=%i", cs(address), cs(port),
					m_listening_socket->fd());
		}
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
		}
	}

	void on_listen_event(int event_fd)
	{
		log_v(MODULE, "network: on_listen_event(): fd=%i", event_fd);
		// Create socket
		sp_<interface::TCPSocket> socket(interface::createTCPSocket());
		// Accept connection
		socket->accept_fd(*m_listening_socket.get());
		// Store socket
		Peer::Id peer_id = m_next_peer_id++;
		m_peers[peer_id] = Peer(peer_id, socket);
		m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
		log_i(MODULE, "Client %zu from %s connected",
				peer_id, cs(socket->get_remote_address()));
		// Emit event
		PeerInfo pinfo;
		pinfo.id = peer_id;
		pinfo.address = socket->get_remote_address();
		m_server->emit_event("network:client_connected", new NewClient(pinfo));
	}

	void on_incoming_data(int event_fd)
	{
		log_v(MODULE, "network: on_incoming_data(): fd=%i", event_fd);

		auto it = m_peers_by_socket.find(event_fd);
		if(it == m_peers_by_socket.end()){
			log_w(MODULE, "network: Peer with fd=%i not found", event_fd);
			return;
		}
		Peer &peer = *it->second;

		int fd = peer.socket->fd();
		if(fd != event_fd)
			throw Exception("on_incoming_data: fds don't match");
		char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1){
#ifdef ECONNRESET // No idea why this isn't defined on MinGW
			if(errno == ECONNRESET){
				log_v(MODULE, "Peer %zu: Connection reset by peer", peer.id);
				return;
			}
#endif
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		}
		if(r == 0){
			log_i(MODULE, "Client %zu from %s disconnected",
					peer.id, cs(peer.socket->get_remote_address()));

			PeerInfo pinfo;
			pinfo.id = peer.id;
			pinfo.address = peer.socket->get_remote_address();
			m_server->emit_event("network:client_disconnected",
					new OldClient(pinfo));

			m_peers_by_socket.erase(peer.socket->fd());
			m_peers.erase(peer.id);
			return;
		}
		log_v(MODULE, "Received %zu bytes", r);
		peer.socket_buffer.insert(peer.socket_buffer.end(), buf, buf + r);

		try {
			peer.packet_stream.input(peer.socket_buffer,
			[&](const ss_ &name, const ss_ &data){
				// Emit event
				m_server->emit_event(ss_()+"network:packet_received/"+name,
						new Packet(peer.id, name, data));
			});
		} catch(interface::UnknownPacketReceived &e){
			log_w(MODULE, "%s", e.what());
		}
	}

	void send_u(Peer &peer, const ss_ &name, const ss_ &data)
	{
		peer.packet_stream.output(name, data, [&](const ss_ &packet_data){
			peer.socket->send_fd(packet_data);
		});
	}

	void send_u(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		// Grab Peer (which contains socket)
		auto it = m_peers.find(recipient);
		if(it == m_peers.end()){
			log_w(MODULE, "network::send(): Peer %i doesn't exist",
					recipient);
			return;
		}
		Peer &peer = it->second;

		send_u(peer, name, data);
	}

	// Interface for NetworkThread

	sv_<int> get_sockets()
	{
		sv_<int> result;
		result.push_back(m_listening_socket->fd());
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			result.push_back(peer.socket->fd());
		}
		return result;
	}

	void handle_active_socket(int fd)
	{
		if(fd == m_listening_socket->fd()){
			on_listen_event(fd);
		} else {
			on_incoming_data(fd);
		}
	}

	// Interface

	void send(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		log_d(MODULE, "network::send()");
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

void NetworkThread::run(interface::Thread *thread)
{
	interface::SelectHandler handler;

	while(!thread->stop_requested()){
		sv_<int> sockets;
		// We can avoid implementing our own mutex locking in Module by using
		// interface::Server::access_module() instead of directly accessing it.
		network::access(m_module->m_server, [&](network::Interface *inetwork){
			sockets = m_module->get_sockets();
		});

		sv_<int> active_sockets;
		bool ok = handler.check(500000, sockets, active_sockets);
		(void)ok; // Unused

		if(active_sockets.empty())
			continue;

		network::access(m_module->m_server, [&](network::Interface *inetwork){
			for(int fd: active_sockets){
				m_module->handle_active_socket(fd);
			}
		});
	}
}

void NetworkThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "NetworkThread crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_network(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
