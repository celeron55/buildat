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
		virtual bool connect(const ss_ &address, ss_ *error = nullptr) = 0;
		virtual void send_packet(const ss_ &name, const ss_ &data) = 0;
		// Returns "" if not found
		virtual ss_ get_file_path(const ss_ &name, ss_ *dst_file_hash = NULL) = 0;
		// Throws exception if not found
		virtual ss_ get_file_content(const ss_ &name) = 0;
		// The connection dropped and the state made ready for another: a
		// menu-only connection left for the launcher ([MENU_CONTEXT]); what
		// the sandbox kept is client/sandbox.lua's __buildat_reset_sandbox
		virtual void reset() = 0;
	};

	State* createState(sp_<app::App> app);
}

// vim: set noet ts=4 sw=4:
