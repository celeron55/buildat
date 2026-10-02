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
		// How many bytes wait in front of a peer's socket, so a producer
		// of bulk can hold back while a slow peer drains ([NET_CHANNELS]):
		// what is queued keeps its place, and what is not yet sent is
		// not yet stale
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
