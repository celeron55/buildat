// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>
#include <cstdint>

namespace network
{
	typedef size_t PeerId;

	struct PeerInfo
	{
		typedef PeerId Id;

		Id id = 0;
		ss_ address;
		// Came in through a WebSocket: a browser's page, which any site
		// the user visits can open to 127.0.0.1 ([SECURITY_RUN_1])
		bool web = false;
	};

	struct Packet: public interface::Event::Private
	{
		typedef size_t Type;
		PeerInfo::Id sender = 0;
		ss_ name;
		ss_ data;
		Packet(PeerInfo::Id sender, const ss_ &name, const ss_ &data):
			sender(sender), name(name), data(data){}
	};

	struct NewClient: public interface::Event::Private
	{
		PeerInfo info;

		NewClient(const PeerInfo &info): info(info){}
	};

	struct OldClient: public interface::Event::Private
	{
		PeerInfo info;

		OldClient(const PeerInfo &info): info(info){}
	};

	// **An HTTP request for an app** ([STARPORT]): what a GET or a POST to a
	// path under /api/ on the server's port carries, as the event
	// "network:http_request". The module whose path it is answers with
	// Interface::http_respond(); one not answered within ten seconds is
	// dropped. The address is the client's as the game would be told it
	// (a trusted proxy's X-Forwarded-For).
	struct HttpRequest: public interface::Event::Private
	{
		PeerInfo::Id peer = 0;
		ss_ method;       // "GET" or "POST"
		ss_ path;         // "/api/..." or a claimed path, without the query
		ss_ query;        // what follows "?", as it came
		ss_ body;         // a POST's, at most 64 KiB
		ss_ address;
		// The Origin header, as it came: a browser's page says where it is
		// from on every cross-origin request; "" from anything else
		ss_ origin;
		ss_ host;  // the Host header: what the request was sent to
		HttpRequest(PeerInfo::Id peer, const ss_ &method, const ss_ &path,
				const ss_ &query, const ss_ &body, const ss_ &address,
				const ss_ &origin = "", const ss_ &host = ""):
			peer(peer), method(method), path(path), query(query), body(body),
			address(address), origin(origin), host(host){}
	};

	// What a server does about a peer that will not read what it is sent.
	// A peer's socket does not block any more, so what cannot go right away
	// waits in a queue of its own -- and this says what happens when that
	// queue keeps growing.
	//
	// The choice is the game's: a game knows whether a client that has
	// fallen behind is better off waiting, losing data, or being let go.
	// See set_send_policy(), and doc/plan/luanti_module_plan.md, "Settled".
	enum class SendPolicy
	{
		// Queue whatever it takes. Nothing is ever lost and nothing ever
		// waits, and a peer that never reads costs memory without bound.
		// The default, because it is what a game that has not thought about
		// this wants: it works.
		Buffer,
		// Over the limit, a new packet is dropped and said so once. For a
		// game whose packets are a stream of the latest of something --
		// positions -- and where an old one is worth nothing anyway.
		Drop,
		// Over the limit for longer than the grace period, the peer is
		// disconnected. Luanti's own answer, and what
		// apps/vanilla picks.
		Disconnect,
	};

	struct Interface
	{
		virtual void send(PeerInfo::Id recipient, const ss_ &name,
				const ss_ &data) = 0;
		virtual sv_<PeerInfo::Id> list_peers() = 0;
		// How many bytes wait in front of a peer's socket, and behind it in
		// a client that has read them and not handled them yet
		// (network:backlog), so a producer of bulk can hold back while a
		// slow peer drains ([NET_CHANNELS], [CHUNK_RELOAD]): what is
		// queued keeps its place, and what is not yet sent is not yet
		// stale
		virtual size_t pending_bytes(PeerInfo::Id peer) = 0;
		// max_queue_bytes is what Drop and Disconnect measure against, and
		// grace_us how long Disconnect lets a peer stay over it. Buffer
		// ignores both.
		virtual void set_send_policy(SendPolicy policy,
				size_t max_queue_bytes, int64_t grace_us) = 0;
		// What a packet's name means for the queue in front of the socket
		// ([NET_CHANNELS]): the module that defines the packet declares it,
		// once, and the declaration holds for every peer. LatestOnly: the
		// packet goes ahead of everything queued and replaces an unsent
		// one of the same name -- a position, a clock, a HUD value, whose
		// order against other packets does not matter and whose stale copy
		// is worth nothing. Everything undeclared keeps its order behind
		// what was queued before it, sliced into fragments, so a
		// LatestOnly packet waits one fragment and not the bulk.
		// A client is told the LatestOnly names at its connect
		// (core:unordered) and handles them ahead of a backlog of its own,
		// so a module declares at its start.
		enum class Channel { Ordered, LatestOnly };
		virtual void declare(const ss_ &packet_name, Channel channel) = 0;
		// The peer is disconnected once what is queued for it has gone, or
		// in two seconds if it does not read: a packet sent just before,
		// such as why, still arrives. Nothing more is sent to it.
		virtual void disconnect(PeerInfo::Id peer) = 0;
		// The answer to a network:http_request; the connection closes
		// after it. A peer that has gone, or was answered, is ignored.
		// extra_headers: more header lines, each ending in \r\n (CORS, a
		// page's framing policy)
		virtual void http_respond(PeerInfo::Id peer, int status,
				const ss_ &content_type, const ss_ &body,
				const ss_ &extra_headers = "") = 0;
		// Listen on another address too, the same port: the launcher's
		// game, on 127.0.0.1, opened to the LAN at the machine's LAN
		// address. false with why if it cannot.
		virtual bool listen_on(const ss_ &address, ss_ *error) = 0;
		// Paths besides /api/ that come as network:http_request: every
		// target starting with `prefix` -- but "/" is the root page only,
		// and the web client's own files are never an app's. An app that
		// serves pages to read ([HEARTH_MVP]) claims its own at its start.
		virtual void claim_http_path(const ss_ &prefix) = 0;
		// [PLAY_PAGE] (c): a WebSocket to a path starting with `prefix` is
		// the app's, not a game client: "network:ws_open" (an HttpRequest:
		// its path, query, address, Origin and Host), then each message as
		// "network:ws_message" (a Packet, name ""), and "network:ws_closed"
		// (an OldClient). ws_send() sends one binary message; disconnect()
		// closes it. Origin is checked as for a game's WebSocket.
		virtual void claim_ws_path(const ss_ &prefix) = 0;
		// [PLAY_OOTB] the page served at / starts on the launch menu
		// instead of joining this server: for a server with no game of
		// its own (apps/play)
		virtual void set_page_has_no_game() = 0;
		virtual void ws_send(PeerInfo::Id peer, const ss_ &data) = 0;
		// [FAVICON] the PNG served for /favicon.ico, ahead of the default
		// Buildat logo; "" restores the default. An app sets its own icon
		// (vanilla, the game's) at any time.
		virtual void set_favicon(const ss_ &png) = 0;
		// [PAGE_TITLE] the web client page's <title>, "<name> | Buildat":
		// the admin's name (starport.json's, set by starport_announce)
		// ahead of the app's (vanilla, its game's title); "" unsets one,
		// and with neither it is "Buildat"
		virtual void set_page_title(const ss_ &name, bool admin) = 0;
		// [LAN_DISCOVERY]: say every 2 s on the LAN's group (tcpsocket.h)
		// that this server is here, under `name`; "" stops. `account`:
		// whether joining needs one.
		virtual void lan_announce(const ss_ &name, bool account) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(network::Interface*)> cb)
	{
		return server->access_module("network", [&](interface::Module *module){
			cb((network::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
