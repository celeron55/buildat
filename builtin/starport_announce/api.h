// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/server.h"
#include "interface/module.h"
#include <functional>

// **Starport ID logins** ([STARPORT] 10c): a Starport signs a token for this
// server's listing with the listing's secret, which only this module holds;
// builtin/accounts asks it whether a token is good.
namespace starport_announce
{
	struct IdLogin
	{
		ss_ sub;      // the ID's identity in this server's fleet
		ss_ name;     // the name the player picked for the fleet
		ss_ starport; // the Starport's host
		bool adult = false; // "18 or over", told only to an adult listing
	};

	struct Interface
	{
		// Whether starport.json's "login" lets Starport IDs in
		virtual bool accepts_ids() = 0;
		// "" when the token is good, else why not
		virtual ss_ verify_id_token(const ss_ &token, IdLogin *out) = 0;
	};

	// False, and cb not called, where the app does not have the module:
	// builtin/accounts asks on every server, Starport's own among them
	inline bool access(interface::Server *server,
			std::function<void(starport_announce::Interface*)> cb)
	{
		if(!server->has_module("starport_announce"))
			return false;
		return server->access_module("starport_announce",
				[&](interface::Module *module){
			cb((starport_announce::Interface*)module->check_interface());
		});
	}
}
// vim: set noet ts=4 sw=4:
