// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/thread.h"
#include "interface/os.h"
#include "interface/select_handler.h"
#include <cereal/archives/portable_binary.hpp>
#include <deque>
#include <set>
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

	// What has been handed to this peer and has not gone down the socket
	// yet, because the socket does not block any more: a peer that is not
	// reading used to stop the whole server inside send(2). `out_sent` is
	// how much of the front of it has already gone.
	ss_ out_buf;
	size_t out_sent = 0;
	// Behind it, the queue: packets (a fragment each at most) in the order
	// they were sent, and ahead of them the LatestOnly ones by name, one
	// per name, the newest ([NET_CHANNELS]). out_buf is what is being
	// written now; a packet moves into it when it drains.
	std::deque<ss_> out_queue;
	std::deque<std::pair<ss_, ss_>> out_latest; // name, packet
	size_t out_queued_bytes = 0;
	// When the queue first went over the policy's limit, for Disconnect
	int64_t over_since_us = 0;
	// Said once per peer rather than per packet
	bool warned_full = false;

	size_t out_pending() const {
		return out_buf.size() - out_sent + out_queued_bytes;
	}
	// The next packet into out_buf, if it is empty and there is one
	void refill()
	{
		if(out_sent < out_buf.size())
			return;
		out_buf.clear();
		out_sent = 0;
		if(!out_latest.empty()){
			out_buf = std::move(out_latest.front().second);
			out_latest.pop_front();
		} else if(!out_queue.empty()){
			out_buf = std::move(out_queue.front());
			out_queue.pop_front();
		} else {
			return;
		}
		out_queued_bytes -= out_buf.size();
	}
	void enqueue(const ss_ &name, const ss_ &packet, bool latest_only)
	{
		if(latest_only){
			for(auto &pair : out_latest){
				if(pair.first == name){
					out_queued_bytes -= pair.second.size();
					out_queued_bytes += packet.size();
					pair.second = packet;
					return;
				}
			}
			out_latest.push_back(std::make_pair(name, packet));
		} else {
			out_queue.push_back(packet);
		}
		out_queued_bytes += packet.size();
	}

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
	// The game's answer to a peer that will not read; see SendPolicy in
	// api.h. Buffer is what a game that never says anything gets, because
	// it is the one that neither loses data nor makes anybody wait.
	SendPolicy m_send_policy = SendPolicy::Buffer;
	size_t m_max_queue_bytes = 4 * 1024 * 1024;
	int64_t m_grace_us = 10000000;
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
		ss_ address = m_server->get_config().get<ss_>("network_address");
		ss_ port = m_server->get_config().get<ss_>("network_port");

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
			log_i(MODULE, "STATUS Listening");
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
		// A peer's socket must not block: a send that waits for a client to
		// read holds this module, and everything that wants to send
		// anything waits behind it. What does not fit waits in the peer's
		// own queue instead; see flush_peer().
		if(!socket->set_nonblocking(true)){
			log_w(MODULE, "Could not make peer socket non-blocking; a client "
					"that stops reading will stall the server");
		}
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

	// What has not gone yet, as far as the socket will take it now. Not an
	// error for nothing to go: the peer is not reading and the rest waits.
	void flush_peer(Peer &peer)
	{
		for(;;){
			peer.refill();
			if(peer.out_sent >= peer.out_buf.size())
				break;
			size_t sent = 0;
			if(!peer.socket->send_some(peer.out_buf, peer.out_sent, &sent)){
				// The socket is gone; the read side notices and cleans up
				peer.out_buf.clear();
				peer.out_sent = 0;
				peer.out_queue.clear();
				peer.out_latest.clear();
				peer.out_queued_bytes = 0;
				return;
			}
			if(sent == 0)
				break;
			peer.out_sent += sent;
		}
		if(peer.out_pending() <= m_max_queue_bytes){
			peer.over_since_us = 0;
			peer.warned_full = false;
		}
	}

	bool any_peer_pending()
	{
		for(auto &pair : m_peers){
			if(pair.second.out_pending() > 0)
				return true;
		}
		return false;
	}

	void flush_peers()
	{
		sv_<Peer::Id> to_drop;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			flush_peer(peer);
			if(m_send_policy != SendPolicy::Disconnect)
				continue;
			if(peer.out_pending() <= m_max_queue_bytes)
				continue;
			const int64_t now = interface::os::time_us();
			if(peer.over_since_us == 0){
				peer.over_since_us = now;
			} else if(now - peer.over_since_us >= m_grace_us){
				log_w(MODULE, "Peer %zu has not read %zu queued bytes in "
						"%.0f s; disconnecting it", peer.id,
						peer.out_pending(), (now - peer.over_since_us) / 1e6);
				to_drop.push_back(peer.id);
			}
		}
		for(Peer::Id id : to_drop)
			drop_peer(id);
	}

	void drop_peer(Peer::Id id)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end())
			return;
		Peer &peer = it->second;
		PeerInfo pinfo;
		pinfo.id = peer.id;
		pinfo.address = peer.socket->get_remote_address();
		m_server->emit_event("network:client_disconnected",
				new OldClient(pinfo));
		m_peers_by_socket.erase(peer.socket->fd());
		peer.socket->close_fd();
		m_peers.erase(it);
	}

	void send_u(Peer &peer, const ss_ &name, const ss_ &data)
	{
		const bool latest_only = m_latest_only.count(name) > 0;
		// A drop policy drops the whole of a fragmented packet or none of
		// it: the fragments of one call are one packet to the reader
		bool dropping = false;
		// A LatestOnly payload may not overtake its own definition, which
		// the stream writes ahead of the first payload of a name: that
		// first one goes ordered, behind it
		bool defined_now = false;
		peer.packet_stream.output(name, data,
				[&](const ss_ &packet_data, bool droppable){
			if(!droppable)
				defined_now = true;
			if(dropping && droppable)
				return;
			// Over the limit, a Drop game throws the new packet away rather
			// than queueing it. Buffer and Disconnect both queue; what
			// Disconnect does about it is in flush_peers(), on the thread
			// that drains, because a peer is not to be closed from inside
			// somebody else's send.
			//
			// A packet the stream marks undroppable is queued whatever the
			// policy says: that is core:define_packet_type, and a peer that
			// misses one can never read that type again. A dropped payload
			// costs one packet; a dropped definition costs the session.
			if(droppable && m_send_policy == SendPolicy::Drop &&
					peer.out_pending() > m_max_queue_bytes){
				if(!peer.warned_full){
					peer.warned_full = true;
					log_w(MODULE, "Peer %zu is %zu bytes behind; dropping "
							"what does not fit", peer.id, peer.out_pending());
				}
				dropping = true;
				return;
			}
			// A definition is ordered whatever the payload is: it has to be
			// read before the payload, and the queue keeps that
			peer.enqueue(name, packet_data,
					latest_only && droppable && !defined_now);
		});
		// The common case is a peer that is keeping up, and then this writes
		// the packet and leaves nothing behind
		flush_peer(peer);
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

	std::set<ss_> m_latest_only;

	void declare(const ss_ &packet_name, Channel channel)
	{
		if(channel == Channel::LatestOnly)
			m_latest_only.insert(packet_name);
		else
			m_latest_only.erase(packet_name);
	}

	void set_send_policy(SendPolicy policy, size_t max_queue_bytes,
			int64_t grace_us)
	{
		m_send_policy = policy;
		if(max_queue_bytes > 0)
			m_max_queue_bytes = max_queue_bytes;
		if(grace_us > 0)
			m_grace_us = grace_us;
		log_i(MODULE, "Send policy: %s, %zu bytes a peer, %.0f s of grace",
				policy == SendPolicy::Buffer ? "buffer whatever it takes" :
				policy == SendPolicy::Drop ? "drop what does not fit" :
				"disconnect a peer that stays behind",
				m_max_queue_bytes, m_grace_us / 1e6);
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

		// A peer that is behind has bytes waiting for room in its socket,
		// and nothing wakes this loop when that room appears -- the select
		// is on readability only. So while anything is waiting it comes
		// round often and pushes what fits.
		//
		// simplified: a poll rather than a select on writability, which is
		// what SelectHandler would have to grow. It costs a wakeup every
		// five milliseconds and only while a peer is actually behind.
		bool pending = false;
		network::access(m_module->m_server, [&](network::Interface *inetwork){
			pending = m_module->any_peer_pending();
		});

		sv_<int> active_sockets;
		bool ok = handler.check(pending ? 5000 : 500000, sockets,
				active_sockets);
		(void)ok; // Unused

		if(pending){
			network::access(m_module->m_server,
					[&](network::Interface *inetwork){
				m_module->flush_peers();
			});
		}

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
