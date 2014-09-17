#include "interface/event.h"

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

		Type type;
		ss_ data;

		Packet(const Type &type, const ss_ &data): type(type), data(data){}
	};

	struct ClientConnected: public interface::Event::Private
	{
		PeerInfo info;

		ClientConnected(const PeerInfo &info): info(info){}
	};
}

