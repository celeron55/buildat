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
		// The same connect on a worker thread, so that the frame keeps
		// drawing while it runs ([BOX_PLAYTEST_2] 12: the box's watchdog
		// caught the main thread inside connect's select, and the waiting
		// screen froze on whatever it had last drawn). One is in flight at
		// a time -- a client connects once.
		virtual void connect_start(const ss_ &address) = 0;
		// 0 while it runs, 1 when it is connected, -1 when it failed, with
		// the reason in error. The connect's thread is joined here.
		virtual int connect_poll(ss_ *error = nullptr) = 0;
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
