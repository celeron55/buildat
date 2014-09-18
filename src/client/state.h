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
		virtual bool connect(const ss_ &address, const ss_ &port) = 0;
		virtual bool send(const ss_ &data) = 0;
		virtual void update() = 0;
	};

	State* createState(sp_<app::App> app);
}

