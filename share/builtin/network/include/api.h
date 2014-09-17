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

	inline void send(interface::Server *server,
	                 const Packet::Type &type, const ss_ &data)
	{
		interface::Event event("network:send");
		event.p.reset(new network::Packet(type, data));
		server->emit_event(std::move(event));
	}
}

