#pragma once
#include "interface/event.h"
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

	struct Interface
	{
		virtual void send(PeerInfo::Id recipient, const ss_ &name,
				const ss_ &data) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(network::Interface*)> cb)
	{
		return server->access_module("network", [&](interface::Module * module){
			cb((network::Interface*)module->check_interface());
		});
	}
}

