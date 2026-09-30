// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include "network/api.h"
#include <functional>

// **The server's accounts** ([VANILLA_PUBLIC] 2, from the floorplanner's
// [FP_ACCESS]): who may join and as whom, and who is an admin, for every
// game on the server. A client joins through this module before its game
// lets it in:
// - The accounts are in the server's own save, "_server" (a game leaves
//   saves beginning with _ out of its lists), store "accounts".
// - A password is PBKDF2-HMAC-SHA256 with a salt of its own.
// - A server with no admin prints a setup code; the first to join with it
//   is the admin. A new account needs an invite from an admin, unless
//   registration is open, which it is by default only on a server the
//   launcher started.
// - The launcher's own user of a server it started (launch parameter
//   launcher=1, from 127.0.0.1 or ::1) joins by name alone, and is the
//   first admin.
// - Failed logins wait, doubling, per name and per address; every login is
//   logged.
// - An admin kicks, bans and unbans, and manages the accounts and invites.
//
// The client's side is builtin/accounts/client_lua/accounts.lua: the join
// dialog, and the calls a game's admin pages make.
namespace accounts
{
	typedef network::PeerInfo::Id PeerId;

	// accounts:login: a peer has joined as `name`. accounts:privs: a user's
	// admin changed; their game says so to their client. A peer leaves as
	// network:client_disconnected says.
	struct Login: public interface::Event::Private
	{
		PeerId peer = 0;
		ss_ name;
		Login(PeerId peer, const ss_ &name): peer(peer), name(name){}
	};

	struct Interface
	{
		// The name a peer joined as, or "" before it has
		virtual ss_ name_of(PeerId peer) = 0;
		// The peer that has joined as `name`, or 0
		virtual PeerId find_peer(const ss_ &name) = 0;
		// Its address, as the network module has it (a trusted proxy's
		// X-Forwarded-For included)
		virtual ss_ address_of(PeerId peer) = 0;
		virtual bool is_admin(const ss_ &name) = 0;
		virtual bool exists(const ss_ &name) = 0;
		virtual sv_<ss_> account_names() = 0;
		// The launcher's own user of a server it started
		virtual bool is_local(PeerId peer) = 0;
		// Whether the launcher started this server
		virtual bool launched() = 0;
		// Off the server, told why
		virtual void kick(PeerId peer, const ss_ &why) = 0;
		// A ban by name, and by the address the name last joined from.
		// "" when done, else why not.
		virtual ss_ ban(const ss_ &name, const ss_ &by) = 0;
		// A name or an address; "" when done, else why not
		virtual ss_ unban(const ss_ &name_or_address) = 0;
		// "name|address" per ban, as Luanti's get_ban_list says them
		virtual sv_<ss_> ban_list() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(accounts::Interface*)> cb)
	{
		return server->access_module("accounts", [&](interface::Module *module){
			cb((accounts::Interface*)module->check_interface());
		});
	}
}

// vim: set noet ts=4 sw=4:
