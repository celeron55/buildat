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
#include "interface/sha1.h"
#include "interface/compress.h"
#include <cereal/archives/portable_binary.hpp>
#include <deque>
#include <set>
#include <fstream>
#include <sstream>
#include <algorithm>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
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
#include <sys/stat.h>
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
	// The client behind a trusted proxy ([FP_ACCESS] 6): the last entry of
	// its WebSocket upgrade's X-Forwarded-For, or empty
	ss_ forwarded_for;
	// Whom the game is told the peer is
	ss_ address() const {
		return forwarded_for.empty() ? socket->get_remote_address() :
				forwarded_for;
	}
	std::deque<char> socket_buffer;
	interface::PacketStream packet_stream;

	// One port takes the native client, a browser fetching the web client
	// and the web client's WebSocket ([WEB_CLIENT]). A new connection is
	// Sniff until its first bytes say which; only Native and WebSocket are
	// game peers, and the game hears of a peer when it becomes one.
	enum class Kind { Sniff, Http, Native, WebSocket };
	Kind kind = Kind::Native;
	int64_t accepted_us = 0;
	// Sniff and Http: what has come of the request so far
	ss_ http_request;
	// WebSocket: what has come and is not a whole frame yet
	ss_ ws_in;
	// Dropped once what is queued has gone: an HTTP response, the answer to
	// a WebSocket close, or a game's disconnect()
	bool closing = false;
	// disconnect()'s: dropped by then even if the peer does not read
	int64_t close_by_us = 0;

	bool game() const {
		return kind == Kind::Native || kind == Kind::WebSocket;
	}

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
	struct Queued {
		ss_ name;
		ss_ packet;
		bool payload; // a droppable payload, not a definition
	};
	std::deque<Queued> out_queue;
	std::deque<std::pair<ss_, ss_>> out_latest; // name, packet
	// LatestOnly names with packets still in the ordered queue, and how
	// many: the definition and the first payload go ordered (send_u), and
	// a payload in the lane while they are queued would overtake them --
	// the peer reads a type it has not been told. Until the count is
	// zero the name's payloads go ordered too.
	sm_<ss_, size_t> ordered_first;
	size_t out_queued_bytes = 0;
	// When the queue first went over the policy's limit, for Disconnect
	int64_t over_since_us = 0;
	// When the socket last took anything: a peer over the limit that is
	// reading, however slowly, is a slow link and not a dead one
	// ([NET_CHANNELS]; over a lossy link VoxeLibre's join was
	// disconnected at 24 MB unread in 30 s while the peer was reading
	// the whole time)
	int64_t last_progress_us = 0;
	// Said once per peer rather than per packet
	bool warned_full = false;
	// When this end last sent the peer anything, for keepalive(), and
	// whether it has had one: the first goes whatever else is being sent,
	// so that a client busy with a world knows it is to expect them
	int64_t last_send_us = 0;
	bool keepalive_sent = false;

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
			out_buf = std::move(out_queue.front().packet);
			auto f = ordered_first.find(out_queue.front().name);
			if(f != ordered_first.end() && --f->second == 0)
				ordered_first.erase(f);
			out_queue.pop_front();
		} else {
			return;
		}
		out_queued_bytes -= out_buf.size();
	}
	// A LatestOnly name's payload replaces an unsent one in the lane. Its
	// definition (the undroppable packet the stream writes ahead of the
	// first payload) goes ordered, and so does the first payload: at join
	// the queue holds the client's module files, and a placement in the
	// lane overtook them and was read before the client's luanti half had
	// subscribed -- dropped, never resent ([PLAYER_POS_RACE]). While they
	// are queued a newer payload takes the queued one's place -- its spot
	// behind the modules, not the back of the queue: appended behind the
	// newest chunks it never caught up over a slow link (the clock waited
	// 200 s at join over 2 % loss). one_piece: the packet is a single
	// fragment, so a replacement is one entry; a fragmented payload of a
	// LatestOnly name goes ordered whole (simplified: none of the three
	// LatestOnly names fragments in practice).
	void enqueue(const ss_ &name, const ss_ &packet, bool latest_only,
			bool droppable, bool one_piece)
	{
		if(latest_only && droppable && !ordered_first.count(name)){
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
			if(latest_only && droppable && one_piece){
				for(Queued &q : out_queue){
					if(q.name == name && q.payload){
						out_queued_bytes -= q.packet.size();
						out_queued_bytes += packet.size();
						q.packet = packet;
						return;
					}
				}
			}
			out_queue.push_back(Queued{name, packet, droppable});
			if(latest_only)
				ordered_first[name]++;
		}
		out_queued_bytes += packet.size();
	}

	// Bytes that go as they are, ahead of nothing and behind what is queued:
	// an HTTP response, a WebSocket control frame
	void queue_raw(ss_ &&data)
	{
		out_queued_bytes += data.size();
		out_queue.push_back(Queued{ss_(), std::move(data), false});
	}

	Peer(){}
	Peer(Id id, sp_<interface::TCPSocket> socket):
		id(id), socket(socket){}
};

