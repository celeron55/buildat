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

		PeerInfo::Id recipient;
		Type type; // TODO: Allow supplying a name directly here alternatively
		ss_ data;

		Packet(PeerInfo::Id recipient, const Type &type, const ss_ &data):
			recipient(recipient), type(type), data(data){}
	};

	struct NewClient: public interface::Event::Private
	{
		PeerInfo info;

		NewClient(const PeerInfo &info): info(info){}
	};

	struct Req_get_packet_type: public interface::Event::Private
	{
		ss_ name;

		Req_get_packet_type(const ss_ &name): name(name){}
	};

	struct Resp_get_packet_type: public interface::Event::Private
	{
		Packet::Type type;

		Resp_get_packet_type(const Packet::Type &type): type(type){}
	};

	struct Direct
	{
		virtual ~Direct(){}
		virtual Packet::Type packet_type(const ss_ &name) = 0;
		virtual void send(PeerInfo::Id recipient, const Packet::Type &type,
		                  const ss_ &data) = 0;
	};
}

