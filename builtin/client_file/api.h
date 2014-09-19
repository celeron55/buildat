#pragma once
#include "interface/event.h"
#include "network/api.h"

namespace client_file
{
	struct FilesTransmitted: public interface::Event::Private
	{
		network::PeerInfo::Id recipient;

		FilesTransmitted(const network::PeerInfo::Id &recipient): recipient(
					recipient){}
	};

	struct Interface
	{
		virtual void add_file_content(const ss_ &name, const ss_ &content) = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(client_file::Interface*)> cb)
	{
		return server->access_module("client_file", [&](interface::Module * module){
			cb((client_file::Interface*)module->check_interface());
		});
	}
}
