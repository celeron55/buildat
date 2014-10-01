// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

namespace network
{
	struct PeerInfo
	{
		typedef size_t Id;

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

	struct Interface
	{
		virtual void send(PeerInfo::Id recipient, const ss_ &name,
				const ss_ &data) = 0;
		virtual sv_<PeerInfo::Id> list_peers() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(network::Interface*)> cb)
	{
		return server->access_module("network", [&](interface::Module * module){
			cb((network::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