// The server half of RFC 6455 and the little of HTTP that serves the web
// client ([WEB_CLIENT])
namespace web {

// A browser sends its request as soon as it has connected, and a native
// client sends a packet type definition as soon as it has connected, so
// either is known by its first bytes. A connection that is quiet this long
// is taken for a native client that does not speak first (one older than
// [WEB_CLIENT]).
// simplified: a browser's speculative preconnect that stays quiet longer is
// taken for such a client and gets game bytes; its request later fails.
static const int64_t SNIFF_US = 200000;
static const size_t MAX_REQUEST_BYTES = 8 * 1024;
// A request that does not arrive, or a response nobody reads
static const int64_t HTTP_STALL_US = 10000000;
static const size_t MAX_FRAME_BYTES = 16 * 1024 * 1024;

static ss_ base64(const ss_ &data)
{
	static const char *t =
			"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	ss_ r;
	for(size_t i = 0; i < data.size(); i += 3){
		uint32_t v = (uint8_t)data[i] << 16;
		if(i + 1 < data.size()) v |= (uint8_t)data[i + 1] << 8;
		if(i + 2 < data.size()) v |= (uint8_t)data[i + 2];
		r += t[(v >> 18) & 63];
		r += t[(v >> 12) & 63];
		r += i + 1 < data.size() ? t[(v >> 6) & 63] : '=';
		r += i + 2 < data.size() ? t[v & 63] : '=';
	}
	return r;
}

static ss_ lower(ss_ s)
{
	for(char &c : s)
		c = tolower((unsigned char)c);
	return s;
}

static ss_ trim(const ss_ &s)
{
	size_t a = s.find_first_not_of(" \t");
	if(a == ss_::npos)
		return "";
	return s.substr(a, s.find_last_not_of(" \t") - a + 1);
}

// A server's frame: never masked, always whole
static ss_ frame(int opcode, const ss_ &payload)
{
	ss_ r;
	r += (char)(0x80 | opcode);
	const uint64_t n = payload.size();
	if(n < 126){
		r += (char)n;
	} else if(n < 65536){
		r += (char)126;
		r += (char)(n >> 8);
		r += (char)n;
	} else {
		r += (char)127;
		for(int i = 7; i >= 0; i--)
			r += (char)(n >> (i * 8));
	}
	return r + payload;
}

// extra: more header lines, each ending in \r\n
static ss_ response(const ss_ &status, const ss_ &content_type,
		size_t content_length, const ss_ &extra = "")
{
	return "HTTP/1.1 "+status+"\r\n"
			"Content-Type: "+content_type+"\r\n"
			"Content-Length: "+itos((int64_t)content_length)+"\r\n"
			"Cache-Control: no-cache\r\n"+extra+
			"Connection: close\r\n\r\n";
}

}

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
	// The web client's files as last read, by name, kept while the file's
	// modification time and size are the same (its ETag)
	struct WebFile {
		ss_ etag;
		ss_ body;
		ss_ deflated;
	};
	sm_<ss_, WebFile> m_web_files;

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

		// A connection that is not a game peer is not carried over: it has
		// a request or a response half way, and the next module would not
		// know. The browser asks again.
		sv_<Peer::Id> not_game;
		for(auto &pair : m_peers){
			if(!pair.second.game())
				not_game.push_back(pair.first);
		}
		for(Peer::Id id : not_game)
			drop_peer(id);

		int listening_fd = m_listening_socket->fd();
		sv_<std::tuple<Peer::Id, int>> peer_restore_info;
		sv_<Peer::Id> websocket_peers;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			peer_restore_info.push_back(std::tuple<Peer::Id, int>(
					peer.id, peer.socket->fd()));
			if(peer.kind == Peer::Kind::WebSocket)
				websocket_peers.push_back(peer.id);
		}

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(listening_fd);
			ar(peer_restore_info);
			ar(websocket_peers);
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
		sv_<Peer::Id> websocket_peers;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(listening_fd);
			ar(peer_restore_info);
			// Not there when the module that unloaded predates WebSockets
			try {
				ar(websocket_peers);
			} catch(std::exception &e){
			}
		}

		m_listening_socket.reset(interface::createTCPSocket(listening_fd));

		for(auto &tuple : peer_restore_info){
			Peer::Id peer_id = std::get<0>(tuple);
			int fd = std::get<1>(tuple);
			log_i(MODULE, "Restoring peer %i: fd=%i", peer_id, fd);
			sp_<interface::TCPSocket> socket(interface::createTCPSocket(fd));
			m_peers[peer_id] = Peer(peer_id, socket);
			m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
			// simplified: a frame half received when the module unloaded is
			// lost, the same as a native peer's half packet in socket_buffer
			if(std::find(websocket_peers.begin(), websocket_peers.end(),
					peer_id) != websocket_peers.end())
				m_peers[peer_id].kind = Peer::Kind::WebSocket;
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
		// Store socket. The game hears of it once sniff() knows what it is.
		Peer::Id peer_id = m_next_peer_id++;
		m_peers[peer_id] = Peer(peer_id, socket);
		m_peers_by_socket[socket->fd()] = &m_peers[peer_id];
		Peer &peer = m_peers[peer_id];
		peer.kind = Peer::Kind::Sniff;
		peer.accepted_us = interface::os::time_us();
	}

	// A reverse proxy's client ([FP_ACCESS] 6): believed only from the
	// addresses web_trusted_proxies names (comma separated; loopback by
	// default, which is nginx on the same box). The last entry is the one
	// the proxy added; one that is not an address is ignored.
	ss_ forwarded_for(const Peer &peer, const ss_ &header)
	{
		if(header.empty())
			return "";
		const ss_ from = peer.socket->get_remote_address();
		const ss_ trusted = m_server->get_config().get<ss_>(
				"web_trusted_proxies");
		bool ok = false;
		size_t at = 0;
		while(at <= trusted.size()){
			size_t comma = trusted.find(',', at);
			if(comma == ss_::npos)
				comma = trusted.size();
			if(web::trim(trusted.substr(at, comma - at)) == from)
				ok = true;
			at = comma + 1;
		}
		if(!ok)
			return "";
		size_t comma = header.find_last_of(',');
		ss_ last = web::trim(comma == ss_::npos ? header : header.substr(comma + 1));
		if(last.empty() || last.size() > 45)
			return "";
		for(char c : last)
			if(!(isxdigit((unsigned char)c) || c == '.' || c == ':'))
				return "";
		return last;
	}

	void emit_connected(Peer &peer)
	{
		log_i(MODULE, "Client %zu from %s connected%s%s",
				peer.id, cs(peer.address()),
				peer.kind == Peer::Kind::WebSocket ? " (WebSocket)" : "",
				peer.forwarded_for.empty() ? "" :
				(" through "+peer.socket->get_remote_address()).c_str());
		send_unordered(peer);
		PeerInfo pinfo;
		pinfo.id = peer.id;
		pinfo.address = peer.address();
		m_server->emit_event("network:client_connected", new NewClient(pinfo));
	}

	// **What the client may handle out of order** ([NET_CHANNELS]; user,
	// 2026-09-30): the LatestOnly names, whose order against the rest does
	// not matter. A client that cannot keep up with a world arriving has the
	// backlog in its own buffer, not in this queue, and an answer to a menu
	// waited behind it for a minute; a client told these handles them first.
	void send_unordered(Peer &peer)
	{
		sv_<ss_> names(m_latest_only.begin(), m_latest_only.end());
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(names);
		}
		send_u(peer, "core:unordered", os.str());
	}

	void become_native(Peer &peer)
	{
		peer.kind = Peer::Kind::Native;
		peer.socket_buffer.insert(peer.socket_buffer.end(),
				peer.http_request.begin(), peer.http_request.end());
		peer.http_request.clear();
		emit_connected(peer);
		input_packets(peer);
	}

	// Whether the peer is to be kept. The native protocol's first bytes are
	// a packet's type, and the first packet is core:define_packet_type,
	// type 0: they never read as "GET " (which as a type is 0x4547).
	bool sniff(Peer &peer)
	{
		static const ss_ get = "GET ";
		const size_t n = std::min(peer.http_request.size(), get.size());
		if(peer.http_request.compare(0, n, get, 0, n) != 0){
			become_native(peer);
			return true;
		}
		if(n < get.size())
			return true;
		peer.kind = Peer::Kind::Http;
		return handle_http(peer);
	}

	// Whether the peer is to be kept
	bool handle_http(Peer &peer)
	{
		const ss_ &req = peer.http_request;
		const size_t end = req.find("\r\n\r\n");
		if(end == ss_::npos)
			return req.size() <= web::MAX_REQUEST_BYTES;
		if(end + 4 > web::MAX_REQUEST_BYTES)
			return false;
		// "GET <target> HTTP/1.1", then "Name: value" lines
		size_t eol = req.find("\r\n");
		const ss_ line = req.substr(0, eol);
		const size_t sp = line.find(' ', 4);
		if(sp == ss_::npos || line.compare(sp, 6, " HTTP/") != 0)
			return false;
		ss_ target = line.substr(4, sp - 4);
		target = target.substr(0, target.find('?'));
		sm_<ss_, ss_> headers;
		for(size_t at = eol + 2; at < end; at = eol + 2){
			eol = req.find("\r\n", at);
			const ss_ h = req.substr(at, eol - at);
			const size_t colon = h.find(':');
			if(colon == ss_::npos)
				return false;
			headers[web::lower(web::trim(h.substr(0, colon)))] =
					web::trim(h.substr(colon + 1));
		}
		const ss_ rest = req.substr(end + 4);
		peer.http_request.clear();

		if(web::lower(headers["upgrade"]).find("websocket") != ss_::npos){
			const ss_ &key = headers["sec-websocket-key"];
			if(key.empty())
				return false;
			ss_ r = "HTTP/1.1 101 Switching Protocols\r\n"
					"Upgrade: websocket\r\n"
					"Connection: Upgrade\r\n"
					"Sec-WebSocket-Accept: "+web::base64(interface::sha1::calculate(
					key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))+"\r\n";
			// Emscripten's socket emulation asks for it.
			// simplified: a substring match on the offered list
			if(web::lower(headers["sec-websocket-protocol"]).find("binary") !=
					ss_::npos)
				r += "Sec-WebSocket-Protocol: binary\r\n";
			r += "\r\n";
			// Ahead of anything the game sends, which only starts on the
			// event below
			peer.queue_raw(std::move(r));
			peer.kind = Peer::Kind::WebSocket;
			peer.ws_in = rest;
			peer.forwarded_for = forwarded_for(peer, headers["x-forwarded-for"]);
			emit_connected(peer);
			return deframe(peer);
		}

		// A closed list of names, and nothing else is looked at
		static const sm_<ss_, std::pair<ss_, ss_>> files = {
			{"/", {"index.html", "text/html; charset=utf-8"}},
			{"/index.html", {"index.html", "text/html; charset=utf-8"}},
			{"/buildat.js", {"buildat.js", "application/javascript"}},
			{"/buildat.wasm", {"buildat.wasm", "application/wasm"}},
			{"/buildat.data", {"buildat.data", "application/octet-stream"}},
		};
		peer.closing = true;
		auto it = files.find(target);
		if(it == files.end()){
			ss_ body = "Not found\n";
			peer.queue_raw(web::response("404 Not Found",
					"text/plain; charset=utf-8", body.size()) + body);
			return true;
		}
		const ss_ path = web_client_path()+"/"+it->second.first;
		// **A reload does not download the client again** (user,
		// 2026-10-01: a phone reloads the page each time it comes back): the
		// browser asks with the ETag it has, and the same file is a 304
		struct stat st;
		const ss_ etag = stat(path.c_str(), &st) == 0 ? "\""+
				itos((int64_t)st.st_mtime)+"-"+itos((int64_t)st.st_size)+"\"" : "";
		WebFile &wf = m_web_files[it->second.first];
		if(etag.empty() || wf.etag != etag){
			wf = WebFile();
			std::ifstream f(path, std::ios::binary);
			if(f.good()){
				std::ostringstream os(std::ios::binary);
				os<<f.rdbuf();
				wf.body = os.str();
			}
			if(!f.good() || wf.body.empty()){
				log_w(MODULE, "Web client file not found: %s", cs(path));
				ss_ body = "The web client is not here: "+it->second.first+
						" is not in the server's web_client_path.\n";
				peer.queue_raw(web::response("404 Not Found",
						"text/plain; charset=utf-8", body.size()) + body);
				return true;
			}
			// Compressed once per build; about a second for the wasm, in
			// this thread
			// simplified: zlib's stream, which is what HTTP's "deflate"
			// is and every browser takes; gzip only adds a header and a CRC
			std::ostringstream os(std::ios::binary);
			interface::compress_zlib(wf.body, os, 6);
			wf.deflated = os.str();
			wf.etag = etag;
		}
		const ss_ cache = etag.empty() ? "" : "ETag: "+etag+"\r\n";
		if(!etag.empty() && headers["if-none-match"].find(etag) != ss_::npos){
			log_v(MODULE, "Peer %zu: %s not modified", peer.id, cs(path));
			peer.queue_raw("HTTP/1.1 304 Not Modified\r\n"+cache+
					"Cache-Control: no-cache\r\nConnection: close\r\n\r\n");
			return true;
		}
		// simplified: a substring match; "deflate;q=0" would still get it
		const bool deflate =
				web::lower(headers["accept-encoding"]).find("deflate") != ss_::npos;
		const ss_ &body = deflate ? wf.deflated : wf.body;
		log_v(MODULE, "Peer %zu: serving %s (%zu bytes%s)", peer.id,
				cs(path), body.size(), deflate ? ", deflated" : "");
		// It goes out through the peer's queue like anything else, as far as
		// the socket takes it at a time.
		// simplified: the whole file is kept in memory, and copied per
		// download; tens of megabytes. Reading it as the queue drains is the
		// upgrade.
		peer.queue_raw(web::response("200 OK", it->second.second,
				body.size(), cache+(deflate ? "Content-Encoding: deflate\r\n" :
				"")+"Vary: Accept-Encoding\r\n"));
		peer.queue_raw(ss_(body));
		return true;
	}

	ss_ web_client_path()
	{
		const ss_ &path = m_server->get_config().get<ss_>("web_client_path");
		if(!path.empty())
			return path;
		return m_server->get_config().get<ss_>("share_path")+"/web";
	}

	// Takes what is whole of peer.ws_in; the payload is stream bytes, the
	// same as a native peer's. Whether the peer is to be kept.
	bool deframe(Peer &peer)
	{
		const ss_ &b = peer.ws_in;
		size_t at = 0;
		for(;;){
			if(peer.closing)
				break;
			if(b.size() - at < 2)
				break;
			const uint8_t b0 = b[at], b1 = b[at + 1];
			const bool fin = b0 & 0x80;
			const int opcode = b0 & 0x0f;
			// A client's frames are masked, always
			if(!(b1 & 0x80) || (b0 & 0x70))
				return false;
			uint64_t len = b1 & 0x7f;
			size_t h = 2;
			if(len == 126){
				if(b.size() - at < 4)
					break;
				len = (uint8_t)b[at + 2] << 8 | (uint8_t)b[at + 3];
				h = 4;
			} else if(len == 127){
				if(b.size() - at < 10)
					break;
				len = 0;
				for(size_t i = 0; i < 8; i++)
					len = len << 8 | (uint8_t)b[at + 2 + i];
				h = 10;
			}
			if(len > web::MAX_FRAME_BYTES){
				log_w(MODULE, "Peer %zu: WebSocket frame of %zu bytes is over "
						"the limit", peer.id, (size_t)len);
				return false;
			}
			if(opcode >= 8 && (!fin || len > 125))
				return false;
			if(b.size() - at < h + 4 + len)
				break;
			const char *mask = &b[at + h];
			ss_ payload(&b[at + h + 4], len);
			for(size_t i = 0; i < len; i++)
				payload[i] ^= mask[i & 3];
			at += h + 4 + len;
			switch(opcode){
			case 0: // continuation
			case 1: // text
			case 2: // binary
				// simplified: the order of a message's frames is not checked;
				// every data frame is more of the stream
				peer.socket_buffer.insert(peer.socket_buffer.end(),
						payload.begin(), payload.end());
				break;
			case 8: // close: answered with its status, and the peer goes
				log_i(MODULE, "Client %zu from %s closed its WebSocket",
						peer.id, cs(peer.socket->get_remote_address()));
				peer.queue_raw(web::frame(8, payload.substr(0, 2)));
				peer.closing = true;
				break;
			case 9: // ping
				peer.queue_raw(web::frame(10, payload));
				break;
			case 10: // pong
				break;
			default:
				return false;
			}
		}
		peer.ws_in.erase(0, at);
		if(peer.closing)
			peer.ws_in.clear();
		input_packets(peer);
		return true;
	}

	void input_packets(Peer &peer)
	{
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
			if(peer.game())
				log_i(MODULE, "Client %zu from %s disconnected",
						peer.id, cs(peer.socket->get_remote_address()));
			drop_peer(peer.id);
			return;
		}
		log_v(MODULE, "Received %zu bytes", r);
		bool keep = true;
		switch(peer.kind){
		case Peer::Kind::Sniff:
			peer.http_request.append(buf, r);
			keep = sniff(peer);
			break;
		case Peer::Kind::Http:
			// What comes after the request is not read
			if(!peer.closing){
				peer.http_request.append(buf, r);
				keep = handle_http(peer);
			}
			break;
		case Peer::Kind::WebSocket:
			if(!peer.closing){
				peer.ws_in.append(buf, r);
				keep = deframe(peer);
			}
			break;
		case Peer::Kind::Native:
			peer.socket_buffer.insert(peer.socket_buffer.end(), buf, buf + r);
			input_packets(peer);
			break;
		}
		if(keep)
			flush_peer(peer);
		if(!keep || (peer.closing && peer.out_pending() == 0)){
			if(!keep)
				log_i(MODULE, "Peer %zu from %s: bad request; dropping it",
						peer.id, cs(peer.socket->get_remote_address()));
			drop_peer(peer.id);
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
				peer.ordered_first.clear();
				peer.out_queued_bytes = 0;
				return;
			}
			if(sent == 0)
				break;
			peer.out_sent += sent;
			peer.last_progress_us = interface::os::time_us();
		}
		if(peer.out_pending() <= m_max_queue_bytes){
			peer.over_since_us = 0;
			peer.warned_full = false;
		}
	}

	// **network:keepalive** (user, 2026-09-30): an empty packet to a game
	// peer that has been sent nothing for KEEPALIVE_US, so that a client
	// hears from a live server every few seconds and can tell a link that
	// died without closing (src/client/state.cpp, SILENCE_US). On this
	// thread, which goes round whatever the game's modules are doing.
	static const int64_t KEEPALIVE_US = 5000000;
	void keepalive()
	{
		const int64_t now = interface::os::time_us();
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			if(peer.game() && !peer.closing && (!peer.keepalive_sent ||
					now - peer.last_send_us >= KEEPALIVE_US)){
				peer.keepalive_sent = true;
				send_u(peer, "network:keepalive", "");
			}
		}
	}

	bool any_peer_pending()
	{
		for(auto &pair : m_peers){
			const Peer &peer = pair.second;
			// The web's peers also have clocks that flush_peers() keeps
			if(peer.out_pending() > 0 || peer.closing ||
					peer.kind == Peer::Kind::Sniff || peer.kind == Peer::Kind::Http)
				return true;
		}
		return false;
	}

	void flush_peers()
	{
		sv_<Peer::Id> to_drop;
		for(auto &pair : m_peers){
			Peer &peer = pair.second;
			const int64_t now = interface::os::time_us();
			if(peer.kind == Peer::Kind::Sniff &&
					now - peer.accepted_us >= web::SNIFF_US)
				become_native(peer);
			flush_peer(peer);
			if(peer.closing && (peer.out_pending() == 0 ||
					(peer.close_by_us != 0 && now >= peer.close_by_us))){
				to_drop.push_back(peer.id);
				continue;
			}
			if(peer.kind == Peer::Kind::Http && now - std::max(peer.accepted_us,
					peer.last_progress_us) >= web::HTTP_STALL_US){
				log_i(MODULE, "Peer %zu from %s: HTTP stalled; dropping it",
						peer.id, cs(peer.socket->get_remote_address()));
				to_drop.push_back(peer.id);
				continue;
			}
			if(!peer.game())
				continue;
			if(m_send_policy != SendPolicy::Disconnect)
				continue;
			if(peer.out_pending() <= m_max_queue_bytes)
				continue;
			if(peer.over_since_us == 0){
				peer.over_since_us = now;
				if(peer.last_progress_us == 0)
					peer.last_progress_us = now;
			} else if(now - peer.over_since_us >= m_grace_us &&
					now - peer.last_progress_us >= m_grace_us){
				// Over the limit for the grace and nothing read in it:
				// the grace measures the peer's reading, not the queue
				log_w(MODULE, "Peer %zu has read nothing of %zu queued "
						"bytes in %.0f s; disconnecting it", peer.id,
						peer.out_pending(), (now - peer.last_progress_us) / 1e6);
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
		if(peer.game()){
			PeerInfo pinfo;
			pinfo.id = peer.id;
			pinfo.address = peer.address();
			m_server->emit_event("network:client_disconnected",
					new OldClient(pinfo));
		}
		m_peers_by_socket.erase(peer.socket->fd());
		peer.socket->close_fd();
		m_peers.erase(it);
	}

	void send_u(Peer &peer, const ss_ &name, const ss_ &data)
	{
		// A WebSocket peer that has said close is not sent any more
		if(peer.closing)
			return;
		peer.last_send_us = interface::os::time_us();
		const bool latest_only = m_latest_only.count(name) > 0;
		// A drop policy drops the whole of a fragmented packet or none of
		// it: the fragments of one call are one packet to the reader
		bool dropping = false;
		peer.packet_stream.output(name, data,
				[&](const ss_ &packet_data, bool droppable){
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
			// A WebSocket peer gets each packet as a frame of its own. It is
			// framed here, before the queue, so that the queue and its
			// flow control only ever see whole frames: a LatestOnly
			// replacement swaps one whole frame for another.
			peer.enqueue(name, peer.kind == Peer::Kind::WebSocket ?
					web::frame(2, packet_data) : packet_data,
					latest_only, droppable,
					data.size() <= interface::PacketStream::FRAGMENT_BYTES);
		});
		// The common case is a peer that is keeping up, and then this writes
		// the packet and leaves nothing behind
		flush_peer(peer);
	}

	void send_u(PeerInfo::Id recipient, const ss_ &name, const ss_ &data)
	{
		// Grab Peer (which contains socket)
		auto it = m_peers.find(recipient);
		if(it == m_peers.end() || !it->second.game()){
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
		// simplified: a client is told the names at its connect, so a
		// module declares at its start, before any connects
	}

	void disconnect(PeerInfo::Id id)
	{
		auto it = m_peers.find(id);
		if(it == m_peers.end())
			return;
		it->second.closing = true;
		it->second.close_by_us = interface::os::time_us() + 2000000;
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
			if(peer.game())
				result.push_back(peer.id);
		}
		return result;
	}

	size_t pending_bytes(PeerInfo::Id peer)
	{
		auto it = m_peers.find(peer);
		return it == m_peers.end() ? 0 : it->second.out_pending();
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
			m_module->keepalive();
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
