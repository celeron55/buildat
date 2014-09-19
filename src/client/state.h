// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface {
	struct TCPSocket;
}
namespace app {
	struct App;
}

namespace client
{
	typedef size_t PacketType;

	struct State
	{
		virtual ~State(){}
		virtual void update() = 0;
		virtual bool connect(const ss_ &address, const ss_ &port) = 0;
		virtual void send_packet(const ss_ &name, const ss_ &data) = 0;
		virtual ss_ get_file_path(const ss_ &name, ss_ *dst_file_hash = NULL) = 0;
		virtual ss_ get_file_content(const ss_ &name) = 0;
	};

	State* createState(sp_<app::App> app);
}

