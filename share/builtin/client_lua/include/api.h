#pragma once
#include "interface/event.h"
#include "network/include/api.h"

namespace client_lua
{
	struct FilesSent: public interface::Event::Private
	{
		network::PeerInfo::Id recipient;

		FilesSent(const network::PeerInfo::Id &recipient): recipient(recipient){}
	};
}


