// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Runs a Luanti world and extends nothing. Games and worlds are scanned from
// user_path/luanti, which is buildat's own directory on purpose: nothing here
// reads the content of a real Luanti install, and nothing here can write to
// one. buildat's own minimal game is bundled with the module, so there is
// something to run without one.
//
// For now it runs the first world it finds, or the one BUILDAT_LUANTI_WORLD
// names. The menu the plan describes is a milestone of its own; what this is
// today is the fixture the module is tested against.
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "luanti/api.h"
#include "network/api.h"
#include "replicate/api.h"
#include "client_file/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include <cstdlib>
#include <sys/stat.h>
#include <ctime>
#include <map>
#include <fstream>
#include <cctype>
#include <utility>
#include <set>
#include <sstream>
#include <algorithm>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include "interface/polyvox_cereal.h"
#include "core/sajson.h"
#include "interface/http.h"
#include "interface/zip.h"
#include "interface/thread.h"
#include "interface/os.h"
#include <atomic>
#include <PolyVoxCore/Vector.h>
#define MODULE "main"

using interface::Event;

namespace pv = PolyVox;

#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

namespace vanilla {

struct World
{
	ss_ name;
	ss_ path;
	ss_ gameid;
};

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server){}

	// The scene belongs to builtin/luanti -- it is what knows the world's
	// node ids and its light -- and arrives with luanti:game_loaded. A client
	// that connected while the mods were still loading waits here until it
	// does.
	luanti::SceneReference m_scene = nullptr;
	sv_<network::PeerInfo::Id> m_waiting_peers;
	std::set<network::PeerInfo::Id> m_shown_world;
	// The menu is a script of its own and is run once per peer, for the
	// same reason show_world_to() is: files_transmitted comes again after
	// every batch announced, and the ContentDB screen announces a
	// thumbnail at a time -- twenty-one runs of main/menu.lua in five
	// seconds, each asking for the saves again and drawing the whole menu
	// again over the one on the screen ([CONTENTDB_SCAN])
	std::set<network::PeerInfo::Id> m_shown_menu;
	// Which client took the name BUILDAT_LUANTI_NAME asked for, if any;
	// see player_name_of()
	network::PeerInfo::Id m_named_peer = 0;
	// Where each client last said its player is, applied on the next tick;
	// see on_where()
	// And what the player is holding down, in Luanti's own bit order; see
	// control_bits() in client_lua/init.lua and CONTROL_BITS in
	// builtin/luanti/lua/entity.lua
	struct Where {
		double x = 0, y = 0, z = 0, look_h = 0, look_v = 0;
		int32_t controls = 0;
		double sent_us = 0; // the client's clock, microseconds (cereal's
		                    // Lua side has doubles, not int64)
	};
	sm_<network::PeerInfo::Id, Where> m_pending_where;
	// How long a position update waited on the wire ([NET_SIM]): the
	// client's clock is not the server's, so the age is the excess over
	// the smallest (received - sent) seen from that peer -- the fastest
	// update sets the baseline, a lossy link shows as the rest lagging
	// it. The worst per five seconds is logged.
	struct WhereAge {
		int64_t base_us = 0; // the smallest received - sent, or 0
		int64_t worst_us = 0;
		int64_t window_from_us = 0;
	};
	sm_<network::PeerInfo::Id, WhereAge> m_where_age;
	float m_where_timer = 0.0f;
	// A world runs once: what a second choice would be is a second Luanti
	// environment in one server, which is not what the module is
	bool m_starting = false;
	// The launch param's save is opened by the first main:get_saves packet
	// and by no later one: vanilla's client sends that packet more than
	// once, and a repeat is not a user asking twice
	bool m_launched_param_save = false;
	// [VANILLA_PUBLIC] 1: a server the launcher did not start is public. A
	// client joins through builtin/accounts first, the worlds and ContentDB
	// are an admin's, and the server's imports and settings nobody's.
	bool m_public = false;
	// The world running, or starting
	ss_ m_world_name;
	// [VANILLA_PUBLIC] 5: a switch to another world, which is a restart
	// when this reaches zero: the time left, in seconds, or below 0 for none
	float m_restart_in = -1;
	// The exit status that asks util/serve_latest_release.sh to start the
	// server again at once
	static const int RESTART_STATUS = 20;
	// A public server's chat: per peer, how full the bucket is and when it
	// was last looked at (see on_chat)
	std::map<network::PeerInfo::Id, std::pair<double, int64_t>> m_chat_bucket;
	static constexpr double CHAT_BURST = 5;
	// Who has joined, by the account name their player has
	std::map<network::PeerInfo::Id, ss_> m_names;
	std::set<network::PeerInfo::Id> m_join_sent;

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig_start"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:punch_object"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_saves"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:open"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:save_info"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_world_flags"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:delete"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:create"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_imports"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:set_settings"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:contentdb_query"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:contentdb_install"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:import_game"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:import_world"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:where"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:fell"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:chat"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:wield"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:drop"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("accounts:login"));
		m_server->sub_event(this, Event::t("accounts:privs"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:dig", on_dig,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:dig_start", on_dig_start,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:punch_object",
				on_punch_object, network::Packet)
		EVENT_TYPEN("network:packet_received/main:place", on_place,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_saves", on_get_saves,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:save_info", on_save_info,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_world_flags",
				on_set_world_flags, network::Packet)
		EVENT_TYPEN("network:packet_received/main:delete", on_delete,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:open", on_open,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:create", on_create,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_imports", on_get_imports,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_settings",
				on_get_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:set_settings",
				on_set_settings, network::Packet)
		EVENT_TYPEN("network:packet_received/main:contentdb_query",
				on_contentdb_query, network::Packet)
		EVENT_TYPEN("network:packet_received/main:contentdb_install",
				on_contentdb_install, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_game",
				on_import_game, network::Packet)
		EVENT_TYPEN("network:packet_received/main:import_world",
				on_import_world, network::Packet)
		EVENT_TYPEN("network:packet_received/main:chat", on_chat,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:wield", on_wield,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:drop", on_drop,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:fell", on_fell,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:where", on_where,
				network::Packet)
		EVENT_TYPEN("accounts:login", on_accounts_login, accounts::Login)
		EVENT_TYPEN("accounts:privs", on_accounts_privs, accounts::Login)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
	}

	// A Luanti player per client. The name is this game's to choose and the
	// client does not send one, so it is the peer's number: what it is for
	// is to be the key everything about the player hangs off, and a mod
	// that prints it gets something it can tell apart.
	//
	// BUILDAT_LUANTI_NAME names the first client that connects instead,
	// spelled the way extensions/luanti_client spells it. An imported
	// world's own player is somebody the save already knows -- where they
	// stood, what they carry, what they are allowed to do -- and nothing
	// ever logs in as them otherwise. Only the first client gets the name,
	// because a name is one player and two clients cannot both be them.
	//
	// simplified: an environment variable is not how a player picks
	// themselves. The menu lists the saves and a save knows its players, so
	// choosing one there is the shape this ends up as.
	ss_ player_name_of(network::PeerInfo::Id peer)
	{
		// A public server's players are its accounts ([VANILLA_PUBLIC] 3)
		if(m_public){
			auto it = m_names.find(peer);
			return it != m_names.end() ? it->second : "client"+itos(peer);
		}
		const char *name = getenv("BUILDAT_LUANTI_NAME");
		if(name == nullptr || name[0] == '\0')
			return "client"+itos(peer);
		if(m_named_peer == 0)
			m_named_peer = peer;
		if(m_named_peer != peer)
			return "client"+itos(peer);
		return name;
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
		m_shown_world.erase(old_client.info.id);
		m_shown_menu.erase(old_client.info.id);
		if(!m_scene)
			return;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->remove_player(player_name_of(old_client.info.id));
		});
		m_names.erase(old_client.info.id);
		m_join_sent.erase(old_client.info.id);
		m_chat_bucket.erase(old_client.info.id);
	}

	// Public mode ([VANILLA_PUBLIC])

	// A save a world may be: not _server, which is builtin/accounts', nor
	// any other name beginning with _
	static bool is_world_name(const ss_ &name)
	{
		return !name.empty() && name[0] != '_';
	}

	bool is_admin(network::PeerInfo::Id peer)
	{
		auto it = m_names.find(peer);
		if(it == m_names.end())
			return false;
		bool admin = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			admin = i->is_admin(it->second);
		});
		return admin;
	}

	// What the world menu may do: anything on the launcher's server, and an
	// admin's on a public one
	bool may_manage(network::PeerInfo::Id peer)
	{
		if(!m_public || is_admin(peer))
			return true;
		menu_error(peer, "Only an admin manages this server's worlds");
		return false;
	}

	// The launcher's server's alone: the server's own disk and settings
	bool local_only(network::PeerInfo::Id peer)
	{
		if(!m_public)
			return true;
		menu_error(peer, "Not on a public server");
		return false;
	}

	// [VANILLA_PUBLIC] 5: the world a public server runs, which an admin
	// chose and it starts at boot
	ss_ public_world_file()
	{
		return m_server->get_config().get<ss_>("user_path")+"/games/"+
				m_server->get_game_id()+"/public_world";
	}

	ss_ read_public_world()
	{
		std::ifstream f(public_world_file());
		ss_ name;
		std::getline(f, name);
		return is_world_name(name) ? name : "";
	}

	void write_public_world(const ss_ &name)
	{
		interface::fs::create_directories(
				interface::fs::strip_file_name(public_world_file()));
		std::ofstream f(public_world_file());
		f<<name<<"\n";
	}

	// Another world, by restarting: everyone is told, the choice is kept
	// for the next start, and the server exits with RESTART_STATUS, which
	// the script that runs it takes as start again at once
	void switch_world(const ss_ &name, network::PeerInfo::Id by)
	{
		if(name == m_world_name){
			menu_message(by, name+" is the world running");
			return;
		}
		write_public_world(name);
		log_i(MODULE, "%s switches the world to %s", cs(m_names[by]), cs(name));
		if(m_scene){
			luanti::access(m_server, [&](luanti::Interface *i){
				i->chat_send("", "The server switches to the world "+name+
						": join again in a moment");
			});
		}
		// A moment for that to reach everyone before the connections go
		m_restart_in = 1.5f;
	}

	// A path on the server, as a message says it: the launcher's own user
	// may be told where, and a public server's users are not
	ss_ where(const ss_ &path)
	{
		return m_public ? ss_("(on the server)") : path;
	}

	// A player's packets are a joined player's
	bool joined(network::PeerInfo::Id peer)
	{
		return !m_public || m_names.count(peer);
	}

	// In through the join: the world when there is one; else the world
	// menu for an admin, and for anyone else a wait until an admin has
	// chosen one
	void on_accounts_login(const accounts::Login &login)
	{
		if(!m_public)
			return;
		m_names[login.peer] = login.name;
		if(m_scene){
			show_world_to(login.peer);
			return;
		}
		m_waiting_peers.push_back(login.peer);
		if(is_admin(login.peer)){
			m_shown_menu.insert(login.peer);
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(login.peer, "core:run_script",
						"buildat.run_script_file(\"main/menu.lua\")");
			});
			return;
		}
		sv_<ss_> values{"No world is running on this server yet: an admin "
				"chooses one. You are in as soon as they have."};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(login.peer, "main:join_wait", os.str());
		});
	}

	// What the client shows of the server's: whether it is a public one,
	// whether its user is an admin, the world running, and whether its user
	// is the launcher's own -- the pause menu's pages
	void send_account(network::PeerInfo::Id peer)
	{
		bool is_local = false;
		accounts::access(m_server, [&](accounts::Interface *i){
			is_local = i->is_local(peer);
		});
		sv_<ss_> values{m_public ? "1" : "0", is_admin(peer) ? "1" : "0",
				m_world_name, is_local ? "1" : "0"};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:account", os.str());
		});
	}

	// A server admin has every privilege in the world ([VANILLA_PUBLIC] 3)
	void on_accounts_privs(const accounts::Login &login)
	{
		send_account(login.peer);
		if(!m_public || !m_scene || !m_shown_world.count(login.peer))
			return;
		const bool admin = is_admin(login.peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_admin(login.name, admin);
		});
	}

	// Where a client says its player is, five times a second each. Kept
	// rather than applied: going into the module for each one costs a wait
	// on whatever the module is doing -- a fifth of a second in a game the
	// size of VoxeLibre, and three seconds at its worst -- so five a second
	// per player is more than a second of waiting per second of play, and
	// this module's own queue then grows without bound. Everything a player
	// does afterwards waits behind that backlog: a click took twelve seconds
	// to arrive when this was measured.
	//
	// Only the newest matters anyway, which is what makes keeping it right
	// rather than merely cheap: a position is a heartbeat, like the tick
	// src/server/state.cpp coalesces for the same reason.
	void on_where(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		Where w;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(w.x, w.y, w.z, w.look_h, w.look_v, w.controls, w.sent_us);
		} catch(std::exception &e){
			log_w(MODULE, "main:where: %s", e.what());
			return;
		}
		m_pending_where[packet.sender] = w;
		if(w.sent_us > 0){
			const int64_t now = interface::os::time_us();
			WhereAge &a = m_where_age[packet.sender];
			const int64_t d = now - (int64_t)w.sent_us;
			if(a.base_us == 0 || d < a.base_us)
				a.base_us = d;
			const int64_t age = d - a.base_us;
			if(age > a.worst_us)
				a.worst_us = age;
			if(a.window_from_us == 0)
				a.window_from_us = now;
			if(now - a.window_from_us >= 5000000){
				log_i(MODULE, "where: the worst wait behind the wire in "
						"five seconds %d ms (client %u)",
						(int)(a.worst_us / 1000), (unsigned)packet.sender);
				a.worst_us = 0;
				a.window_from_us = now;
			}
		}
	}

	// And the tick is where they are handed over: one visit to the module
	// for every player who has moved since the last one -- and not on every
	// tick, the server's being thirty a second, but at the rate a client
	// sends at. One visit per fifth of a second for the lot of them is what
	// this is for; thirty would be worse than what it replaced.
	void on_tick(const interface::TickEvent &event)
	{
		if(m_restart_in >= 0){
			m_restart_in -= event.dtime;
			if(m_restart_in < 0)
				m_server->shutdown(RESTART_STATUS, "switching the world");
		}
		poll_contentdb();
		m_where_timer += event.dtime;
		if(m_where_timer < 0.2f)
			return;
		m_where_timer = 0.0f;
		if(m_pending_where.empty())
			return;
		sm_<network::PeerInfo::Id, Where> pending;
		pending.swap(m_pending_where);
		luanti::access(m_server, [&](luanti::Interface *i){
			for(const auto &pair : pending){
				i->set_player_pos(player_name_of(pair.first),
						(float)pair.second.x, (float)pair.second.y,
						(float)pair.second.z, (float)pair.second.look_h,
						(float)pair.second.look_v, pair.second.controls);
			}
		});
	}

	// How hard a player landed, which only their own client knows -- the
	// physics is the client's. What it costs is the module's, so this hands
	// over the speed and nothing else.
	//
	// The number is a client's word, so it is bounded here: below Luanti's
	// own tolerance it costs nothing, and nothing beyond terminal velocity
	// is believed. A client that lies about it can hurt nobody but itself,
	// which is what Luanti's own TOSERVER_DAMAGE is worth as well.
	void on_fell(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		double speed = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(speed);
		} catch(std::exception &e){
			log_w(MODULE, "main:fell: %s", e.what());
			return;
		}
		if(!(speed > 14.0))
			return;
		if(speed > 200.0)
			speed = 200.0;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->player_fell(player_name_of(packet.sender), (float)speed);
		});
	}

	// A line a player typed. What it means is the module's: the callbacks
	// run, the "/" commands among them, and what nobody takes is said to
	// everyone.
	void on_chat(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:chat: %s", e.what());
			return;
		}
		if(values.empty() || values[0].empty())
			return;
		const ss_ &message = values[0];
		// **A public server's chat is limited** ([VANILLA_PUBLIC] 8): a
		// player's lines fill a bucket that empties one a second, and a
		// line into a full one is refused and the player told
		if(m_public){
			const int64_t now = interface::os::time_us();
			auto &b = m_chat_bucket[packet.sender];
			b.first = std::max(0.0, b.first - (now - b.second) / 1e6);
			b.second = now;
			if(b.first + 1 > CHAT_BURST){
				luanti::access(m_server, [&](luanti::Interface *i){
					i->chat_send(player_name_of(packet.sender),
							"Too many lines: wait a moment");
				});
				return;
			}
			b.first += 1;
		}
		luanti::access(m_server, [&](luanti::Interface *i){
			i->chat_message(player_name_of(packet.sender), message);
		});
	}

	// Which hotbar slot the player is holding. The keys and the wheel are
	// the client's, and what is in hand is what the next dig or place asks
	// the module about.
	void on_wield(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:wield: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const int index = atoi(values[0].c_str());
		if(index < 1 || index > 32)
			return;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_wield_index(player_name_of(packet.sender), index);
		});
	}

	// The drop key. The count is how many of the held stack go and zero is
	// all of them, which is what Luanti's Q and Ctrl-Q are.
	void on_drop(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:drop: %s", e.what());
			return;
		}
		const int count = values.empty() ? 0 : atoi(values[0].c_str());
		bool dropped = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			dropped = i->drop_wielded(player_name_of(packet.sender),
					count < 0 ? 0 : count);
		});
		log_v(MODULE, "C%i: main:drop %i: %s", packet.sender, count,
				dropped ? "dropped" : "nothing");
	}

	// A click on the client, as the voxel it pointed at. What it means is
	// the module's to decide: core.dig_node() hands the node to the
	// vendored builtin, which is where can_dig, the drops and every
	// callback around a dig live.
	void on_dig(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 voxel_p;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		} catch(std::exception &e){
			log_w(MODULE, "main:dig: %s", e.what());
			return;
		}
		bool dug = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			dug = i->dig_node(voxel_p.getX(), voxel_p.getY(), voxel_p.getZ(),
					player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:dig " PV3I_FORMAT ": %s", packet.sender,
				PV3I_PARAMS(voxel_p), dug ? "dug" : "nothing");
	}

	// The button going down, which is where a held dig starts: the node is
	// punched, so a mod's on_punch runs on the way in. How long the dig
	// takes is the client's to time -- see core.__dig_props() in the module
	// -- and main:dig is what it sends when it is done.
	void on_dig_start(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 voxel_p;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(voxel_p);
		} catch(std::exception &e){
			log_w(MODULE, "main:dig_start: %s", e.what());
			return;
		}
		luanti::access(m_server, [&](luanti::Interface *i){
			i->punch_node(voxel_p.getX(), voxel_p.getY(), voxel_p.getZ(),
					player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:dig_start " PV3I_FORMAT, packet.sender,
				PV3I_PARAMS(voxel_p));
	}

	// The same button, when what it was pointing at was an object rather
	// than a node: one punch per press, and no faster than the client's own
	// delay while it is held.
	void on_punch_object(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:punch_object: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const int32_t id = atoi(values[0].c_str());
		bool punched = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			punched = i->punch_object(id, player_name_of(packet.sender));
		});
		log_v(MODULE, "C%i: main:punch_object %i: %s", packet.sender, id,
				punched ? "punched" : "nothing");
	}

	// The other button. Luanti calls it place, and what it comes to is the
	// pointed node's on_rightclick if it has one and the wielded item's
	// on_place otherwise; which of the two is the module's to decide. under
	// is the node pointed at and above is the empty voxel in front of it,
	// which is where a node goes.
	void on_place(const network::Packet &packet)
	{
		if(!joined(packet.sender))
			return;
		pv::Vector3DInt32 under, above;
		// Whether the player was holding the key that means "build against
		// this rather than use it"; see place_node() in luanti/api.h
		uint8_t sneak = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(under, above, sneak);
		} catch(std::exception &e){
			log_w(MODULE, "main:place: %s", e.what());
			return;
		}
		bool placed = false;
		luanti::access(m_server, [&](luanti::Interface *i){
			placed = i->place_node(under.getX(), under.getY(), under.getZ(),
					above.getX(), above.getY(), above.getZ(),
					player_name_of(packet.sender), sneak != 0);
		});
		log_v(MODULE, "C%i: main:place " PV3I_FORMAT ": %s", packet.sender,
				PV3I_PARAMS(above), placed ? "placed" : "nothing");
	}

	void on_game_loaded(const luanti::GameLoaded &event)
	{
		m_scene = event.scene;
		log_i(MODULE, "The world is up");
		for(network::PeerInfo::Id peer : m_waiting_peers)
			show_world_to(peer);
		m_waiting_peers.clear();
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		// A public server's client joins first ([VANILLA_PUBLIC] 2), and
		// what it is shown after is on_accounts_login's
		if(m_public && !m_names.count(event.recipient)){
			if(m_join_sent.insert(event.recipient).second){
				// The join's title is the Luanti game running, which the
				// script waits for; "" before an admin has chosen a world
				ss_ title;
				if(!m_world_name.empty()){
					const ss_ gameid = gameid_of_save(m_world_name);
					const ss_ game_path = find_game(gameid);
					title = game_path.empty() ? gameid :
							read_game_title(game_path);
				}
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(sv_<ss_>{title});
				}
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(event.recipient, "core:run_script",
							"buildat.run_script_file(\"main/join.lua\")");
					inetwork->send(event.recipient, "main:join_title",
							os.str());
				});
			}
			return;
		}
		if(!m_scene){
			// Waiting for an admin to choose a world
			if(m_public && !is_admin(event.recipient))
				return;
			if(!m_shown_menu.insert(event.recipient).second)
				return;
			m_waiting_peers.push_back(event.recipient);
			// Nothing to look at yet, so what the client draws is the menu:
			// which save, and which game it needs. A world that was chosen
			// before this client arrived is already on its way up, and the
			// menu says so rather than offering another.
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(event.recipient, "core:run_script",
						"buildat.run_script_file(\"main/menu.lua\")");
			});
			return;
		}
		show_world_to(event.recipient);
	}

	// One key of what an untrusted launcher asked for, through the server's
	// -u ([LAUNCH_GRID]): read as a packet would be -- a value of the shape
	// a directory name has, or "" with a warning. The lines are key=value.
	ss_ launch_param(const ss_ &key_name)
	{
		const ss_ u = m_server->get_config().get<ss_>("untrusted_launch");
		const ss_ key = key_name + "=";
		size_t at = u.find(key);
		if(at == ss_::npos || !(at == 0 || u[at - 1] == '\n'))
			return "";
		ss_ v = u.substr(at + key.size());
		v = v.substr(0, v.find('\n'));
		bool ok = !v.empty() && v.size() <= 64;
		for(char c : v)
			if(!(isalnum((unsigned char)c) || c == '_' || c == '-'))
				ok = false;
		if(!ok){
			log_w(MODULE, "untrusted_launch: %s refused", cs(key_name));
			return "";
		}
		return v;
	}

	// The two lists the menu is: every save this game has, with the Luanti
	// game each one says it needs, and every Luanti game there is to choose
	// from. Flat, with the number of saves leading, because that is what one
	// array of strings can carry.
	void on_get_saves(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		// **A launch that named a save opens it and never draws a menu**
		// ([LAUNCH_WORLD]: a save opened through ctx.launch's params).
		// The launcher hands "save=<name>" to the server's -u, which is
		// the same door "menu" and "luanti_game" come through, and the
		// save says itself which game it needs.
		{
			ss_ save = launch_param("save");
			if(save != "" && m_launched_param_save)
				return;
			if(save != ""){
				ss_ gameid = gameid_of_save(save);
				if(gameid == ""){
					log_w(MODULE, "untrusted_launch: save %s does not say"
							" which game it needs", cs(save));
				} else {
					log_i(MODULE, "untrusted_launch: opening save %s",
							cs(save));
					m_launched_param_save = true;
					start_world(gameid, save, packet.sender, "", true);
					return;
				}
			}
		}
		// A launch that asked for one of the menu's screens -- import_game,
		// import_world -- says so before the lists, and the client opens
		// that screen over them ([LAUNCH_GRID])
		{
			ss_ menu = launch_param("menu");
			if(menu == "worlds"){
				ss_ game = launch_param("luanti_game");
				if(game != "")
					menu += ":"+game;
			}
			if(menu != ""){
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(packet.sender, "main:menu", menu);
				});
			}
		}
		// A public server's menu has no imports and no local settings, and
		// over a running world it goes back to it ([VANILLA_PUBLIC] 5)
		if(m_public){
			const ss_ menu = m_starting ? "public_running" : "public";
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(packet.sender, "main:menu", menu);
			});
		}
		sv_<ss_> flat;
		sv_<ss_> saves;
		storage::access(m_server, [&](storage::Interface *istorage){
			sv_<storage::SaveInfo> infos = istorage->list();
			// The one played last is the one most likely wanted next
			std::sort(infos.begin(), infos.end(),
					[](const storage::SaveInfo &a, const storage::SaveInfo &b){
				return a.modified_us > b.modified_us;
			});
			// _server is builtin/accounts', and _ is not a world's
			for(const storage::SaveInfo &info : infos)
				if(!info.name.empty() && info.name[0] != '_')
					saves.push_back(info.name);
		});
		flat.push_back(itos(saves.size()));
		for(const ss_ &name : saves){
			flat.push_back(name);
			flat.push_back(gameid_of_save(name));
		}
		for(const ss_ &id : list_games())
			flat.push_back(id);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:saves", os.str());
		});
	}

	// A save records which Luanti game it needs, as a key in the save rather
	// than in a world.mt: which save and which game it needs were always two
	// facts pretending to be one.
	ss_ gameid_of_save(const ss_ &name)
	{
		ss_ gameid;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			save->store("main")->get("gameid", gameid);
			istorage->close(save);
		});
		return gameid;
	}

	// world.mt's lines as key -> value; a missing file is empty
	static std::map<ss_, ss_> read_world_mt(const ss_ &path)
	{
		std::map<ss_, ss_> out;
		std::ifstream f(path);
		ss_ line;
		while(std::getline(f, line)){
			const size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ k = line.substr(0, eq), v = line.substr(eq + 1);
			auto trim = [](ss_ &t){
				while(!t.empty() && isspace((unsigned char)t.back())) t.pop_back();
				size_t i = 0;
				while(i < t.size() && isspace((unsigned char)t[i])) i++;
				t = t.substr(i);
			};
			trim(k); trim(v);
			if(!k.empty())
				out[k] = v;
		}
		return out;
	}
	// The file written back with these keys set, the other lines kept
	static void write_world_mt(const ss_ &path, const std::map<ss_, ss_> &set)
	{
		std::map<ss_, ss_> all = read_world_mt(path);
		for(const auto &kv : set)
			all[kv.first] = kv.second;
		interface::fs::create_directories(interface::fs::strip_file_name(path));
		std::ofstream f(path, std::ios::trunc);
		for(const auto &kv : all)
			f << kv.first << " = " << kv.second << "\n";
	}

	// main:save_info <name>: what a save answers at a glance, as a flat
	// list of key, value pairs ([WORLD_LIST]) -- one open, a few keys, one
	// count. The section count is voxelworld's "main/s<x>,<y>,<z>/generated"
	// keys; the size the directory's.
	void on_save_info(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:save_info: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const ss_ name = values[0];
		if(!is_world_name(name))
			return;
		sv_<ss_> flat{"name", name};
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(name);
			if(!save)
				return;
			ss_ gameid, seed, mg_name, clock, created;
			save->store("main")->get("gameid", gameid);
			save->store("main")->get("created", created);
			storage::Store *lu = save->store("luanti");
			lu->get("seed", seed);
			lu->get("mg_name", mg_name);
			lu->get("clock", clock);
			const size_t sections =
					save->store("voxelworld")->list("main/s").size();
			const ss_ path = save->path();
			istorage->close(save);
			flat.push_back("game"); flat.push_back(gameid);
			const ss_ game_path = find_game(gameid);
			flat.push_back("title");
			flat.push_back(game_path.empty() ? gameid : read_game_title(game_path));
			flat.push_back("seed"); flat.push_back(seed);
			flat.push_back("mapgen"); flat.push_back(mg_name);
			if(clock.size() > 1){
				try {
					std::istringstream is(clock, std::ios::binary);
					cereal::PortableBinaryInputArchive ar(is);
					uint8_t version = 0; double tod = 0, gt = 0; int32_t days = 0;
					ar(version, tod, gt, days);
					flat.push_back("day"); flat.push_back(itos(days));
					char buf[16];
					snprintf(buf, sizeof buf, "%02d:%02d", (int)(tod * 24) % 24,
							(int)(tod * 24 * 60) % 60);
					flat.push_back("time"); flat.push_back(buf);
					// As text: the sandbox has no os.date and no clock
					char played[32];
					if(gt >= 3600)
						snprintf(played, sizeof played, "%.1f h", gt / 3600);
					else
						snprintf(played, sizeof played, "%d min", (int)(gt / 60));
					flat.push_back("played"); flat.push_back(played);
				} catch(std::exception &){}
			}
			flat.push_back("sections"); flat.push_back(itos((int64_t)sections));
			flat.push_back("bytes");
			flat.push_back(itos((int64_t)interface::fs::directory_tree_size(path)));
			struct stat st;
			auto date_of = [](time_t t){
				char buf[32];
				strftime(buf, sizeof buf, "%Y-%m-%d %H:%M", localtime(&t));
				return ss_(buf);
			};
			if(stat((path+"/save.sqlite").c_str(), &st) == 0){
				flat.push_back("played_at"); flat.push_back(date_of(st.st_mtime));
			}
			// The save's own "created" from on_create; a save from before
			// it has the oldest of its files' times, which a rewritten
			// world.mt or database moves (a directory's ctime is its last
			// change on Linux, not its birth)
			if(!created.empty()){
				flat.push_back("created_at");
				flat.push_back(date_of((time_t)atoll(created.c_str())));
			} else if(stat((path+"/save.sqlite").c_str(), &st) == 0){
				time_t oldest = st.st_ctime;
				for(const interface::fs::Node &n :
						interface::fs::list_directory(path)){
					struct stat s2;
					if(stat((path+"/"+n.name).c_str(), &s2) == 0 &&
							s2.st_mtime < oldest)
						oldest = s2.st_mtime;
				}
				flat.push_back("created_at"); flat.push_back(date_of(oldest));
			}
			const std::map<ss_, ss_> mt = read_world_mt(path+"/luanti/world.mt");
			auto flag = [&](const char *key, const char *dflt){
				auto it = mt.find(key);
				flat.push_back(key);
				flat.push_back(it == mt.end() ? ss_(dflt) : it->second);
			};
			flag("creative_mode", "false");
			flag("enable_damage", "true");
		});
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:save_info", os.str());
		});
	}

	// main:set_world_flags <name> <creative_mode> <enable_damage>: into the
	// save's world.mt, which core.settings reads when the world loads
	void on_set_world_flags(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:set_world_flags: %s", e.what());
			return;
		}
		if(values.size() < 3 || !is_world_name(values[0]))
			return;
		ss_ path;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(values[0]);
			if(save){
				path = save->path();
				istorage->close(save);
			}
		});
		if(path.empty())
			return;
		std::map<ss_, ss_> set;
		set["creative_mode"] = values[1] == "true" ? "true" : "false";
		set["enable_damage"] = values[2] == "true" ? "true" : "false";
		write_world_mt(path+"/luanti/world.mt", set);
		log_i(MODULE, "%s: creative_mode %s, enable_damage %s", cs(values[0]),
				cs(set["creative_mode"]), cs(set["enable_damage"]));
		on_save_info(packet); // the panel re-reads
	}

	// main:delete <name>: the save's directory moved to saves/trash/<name>-
	// <date>, not removed; the list is sent again
	void on_delete(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:delete: %s", e.what());
			return;
		}
		if(values.empty() || !is_world_name(values[0]))
			return;
		if(m_starting && values[0] == m_world_name){
			menu_error(packet.sender, "The world that is running is not "
					"deleted");
			return;
		}
		ss_ path;
		storage::access(m_server, [&](storage::Interface *istorage){
			storage::Save *save = istorage->open(values[0]);
			if(save){
				path = save->path();
				istorage->close(save);
			}
		});
		if(path.empty()){
			menu_error(packet.sender, "There is no save called "+values[0]);
			return;
		}
		const ss_ trash = interface::fs::strip_file_name(path)+"/trash";
		interface::fs::create_directories(trash);
		time_t now = time(NULL);
		char date[32];
		strftime(date, sizeof date, "%Y-%m-%d_%H%M%S", localtime(&now));
		const ss_ to = trash+"/"+values[0]+"-"+date;
		if(rename(path.c_str(), to.c_str()) != 0){
			menu_error(packet.sender, "Could not move "+where(path)+" to "+
					where(to));
			return;
		}
		log_i(MODULE, "Save %s moved to %s", cs(values[0]), cs(to));
		menu_message(packet.sender, values[0]+" moved to the trash");
	}

	sv_<ss_> list_games()
	{
		sv_<ss_> out;
		ss_ dir = luanti_path()+"/games";
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			if(interface::fs::path_exists(dir+"/"+n.name+"/game.conf"))
				out.push_back(n.name);
		}
		// The one buildat ships, so that there is something to choose
		// without a Luanti installation
		if(interface::fs::path_exists(bundled_game_path()+"/game.conf"))
			out.push_back("minimal");
		std::sort(out.begin(), out.end());
		return out;
	}

	//
	// Importing a game and a world from a real Luanti installation
	//
	// Nothing here writes to any of those directories: they are read, and a
	// game is copied out of one into buildat's own. See "The importer" in
	// doc/plan/master_plan.md.
	//

	// Where a Luanti installation might be, most deliberate first. Each is a
	// directory laid out the way a Luanti user directory is -- games/ and
	// worlds/ inside it -- which is also the shape of an in-tree development
	// build, so that needs no special case.
	// The launcher's settings, in the user path beside luanti/games and
	// luanti/worlds ([LAUNCH_GRID]): {"import_paths": ["..."],
	// "render_mode": "pbr"}, the search paths the import screens add to
	// the defaults and the mode a session draws in when BUILDAT_LUANTI_PBR
	// says nothing (read by builtin/luanti where the variable is). Written
	// by hand and read with sajson. On the wire the two are one list of
	// strings, the mode as a "render_mode=<mode>" entry after the paths.
	ss_ settings_path()
	{
		return luanti_path()+"/settings.json";
	}
	// One string value of settings.json's top level, or "" when absent
	ss_ read_setting(const ss_ &key)
	{
		std::ifstream f(settings_path());
		if(!f.good())
			return "";
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const sajson::document doc =
				sajson::parse(sajson::string(text.c_str(), text.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_OBJECT)
			return "";
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			if(root.get_object_key(i).as_string() == key &&
					root.get_object_value(i).get_type() == sajson::TYPE_STRING)
				return root.get_object_value(i).as_string();
		}
		return "";
	}
	ss_ read_render_mode()
	{
		return read_setting("render_mode");
	}
	// The viewing range ([VIEW_RANGE]): "view_range": "<n>", 120 when
	// absent so a new install bets on no strong computer; 20..4000 as
	// official's
	// view_bobbing_amount ([VIEW_BOB]): 1 unless set, 0 off; BUILDAT_VIEW_BOBBING
	// for one run, which is how the reference shooters keep their probes still
	ss_ read_view_bobbing()
	{
		const char *env = getenv("BUILDAT_VIEW_BOBBING");
		const ss_ v = env ? ss_(env) : read_setting("view_bobbing_amount");
		const double n = atof(v.c_str());
		if(v.empty() || n < 0 || n > 7.9)
			return "1";
		char buf[16];
		snprintf(buf, sizeof buf, "%g", n);
		return buf;
	}
	// How far full detail reaches, as a share of the viewing range
	// ([CLIENT_FRAME]): "lod_detail": "full" | "half" | "third". Beyond
	// it voxelworld meshes chunks at a reduced LOD, which is how a
	// machine whose GPU is slower than its processor keeps its range --
	// LOD spends CPU to buy triangles back. "full" is the default, which
	// is the look as it has always been.
	ss_ read_lod_detail()
	{
		const char *env = getenv("BUILDAT_LOD_DETAIL");
		const ss_ v = env ? ss_(env) : read_setting("lod_detail");
		return (v == "half" || v == "third") ? v : ss_("full");
	}
	ss_ read_view_range()
	{
		// BUILDAT_VIEW_RANGE for one run: the reference shooters set their
		// range this way, over whatever the user's settings.json says
		const char *env = getenv("BUILDAT_VIEW_RANGE");
		const ss_ v = env ? ss_(env) : read_setting("view_range");
		const int n = atoi(v.c_str());
		return (n >= 20 && n <= 4000) ? itos(n) : ss_("120");
	}
	// "web_view_range": the web client's viewing range unless its player
	// chose one (user, 2026-09-30): a browser meshes on one thread and
	// loads a world slower. "" when not set, and the client's own default
	// (80, 60 on a touchscreen) holds; never over view_range either way.
	ss_ read_web_view_range()
	{
		const int n = atoi(read_setting("web_view_range").c_str());
		return (n >= 20 && n <= 4000) ? itos(n) : ss_();
	}
	// The key bindings ([KEY_BINDINGS]): settings.json's "keys" object,
	// action to key name, as "key.<action>=<name>" rows of the list
	sv_<ss_> read_key_rows()
	{
		sv_<ss_> out;
		std::ifstream f(settings_path());
		if(!f.good())
			return out;
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const sajson::document doc =
				sajson::parse(sajson::string(text.c_str(), text.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_OBJECT)
			return out;
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			if(root.get_object_key(i).as_string() != "keys")
				continue;
			sajson::value keys = root.get_object_value(i);
			if(keys.get_type() != sajson::TYPE_OBJECT)
				continue;
			for(size_t j = 0; j < keys.get_length(); j++){
				sajson::value v = keys.get_object_value(j);
				if(v.get_type() == sajson::TYPE_STRING && !v.as_string().empty())
					out.push_back("key."+keys.get_object_key(j).as_string()+
							"="+v.as_string());
			}
		}
		return out;
	}
	sv_<ss_> read_import_paths()
	{
		sv_<ss_> out;
		std::ifstream f(settings_path());
		if(!f.good())
			return out;
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const sajson::document doc =
				sajson::parse(sajson::string(text.c_str(), text.size()));
		if(!doc.is_valid()){
			log_w(MODULE, "%s: %s", cs(settings_path()),
					cs(doc.get_error_message()));
			return out;
		}
		sajson::value root = doc.get_root();
		if(root.get_type() != sajson::TYPE_OBJECT)
			return out;
		for(size_t i = 0; i < root.get_length(); i++){
			if(root.get_object_key(i).as_string() != "import_paths")
				continue;
			sajson::value list = root.get_object_value(i);
			if(list.get_type() != sajson::TYPE_ARRAY)
				continue;
			for(size_t j = 0; j < list.get_length(); j++){
				sajson::value v = list.get_array_element(j);
				if(v.get_type() == sajson::TYPE_STRING && !v.as_string().empty())
					out.push_back(v.as_string());
			}
		}
		return out;
	}
	static void write_json_string(std::ofstream &f, const ss_ &s)
	{
		f << '"';
		for(char c : s){
			if(c == '"' || c == '\\')
				f << '\\' << c;
			else if((unsigned char)c < 0x20)
				f << ' ';
			else
				f << c;
		}
		f << '"';
	}
	void write_settings(const sv_<ss_> &paths, const ss_ &mode,
			const sv_<std::pair<ss_, ss_>> &keys, const ss_ &view_range,
			const ss_ &view_bobbing, const ss_ &shoulder,
			const ss_ &lod_detail)
	{
		// Set by hand only, so kept through the settings screen's save
		const ss_ web_range = read_web_view_range();
		interface::fs::create_directories(luanti_path());
		std::ofstream f(settings_path(), std::ios::trunc);
		f << "{\"render_mode\": \"" << mode << "\", \"view_range\": \""
				<< view_range << "\", ";
		if(!web_range.empty())
			f << "\"web_view_range\": \"" << web_range << "\", ";
		f << "\"lod_detail\": \""
				<< lod_detail << "\", \"view_bobbing_amount\": \""
				<< view_bobbing << "\", \"third_person_shoulder\": \""
				<< shoulder << "\", \"import_paths\": [";
		for(size_t i = 0; i < paths.size(); i++){
			f << (i ? ", " : "");
			write_json_string(f, paths[i]);
		}
		f << "], \"keys\": {";
		for(size_t i = 0; i < keys.size(); i++){
			f << (i ? ", " : "");
			write_json_string(f, keys[i].first);
			f << ": ";
			write_json_string(f, keys[i].second);
		}
		f << "}}\n";
		if(!f.good())
			log_w(MODULE, "could not write %s", cs(settings_path()));
	}
	void send_settings(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			// A public server's import paths are nobody's business
			sv_<ss_> list = m_public ? sv_<ss_>() : read_import_paths();
			ss_ mode = read_render_mode();
			list.push_back("render_mode="+(mode.empty() ? ss_("pbr") : mode));
			list.push_back("view_range="+read_view_range());
			const ss_ web_range = read_web_view_range();
			if(!web_range.empty())
				list.push_back("web_view_range="+web_range);
			list.push_back("lod_detail="+read_lod_detail());
			list.push_back("view_bobbing_amount="+read_view_bobbing());
			// The back view centred or over the shoulder ([OVER_SHOULDER])
			list.push_back("third_person_shoulder="+
					(read_setting("third_person_shoulder") == "1" ?
					ss_("1") : ss_("0")));
			for(const ss_ &row : read_key_rows())
				list.push_back(row);
			ar(list);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:settings", os.str());
		});
	}
	// ContentDB ([CONTENTDB]): a browser of its games, the server fetching
	// through libcurl on a thread per job -- a listing, an install -- and
	// on_tick() reading the finished ones. The listing is the API's
	// packages query, games only, sent to the client as five strings a
	// row; an install takes the newest release's zip into the cache and
	// extracts it under luanti/games/<name>, the way an import lands.
	static const char *CONTENTDB;
	struct Job : public interface::ThreadedThing {
		enum Kind { LIST, INSTALL, PICTURE } kind;
		network::PeerInfo::Id peer;
		ss_ q; // LIST: the query; INSTALL: author/name; PICTURE: the url
		ss_ name; // INSTALL: the game's directory; PICTURE: the client file
		ss_ zip_path, into_dir;
		ss_ result, error;
		std::atomic<uint64_t> got{0}, total{0};
		// INSTALL: 0 downloading, 1 unpacking, 2 installing -- the screen
		// says which, since the unpack of a big game is seconds of nothing
		// at "100 %" otherwise ([BOX_PLAYTEST_2] 5)
		std::atomic<int> phase{0};
		std::atomic<bool> done{false};
		interface::Thread *thread = nullptr;
		void run(interface::Thread *) override
		{
			try {
				if(kind == LIST){
					// Twenty, the most downloaded first: the whole list is
					// hundreds and the screen has no pages yet (the search
					// field narrows it)
					result = interface::http_get(ss_(CONTENTDB)+
							"/api/packages/?type=game&limit=20&sort=downloads"
							"&order=desc&q="+q);
				} else if(kind == PICTURE){
					// A picture already fetched is not fetched again; the
					// cache path is the download's ([CONTENTDB_LIST])
					if(!interface::fs::path_exists(zip_path))
						interface::http_download(q, zip_path);
				} else {
					const ss_ rel = interface::http_get(ss_(CONTENTDB)+
							"/api/packages/"+q+"/releases/");
					const ss_ url = newest_release_url(rel);
					if(url.empty())
						throw Exception("no release to download");
					interface::http_download(url, zip_path,
							[&](uint64_t g, uint64_t t){
						got = g; total = t; return true;
					});
					phase = 1;
					interface::fs::remove_all(into_dir);
					interface::zip_extract(zip_path, into_dir);
					phase = 2;
					interface::fs::remove_all(zip_path);
				}
			} catch(std::exception &e){
				error = e.what();
			}
			done = true;
		}
		void on_crash(interface::Thread *) override
		{
			error = "the fetch crashed";
			done = true;
		}
		// The releases list is newest first; "url" is the zip, absolute
		// or site-relative
		static ss_ newest_release_url(const ss_ &json)
		{
			const sajson::document doc =
					sajson::parse(sajson::string(json.c_str(), json.size()));
			if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_ARRAY ||
					doc.get_root().get_length() == 0)
				return "";
			sajson::value r = doc.get_root().get_array_element(0);
			if(r.get_type() != sajson::TYPE_OBJECT)
				return "";
			for(size_t i = 0; i < r.get_length(); i++){
				if(r.get_object_key(i).as_string() == "url" &&
						r.get_object_value(i).get_type() == sajson::TYPE_STRING){
					ss_ u = r.get_object_value(i).as_string();
					if(!u.empty() && u[0] == '/')
						u = ss_(CONTENTDB)+u;
					return u;
				}
			}
			return "";
		}
	};
	// The thread owns its Job (interface::Thread deletes the thing it
	// ran); this list is the jobs still to be read
	sv_<Job*> m_contentdb_jobs;

	static ss_ url_encode(const ss_ &s)
	{
		ss_ out;
		char buf[4];
		for(unsigned char c : s){
			if(isalnum(c) || c == '-' || c == '_' || c == '.')
				out += (char)c;
			else {
				snprintf(buf, sizeof buf, "%%%02X", c);
				out += buf;
			}
		}
		return out;
	}

	void start_job(Job *job)
	{
		job->thread = interface::createThread(job);
		job->thread->set_name("contentdb");
		job->thread->start();
		m_contentdb_jobs.push_back(job);
	}

	void on_contentdb_query(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:contentdb_query: %s", e.what());
			return;
		}
		Job *job = new Job();
		job->kind = Job::LIST;
		job->peer = packet.sender;
		job->q = url_encode(values.empty() ? "" : values[0].substr(0, 200));
		start_job(job);
	}

	void on_contentdb_install(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:contentdb_install: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		const ss_ author = values[0], name = values[1];
		// A name is a directory: letters, digits, _ and - only
		for(const ss_ *v : {&author, &name}){
			for(char c : *v){
				if(!isalnum((unsigned char)c) && c != '_' && c != '-'){
					menu_error(packet.sender, "Not a ContentDB name: "+*v);
					return;
				}
			}
		}
		const ss_ to = luanti_path()+"/games/"+name;
		if(interface::fs::path_exists(to)){
			menu_error(packet.sender, name+" is already installed. Remove "+
					where(to)+" yourself if you mean to replace it.");
			return;
		}
		Job *job = new Job();
		job->kind = Job::INSTALL;
		job->peer = packet.sender;
		job->q = author+"/"+name;
		job->name = name;
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		interface::fs::create_directories(cache);
		job->zip_path = cache+"/"+author+"_"+name+".zip";
		job->into_dir = to+".installing";
		send_progress(packet.sender, "Fetching "+name+"...");
		start_job(job);
	}

	// The finished jobs answered, the running installs' progress told
	void poll_contentdb()
	{
		for(size_t i = 0; i < m_contentdb_jobs.size(); ){
			Job *job = m_contentdb_jobs[i];
			if(!job->done){
				if(job->kind == Job::INSTALL && job->phase == 1)
					send_progress(job->peer, "Unpacking "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->phase == 2)
					send_progress(job->peer, "Installing "+job->name+"...");
				else if(job->kind == Job::INSTALL && job->total > 0){
					send_progress(job->peer, "Downloading "+job->name+": "+
							itos(job->got * 100 / job->total)+"%");
				}
				i++;
				continue;
			}
			m_contentdb_jobs.erase(m_contentdb_jobs.begin() + i);
			job->thread->request_stop();
			job->thread->join();
			// The job's fields read before the thread (and with it the
			// job) is deleted at the end of the block
			struct Free { interface::Thread *t; ~Free(){ delete t; } } free{job->thread};
			if(job->peer == 0 && job->kind == Job::LIST){
				log_i(MODULE, "contentdb: fetched once: %s",
						job->error.empty() ? cs("ok, "+itos(job->result.size())+
						" bytes") : cs("error: "+job->error));
				continue;
			}
			if(!job->error.empty() && job->kind == Job::PICTURE){
				// A picture that does not come leaves its placeholder
				log_v(MODULE, "contentdb: no picture %s: %s", cs(job->name),
						cs(job->error));
				interface::fs::remove_all(job->zip_path);
				continue;
			}
			if(!job->error.empty()){
				menu_error(job->peer, (job->kind == Job::LIST ?
						"ContentDB: " : "Installing "+job->name+" failed: ")+
						job->error);
				continue;
			}
			if(job->kind == Job::LIST){
				send_contentdb_list(job->peer, job->result);
				continue;
			}
			if(job->kind == Job::PICTURE){
				// The file to every client, the name to the one that asked:
				// its row asks the cache for it until it has arrived
				client_file::access(m_server, [&](client_file::Interface *i){
					i->add_file_path(job->name, job->zip_path);
				});
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(sv_<ss_>{job->name});
				}
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(job->peer, "main:contentdb_picture", os.str());
				});
				continue;
			}
			// The zip's one top-level directory is the game; renamed into
			// place, and the game shows on the grid as an imported one does
			ss_ top;
			size_t tops = 0;
			for(const auto &n : interface::fs::list_directory(job->into_dir)){
				if(n.is_directory){
					top = n.name;
					tops++;
				}
			}
			const ss_ to = luanti_path()+"/games/"+job->name;
			const ss_ from = tops == 1 ? job->into_dir+"/"+top : job->into_dir;
			if(rename(from.c_str(), to.c_str()) != 0){
				menu_error(job->peer, "Installing "+job->name+" failed: cannot "
						"rename "+where(from));
				continue;
			}
			interface::fs::remove_all(job->into_dir);
			log_i(MODULE, "Installed game %s from ContentDB", cs(job->name));
			menu_message(job->peer, job->name+" installed from ContentDB");
		}
	}

	// Five strings a row: author, name, title, short_description, thumbnail
	void send_contentdb_list(network::PeerInfo::Id peer, const ss_ &json)
	{
		sv_<ss_> flat;
		const sajson::document doc =
				sajson::parse(sajson::string(json.c_str(), json.size()));
		if(!doc.is_valid() || doc.get_root().get_type() != sajson::TYPE_ARRAY){
			menu_error(peer, "ContentDB answered with something that is not "
					"a list");
			return;
		}
		sajson::value root = doc.get_root();
		for(size_t i = 0; i < root.get_length(); i++){
			sajson::value r = root.get_array_element(i);
			if(r.get_type() != sajson::TYPE_OBJECT)
				continue;
			ss_ f[5];
			static const char *keys[5] = {"author", "name", "title",
					"short_description", "thumbnail"};
			for(size_t j = 0; j < r.get_length(); j++){
				const ss_ k = r.get_object_key(j).as_string();
				sajson::value v = r.get_object_value(j);
				if(v.get_type() != sajson::TYPE_STRING)
					continue;
				for(size_t n = 0; n < 5; n++)
					if(k == keys[n])
						f[n] = v.as_string();
			}
			for(size_t n = 0; n < 5; n++)
				flat.push_back(f[n]);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:contentdb_list", os.str());
		});
		// The pictures after the list, one job each, so a slow one holds
		// nothing but its own row ([CONTENTDB_LIST]); on the wire the row
		// names its picture "contentdb/<author>_<name>.png"
		const ss_ cache = m_server->get_config().get<ss_>("cache_path")+
				"/luanti/contentdb";
		interface::fs::create_directories(cache);
		for(size_t i = 0; i + 4 < flat.size(); i += 5){
			ss_ url = flat[i + 4];
			if(url.empty())
				continue;
			if(url[0] == '/')
				url = ss_(CONTENTDB)+url;
			bool word = true;
			for(const ss_ *v : {&flat[i], &flat[i + 1]})
				for(char c : *v)
					if(!isalnum((unsigned char)c) && c != '_' && c != '-')
						word = false;
			if(!word)
				continue;
			Job *job = new Job();
			job->kind = Job::PICTURE;
			job->peer = peer;
			job->q = url;
			job->name = "contentdb/"+flat[i]+"_"+flat[i + 1]+".png";
			job->zip_path = cache+"/"+flat[i]+"_"+flat[i + 1]+".png";
			start_job(job);
		}
	}

	void on_get_settings(const network::Packet &packet)
	{
		send_settings(packet.sender);
	}
	// The whole list, replacing what was there: the screen adds and
	// removes, and sends the result
	void on_set_settings(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:set_settings: %s", e.what());
			return;
		}
		sv_<ss_> paths;
		sv_<std::pair<ss_, ss_>> keys;
		ss_ mode = "pbr";
		ss_ view_range = "120";
		ss_ view_bobbing = "1";
		ss_ shoulder = "0";
		ss_ lod_detail = "full";
		for(const ss_ &v : values){
			if(v.compare(0, 22, "third_person_shoulder=") == 0){
				shoulder = v.substr(22) == "1" ? "1" : "0";
				continue;
			}
			if(v.compare(0, 20, "view_bobbing_amount=") == 0){
				const double n = atof(v.c_str() + 20);
				if(n >= 0 && n <= 7.9){
					char buf[16];
					snprintf(buf, sizeof buf, "%g", n);
					view_bobbing = buf;
				}
				continue;
			}
			if(v.compare(0, 12, "render_mode=") == 0){
				const ss_ m = v.substr(12);
				if(m == "unlit" || m == "shadows" || m == "pbr")
					mode = m;
			} else if(v.compare(0, 11, "view_range=") == 0){
				const int n = atoi(v.c_str() + 11);
				if(n >= 20 && n <= 4000)
					view_range = itos(n);
			} else if(v.compare(0, 11, "lod_detail=") == 0){
				const ss_ d = v.substr(11);
				if(d == "full" || d == "half" || d == "third")
					lod_detail = d;
			} else if(v.compare(0, 4, "key.") == 0){
				// key.<action>=<name>: the action a word, the name short
				const size_t eq = v.find('=');
				if(eq != ss_::npos && eq > 4 && v.size() - eq - 1 <= 32){
					const ss_ action = v.substr(4, eq - 4);
					bool word = true;
					for(char c : action)
						if(!isalnum((unsigned char)c) && c != '_')
							word = false;
					if(word)
						keys.push_back({action, v.substr(eq + 1)});
				}
			} else if(!v.empty() && v.size() <= 4096)
				paths.push_back(v);
		}
		write_settings(paths, mode, keys, view_range, view_bobbing, shoulder,
				lod_detail);
		log_i(MODULE, "settings: %zu import paths, render_mode %s, view_range "
				"%s and %zu key bindings written to %s", paths.size(), cs(mode),
				cs(view_range), keys.size(), cs(settings_path()));
		send_settings(packet.sender);
	}

	sv_<ss_> import_roots()
	{
		sv_<ss_> out;
		// Said out loud, every one of them: a wrong variable name, a typo, a
		// path that is not there and a directory at the wrong level of a
		// tree all look the same from the menu -- a short list and no
		// reason -- and that is what turns a one-word mistake into a bug
		// report. This is a menu action rather than a loop, so the lines
		// cost nothing.
		auto add = [&](const ss_ &path, const ss_ &from){
			if(path.empty())
				return;
			if(!interface::fs::path_exists(path)){
				log_i(MODULE, "import: %s: no such path (%s)", cs(path),
						cs(from));
				return;
			}
			for(const ss_ &had : out){
				if(had == path){
					log_i(MODULE, "import: %s: already looked at (%s)",
							cs(path), cs(from));
					return;
				}
			}
			const bool has_games =
					interface::fs::path_exists(path+"/games");
			const bool has_worlds =
					interface::fs::path_exists(path+"/worlds");
			if(!has_games && !has_worlds){
				// Which is what pointing the variable at the wrong level of
				// a tree looks like, and the likeliest mistake after the
				// name of the variable itself
				log_w(MODULE, "import: %s has neither games/ nor worlds/ in "
						"it; a Luanti user directory has both (%s)",
						cs(path), cs(from));
			} else {
				log_i(MODULE, "import: %s (%s)%s%s", cs(path), cs(from),
						has_games ? " games/" : "",
						has_worlds ? " worlds/" : "");
			}
			out.push_back(path);
		};
		// The settings' paths first, the variable as an additional source
		// for the shell and the runners
		for(const ss_ &path : read_import_paths())
			add(path, "settings.json");
		const char *extra = getenv("LUANTI_EXTRA_IMPORT_PATH");
		if(extra && extra[0]){
			// Several, separated the way every other path variable does it
			ss_ rest = extra;
			while(!rest.empty()){
				size_t colon = rest.find(':');
				ss_ one = colon == ss_::npos ? rest : rest.substr(0, colon);
				add(one, "LUANTI_EXTRA_IMPORT_PATH");
				rest = colon == ss_::npos ? "" : rest.substr(colon + 1);
			}
		}
		const char *home = getenv("HOME");
		if(home && home[0]){
			// Luanti's user directory was renamed in 5.10 and a machine can
			// have either, or both
			add(ss_(home)+"/.luanti", "$HOME");
			add(ss_(home)+"/.minetest", "$HOME");
		}
		// The two variables are one word apart in meaning and that is the
		// trap: BUILDAT_LUANTI_IMPORT names one world to import at startup,
		// and a tree with worlds/ in it is somebody who meant the search
		// path
		const char *old_import = getenv("BUILDAT_LUANTI_IMPORT");
		if(old_import && old_import[0] &&
				interface::fs::path_exists(ss_(old_import)+"/worlds")){
			log_w(MODULE, "import: BUILDAT_LUANTI_IMPORT=%s has a worlds/ in "
					"it, so it names a Luanti installation rather than one "
					"world. The search path the import menu reads is "
					"LUANTI_EXTRA_IMPORT_PATH.", old_import);
		}
		return out;
	}

	// game.conf's name, which is the title to show; the directory's name is
	// the gameid and is what the game is installed as
	static ss_ read_game_title(const ss_ &game_path)
	{
		std::ifstream f(game_path+"/game.conf");
		if(!f.good())
			return "";
		ss_ line;
		while(std::getline(f, line)){
			size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			ss_ value = line.substr(eq + 1);
			auto trim = [](ss_ &s){
				while(!s.empty() && isspace((unsigned char)s.front()))
					s.erase(s.begin());
				while(!s.empty() && isspace((unsigned char)s.back()))
					s.pop_back();
			};
			trim(key);
			trim(value);
			if(key == "name" || key == "title")
				return value;
		}
		return "";
	}

	// A game to import, found by its id. The first root that has one wins,
	// which is the order import_roots() is in. Empty when there is none --
	// the client names what it wants and the server finds it again, because
	// a path that arrives over the network is not a path to copy.
	ss_ find_importable_game(const ss_ &gameid)
	{
		if(gameid.empty() || gameid.find('/') != ss_::npos ||
				gameid.find("..") != ss_::npos)
			return "";
		for(const ss_ &root : import_roots()){
			ss_ path = root+"/games/"+gameid;
			if(interface::fs::path_exists(path+"/game.conf"))
				return path;
		}
		return "";
	}

	// And a world, the same way
	ss_ find_importable_world(const ss_ &name)
	{
		if(name.empty() || name.find('/') != ss_::npos ||
				name.find("..") != ss_::npos)
			return "";
		for(const ss_ &root : import_roots()){
			ss_ path = root+"/worlds/"+name;
			if(interface::fs::path_exists(path+"/world.mt"))
				return path;
		}
		return "";
	}

	// What is out there to import, as one flat array: the games first with a
	// count, then the worlds. A game is its id, its title, whether it is
	// installed already and how big it is; a world is its name, the game it
	// wants, whether that game is installed and how big it is.
	//
	// The size is there because buildat's own game menu shows one and
	// because it is what says whether a copy is a moment or a minute. The
	// whole search path is walked for it, which was measured at a third of a
	// second over two hundred and fifty directories.
	void on_get_imports(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> games;
		sv_<ss_> worlds;
		sv_<ss_> installed = list_games();
		auto is_installed = [&](const ss_ &gameid){
			for(const ss_ &id : installed){
				if(id == gameid)
					return true;
			}
			return false;
		};
		sv_<ss_> seen_games, seen_worlds;
		auto seen = [](sv_<ss_> &list, const ss_ &name){
			for(const ss_ &had : list){
				if(had == name)
					return true;
			}
			list.push_back(name);
			return false;
		};
		const sv_<ss_> roots = import_roots();
		for(const ss_ &root : roots){
			for(const interface::fs::Node &n :
					interface::fs::list_directory(root+"/games")){
				if(!n.is_directory || n.name == "." || n.name == "..")
					continue;
				ss_ path = root+"/games/"+n.name;
				if(!interface::fs::path_exists(path+"/game.conf"))
					continue;
				// The first root that has a game is the one that would be
				// copied, so a later one is not offered twice
				if(seen(seen_games, n.name))
					continue;
				games.push_back(n.name);
				games.push_back(read_game_title(path));
				games.push_back(is_installed(n.name) ? "installed" : "");
				games.push_back(itos(
						interface::fs::directory_tree_size(path)));
			}
			for(const interface::fs::Node &n :
					interface::fs::list_directory(root+"/worlds")){
				if(!n.is_directory || n.name == "." || n.name == "..")
					continue;
				ss_ path = root+"/worlds/"+n.name;
				ss_ gameid = read_gameid(path);
				if(gameid.empty())
					continue;
				if(seen(seen_worlds, n.name))
					continue;
				worlds.push_back(n.name);
				worlds.push_back(gameid);
				worlds.push_back(is_installed(gameid) ? "installed" : "");
				worlds.push_back(itos(
						interface::fs::directory_tree_size(path)));
			}
		}
		// One line a user can read: "0 games and 0 worlds from 2 roots" says
		// in one go that it is the path and not the feature
		log_i(MODULE, "import: %zu games and %zu worlds from %zu roots",
				games.size() / 4, worlds.size() / 4, roots.size());
		sv_<ss_> flat;
		flat.push_back(itos(games.size() / 4));
		for(const ss_ &v : games)
			flat.push_back(v);
		for(const ss_ &v : worlds)
			flat.push_back(v);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "main:imports", os.str());
		});
	}

	// One line to whoever is waiting, which is the same channel the mod
	// loading uses; see start_world()
	void send_progress(network::PeerInfo::Id peer, const ss_ &line)
	{
		if(peer == 0)
			return;
		sv_<ss_> values{line};
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		const ss_ data = os.str();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "main:progress", data);
		});
	}

	// Everything under from into to, saying how far along it is every so
	// often. Returns false on the first file it cannot write, because half a
	// game installed is worse than none.
	bool copy_tree(const ss_ &from, const ss_ &to, size_t &done, size_t total,
			network::PeerInfo::Id peer, ss_ &error)
	{
		if(!interface::fs::create_directories(to)){
			error = "cannot make "+to;
			return false;
		}
		for(const interface::fs::Node &n :
				interface::fs::list_directory(from)){
			if(n.name == "." || n.name == "..")
				continue;
			const ss_ src = from+"/"+n.name;
			const ss_ dst = to+"/"+n.name;
			if(n.is_directory){
				if(!copy_tree(src, dst, done, total, peer, error))
					return false;
				continue;
			}
			if(!interface::fs::copy_file(src, dst)){
				error = "cannot copy "+src;
				return false;
			}
			done++;
			// Not every file: a game is thousands of them and a line per
			// file is more work than the copying
			if(done % 200 == 0 || done == total){
				send_progress(peer, "Copying: "+itos(done)+"/"+itos(total)+
						" files");
			}
		}
		return true;
	}

	static size_t count_files(const ss_ &path)
	{
		size_t n = 0;
		for(const interface::fs::Node &node :
				interface::fs::list_directory(path)){
			if(node.name == "." || node.name == "..")
				continue;
			if(node.is_directory)
				n += count_files(path+"/"+node.name);
			else
				n++;
		}
		return n;
	}

	// A game is copied into buildat's own games directory, and **refuses to
	// overwrite one that is there**: removing an installed game is the
	// user's own business outside buildat. Copying over the top would leave
	// a file the game deleted upstream behind forever, and deleting first is
	// a recursive delete under user/ driven by a menu.
	void on_import_game(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:import_game: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		const ss_ gameid = values[0];
		const ss_ from = find_importable_game(gameid);
		if(from.empty()){
			menu_error(packet.sender, "There is no game called "+gameid+
					" to import");
			return;
		}
		const ss_ to = luanti_path()+"/games/"+gameid;
		if(interface::fs::path_exists(to)){
			menu_error(packet.sender, gameid+" is already installed. Remove "+
					to+" yourself if you mean to replace it.");
			return;
		}
		log_i(MODULE, "Importing game %s from %s", cs(gameid), cs(from));
		send_progress(packet.sender, "Copying "+gameid+"...");
		const size_t total = count_files(from);
		size_t done = 0;
		ss_ error;
		// Into a directory of its own beside the destination first, so that
		// a copy that fails half way does not look like an installed game
		const ss_ partial = to+".importing";
		if(!copy_tree(from, partial, done, total, packet.sender, error)){
			menu_error(packet.sender, "Importing "+gameid+" failed: "+error);
			return;
		}
		if(rename(partial.c_str(), to.c_str()) != 0){
			menu_error(packet.sender, "Importing "+gameid+" failed: cannot "
					"rename "+partial);
			return;
		}
		log_i(MODULE, "Imported game %s: %zu files", cs(gameid), done);
		menu_message(packet.sender, gameid+" imported: "+itos(done)+" files");
	}

	// A world is not copied: it becomes a save, through the importer that
	// BUILDAT_LUANTI_IMPORT already drives. What the button adds is the
	// picking and the name.
	void on_import_world(const network::Packet &packet)
	{
		if(!local_only(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:import_world: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		const ss_ world_name = values[0];
		const ss_ save_name = values[1];
		const ss_ from = find_importable_world(world_name);
		if(from.empty()){
			menu_error(packet.sender, "There is no world called "+world_name+
					" to import");
			return;
		}
		const ss_ gameid = read_gameid(from);
		if(find_game(gameid).empty()){
			menu_error(packet.sender, world_name+" wants the game "+gameid+
					", which is not installed. Import that first.");
			return;
		}
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(save_name);
		});
		if(!valid){
			menu_error(packet.sender, "\""+save_name+"\" is not a name a "
					"save can have");
			return;
		}
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->create(save_name);
			if(save){
				save->store("main")->set("gameid", gameid);
				istorage->close(save);
			}
		});
		if(!save){
			menu_error(packet.sender, "There is already a save called "+
					save_name);
			return;
		}
		log_i(MODULE, "Importing world %s from %s into save %s",
				cs(world_name), cs(from), cs(save_name));
		start_world(gameid, save_name, packet.sender, from);
	}

	// Opening one that is there, and making one that is not. Split on
	// purpose: a typo in a name cannot silently start a new game instead of
	// opening the old one.
	void on_open(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:open: %s", e.what());
			return;
		}
		if(values.empty())
			return;
		ss_ name = values[0];
		if(!is_world_name(name))
			return;
		ss_ gameid = gameid_of_save(name);
		if(gameid == ""){
			menu_error(packet.sender, "The save "+name+" does not say which"
					" game it needs");
			return;
		}
		if(m_public && m_starting){
			if(name == m_world_name)
				return menu_message(packet.sender, name+" is running already");
			return switch_world(name, packet.sender);
		}
		start_world(gameid, name, packet.sender);
	}

	// The mapgens Luanti ships. A world's mg_name comes from the menu, so
	// it is checked against this before it is written into world.mt
	// ([NEW_WORLD_FORM]).
	static bool is_mapgen_name(const ss_ &name)
	{
		for(const char *n : {"v7", "v5", "valleys", "carpathian", "flat",
				"fractal", "v6", "singlenode"}){
			if(name == n)
				return true;
		}
		return false;
	}

	void on_create(const network::Packet &packet)
	{
		if(!may_manage(packet.sender))
			return;
		sv_<ss_> values;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(values);
		} catch(std::exception &e){
			log_w(MODULE, "main:create: %s", e.what());
			return;
		}
		if(values.size() < 2)
			return;
		ss_ name = values[0], gameid = values[1];
		bool valid = is_world_name(name);
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = valid && istorage->valid_name(name);
		});
		if(!valid){
			menu_error(packet.sender, "\""+name+"\" is not a name a save can"
					" have");
			return;
		}
		if(find_game(gameid).empty()){
			menu_error(packet.sender, "There is no game called "+gameid);
			return;
		}
		// A third value is the seed the menu was given, or empty for a
		// random one: Luanti's own fixed_map_seed, written into the world's
		// world.mt where the module reads it when the world is made
		const ss_ seed = values.size() > 2 ? values[2] : "";
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->create(name);
			if(save){
				save->store("main")->set("gameid", gameid);
				save->store("main")->set("created", itos((int64_t)time(NULL)));
				if(!seed.empty()){
					const ss_ dir = save->path()+"/luanti";
					interface::fs::create_directories(dir);
					std::ofstream f(dir+"/world.mt", std::ios::app);
					f<<"fixed_map_seed = "<<seed<<"\n";
				}
				// The fourth and fifth are the new world's Creative mode
				// and Enable damage ([WORLD_LIST]); official's defaults
				// when absent
				if(values.size() > 4){
					std::map<ss_, ss_> set;
					set["creative_mode"] = values[3] == "true" ? "true" : "false";
					set["enable_damage"] = values[4] == "true" ? "true" : "false";
					// The sixth is which mapgen the world is made with
					// ([NEW_WORLD_FORM]), written before the first load
					// because a world is made with one mapgen once. Only
					// a name out of the list the menu offers, because
					// this goes into the world's own settings file.
					if(values.size() > 5 && is_mapgen_name(values[5]))
						set["mg_name"] = values[5];
					write_world_mt(save->path()+"/luanti/world.mt", set);
				}
				istorage->close(save);
			}
		});
		if(!save){
			menu_error(packet.sender, "There is already a save called "+name);
			return;
		}
		// While a world runs, one world at a time: made, and run by
		// switching to it
		if(m_public && m_starting){
			menu_message(packet.sender, "The world "+name+" was made: run it "
					"to switch to it");
			return;
		}
		start_world(gameid, name, packet.sender);
	}

	// The same dialog for something that went right, which is not a warning
	// in the log and is otherwise the same thing
	// A message is news -- a game installed, a world imported -- shown
	// over the list it changed; an error is a dialog the user has to
	// close ([FIRST_RUN]: a driven run fails on any dialog, so news is
	// not one)
	void menu_message(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_i(MODULE, "%s", cs(message));
		send_menu_message(peer, message, "main:menu_message");
	}

	void menu_error(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_w(MODULE, "%s", cs(message));
		send_menu_message(peer, message, "main:menu_error");
	}

	void send_menu_message(network::PeerInfo::Id peer, const ss_ &message,
			const ss_ &packet = "main:menu_error")
	{
		if(peer == 0)
			return;
		sv_<ss_> values;
		values.push_back(message);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(values);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, packet, os.str());
		});
	}

	void show_world_to(network::PeerInfo::Id peer)
	{
		// Once per peer: files_transmitted comes again after every batch
		// of files announced (the game's media, once the world is up),
		// and a second showing initialised the peer's world twice
		// ("on_ready(): already ready", [FIRST_RUN])
		if(!m_shown_world.insert(peer).second)
			return;
		network::access(m_server, [&](network::Interface *inetwork){
			// The menu takes itself away first: it is a script of its own
			// and has no other way of knowing that it is done with
			inetwork->send(peer, "main:menu_done", "");
			inetwork->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		// The player before the scene: the placement goes out ordered
		// behind the script that subscribes to it ([PLAYER_POS_RACE]), and
		// the scene brings voxelworld's registry, megabytes that over a
		// slow link held the placement -- and the client's input -- for
		// minutes ([NET_SIM]'s link cell)
		const bool admin = m_public && is_admin(peer);
		send_account(peer);
		luanti::access(m_server, [&](luanti::Interface *i){
			i->add_player(player_name_of(peer), peer);
			if(admin)
				i->set_admin(player_name_of(peer), true);
		});
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_scene, peer);
		});
	}

	// Under the user path, not the cache: a Luanti game the user installed
	// and a world they have played are things they chose, and the cache is
	// what the program can recreate by itself. See
	// doc/plan/world_persistence_plan.md.
	ss_ luanti_path()
	{
		return m_server->get_config().get<ss_>("user_path")+"/luanti";
	}

	// world.mt's gameid, or "" for a directory that has no world.mt
	static ss_ read_gameid(const ss_ &world_path)
	{
		std::ifstream f(world_path+"/world.mt");
		if(!f.good())
			return "";
		ss_ line;
		while(std::getline(f, line)){
			size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			ss_ value = line.substr(eq + 1);
			auto trim = [](ss_ &s){
				while(!s.empty() && isspace((unsigned char)s.front()))
					s.erase(s.begin());
				while(!s.empty() && isspace((unsigned char)s.back()))
					s.pop_back();
			};
			trim(key);
			trim(value);
			if(key == "gameid")
				return value;
		}
		return "";
	}

	sv_<World> list_worlds()
	{
		sv_<World> worlds;
		ss_ dir = luanti_path()+"/worlds";
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			World w;
			w.name = n.name;
			w.path = dir+"/"+n.name;
			w.gameid = read_gameid(w.path);
			if(w.gameid == ""){
				log_w(MODULE, "%s has no world.mt; skipping", cs(w.path));
				continue;
			}
			worlds.push_back(w);
		}
		return worlds;
	}

	// buildat ships one Luanti game of its own, so that the module can be run
	// and looked at without a Luanti installation. It is also what the visual
	// check uses, since a fixture somebody has to install is a fixture that
	// is different on every machine.
	ss_ bundled_game_path()
	{
		return m_server->get_module_path("luanti")+"/minimal_game";
	}

	ss_ find_game(const ss_ &gameid)
	{
		ss_ path = luanti_path()+"/games/"+gameid;
		if(interface::fs::path_exists(path+"/game.conf"))
			return path;
		if(gameid == "minimal"){
			path = bundled_game_path();
			if(interface::fs::path_exists(path+"/game.conf"))
				return path;
		}
		return "";
	}

	// Without one of these the game waits for a menu choice; with one it
	// runs what the environment says, which is what every check here does.
	void on_start()
	{
		m_public = launch_param("launcher") != "1";
		if(m_public)
			log_i(MODULE, "A public server: clients join by account, and the "
					"worlds are the admins'");
		// BUILDAT_LUANTI_FETCH_ONCE: one ContentDB listing at start, its
		// outcome logged and sent to nobody -- the smoke's way of running
		// http_get, whose std::call_once died on the box through a
		// winpthreads linked into Urho3D.dll ([WIN8_START] 16); a fetch
		// that errors is a fetch that ran
		if(getenv("BUILDAT_LUANTI_FETCH_ONCE")){
			Job *job = new Job();
			job->kind = Job::LIST;
			job->peer = 0;
			job->q = "";
			start_job(job);
			log_i(MODULE, "contentdb: fetching once, for the log");
		}
		// The game was games/luanti_launcher until 2026-09-20 and its saves
		// lived under that name: moved to this one on the first start
		// that finds the new directory absent, so nobody loses a world
		// ([LAUNCH_GRID]'s rename checklist)
		{
			const ss_ games = m_server->get_config().get<ss_>("user_path")+
					"/games";
			const ss_ old_dir = games+"/luanti_launcher";
			const ss_ new_dir = games+"/vanilla";
			if(interface::fs::path_exists(old_dir) &&
					!interface::fs::path_exists(new_dir)){
				if(rename(old_dir.c_str(), new_dir.c_str()) == 0)
					log_i(MODULE, "Moved %s to %s", cs(old_dir), cs(new_dir));
				else
					log_w(MODULE, "Could not move %s to %s", cs(old_dir),
							cs(new_dir));
			}
		}
		// What this game does about a client that stops reading. Luanti's
		// own answer: a window of what may be in flight, and a timeout that
		// disconnects rather than a queue that grows without bound -- a
		// client that has been given eight megabytes and has read none of
		// it for half a minute is gone, not waited for. See SendPolicy in
		// builtin/network/api.h, and the master plan's "And the bottom of
		// it is a blocking socket write" for why this is a choice at all.
		//
		// Eight megabytes because one client taking a VoxeLibre world moves
		// about that much in its first seconds, so the window is "a world's
		// worth behind" rather than a number that a healthy client trips.
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->set_send_policy(network::SendPolicy::Disconnect,
					8 * 1024 * 1024, 30000000);
			// **The menus' answers go ahead of the world** ([NET_CHANNELS];
			// user, 2026-09-30: "Looking for saves..." counted past 100 s in
			// the world menu, behind the world streaming to a slow link).
			// Each answer is the whole of what it says, so a newer one
			// replacing an unsent one loses nothing, and they keep their
			// order among themselves (main:menu before main:saves). Only
			// answers to a script's own request: main:account and
			// main:join_title follow the run_script that starts their
			// reader, and ahead of it they would find nobody.
			for(const char *name : {"main:menu", "main:saves", "main:save_info",
					"main:imports", "main:settings", "main:progress",
					"main:contentdb_list", "main:menu_message",
					"main:menu_error"})
				inetwork->declare(name,
						network::Interface::Channel::LatestOnly);
		});

		ss_ gameid;
		ss_ world_name;

		// A game by name: what the visual check runs, and what anyone wanting
		// the bundled game wants.
		const char *wanted_game = getenv("BUILDAT_LUANTI_GAME");
		const char *wanted_world = getenv("BUILDAT_LUANTI_WORLD");
		// Or what an untrusted launcher asked for, through the server's
		// -u ([LAUNCH_GRID]): read as a packet would be -- the one key this
		// takes, a game name of the shape a directory name has, and the
		// rest ignored. The environment, the shell's and the runners', wins.
		ss_ launched_game = launch_param("luanti_game");
		// menu=worlds with a game: the save list of that game rather than
		// its one implicit world -- the Luanti tile's world selection
		// ([LAUNCH_GRID]). The game goes to the client with the menu.
		if(launch_param("menu") == "worlds")
			launched_game = "";
		if(!(wanted_game && wanted_game[0]) && !launched_game.empty())
			wanted_game = launched_game.c_str();
		if(m_public && !read_public_world().empty() &&
				!gameid_of_save(read_public_world()).empty()){
			// The world an admin chose ([VANILLA_PUBLIC] 5), over the
			// environment, which is then the first boot's
			world_name = read_public_world();
			gameid = gameid_of_save(world_name);
		} else if(wanted_game && wanted_game[0]){
			gameid = wanted_game;
			// The save is named after the game unless something says
			// otherwise, which is what running two imports of the same game
			// into two saves needs.
			const char *wanted_save = getenv("BUILDAT_LUANTI_SAVE");
			world_name = (wanted_save && wanted_save[0]) ? wanted_save :
					gameid+"_world";
		} else if(wanted_world && wanted_world[0]){
			// A Luanti world directory, read for the one thing it knows that
			// nothing else does -- which game it wants. What is run is a
			// buildat save of the same name.
			for(const World &w : list_worlds()){
				if(w.name == wanted_world){
					gameid = w.gameid;
					world_name = w.name;
				}
			}
			if(gameid == ""){
				m_server->shutdown(1, ss_()+"No world called "+wanted_world);
				return;
			}
		} else {
			// Whoever connects picks; see on_get_saves(). On a public
			// server that is an admin.
			log_i(MODULE, "Waiting for a save to be chosen");
			return;
		}
		start_world(gameid, world_name, 0);
	}

	// Runs the game in the save, or says why it cannot. peer is who asked,
	// for the saying; zero is nobody, and then a failure is fatal because
	// nothing was there to ask.
	// automatic is a launch nobody clicked: it logs where a user's own
	// second click would be told, so a fault of this shape does not reach
	// the client as a dialog over a world that is loading fine
	void start_world(const ss_ &gameid, const ss_ &world_name,
			network::PeerInfo::Id peer, const ss_ &import_world_from = "",
			bool automatic = false)
	{
		if(m_starting){
			if(automatic)
				log_i(MODULE, "start_world: %s is already starting",
						cs(world_name));
			else
				menu_error(peer, "A world is already starting");
			return;
		}
		ss_ game_path = find_game(gameid);
		if(game_path.empty()){
			ss_ message = "World "+world_name+" wants game "+gameid+
					", which is not in "+where(luanti_path()+"/games");
			// A public server waits for an admin rather than exiting,
			// which its runner would take as a crash to restart
			if(peer == 0 && m_public){
				log_e(MODULE, "%s; waiting for an admin", cs(message));
				return;
			}
			if(peer == 0){
				m_server->shutdown(1, message);
				return;
			}
			menu_error(peer, message);
			return;
		}
		m_starting = true;
		m_world_name = world_name;
		if(m_public)
			write_public_world(world_name);

		// The world runs in a buildat save and never in a Luanti world
		// directory. Nothing here writes to user/luanti at any point: a
		// Luanti world is read, or imported, and that is all. It has to be
		// this way round rather than by being careful, because the writes do
		// not come from here -- devtest's testnodes mod writes a PNG through
		// core.get_worldpath() while it loads.
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->open(world_name);
			if(!save){
				save = istorage->create(world_name);
				// BUILDAT_LUANTI_SEED: a new save's seed, the way the
				// menu's third value is, so a scripted run on both engines
				// is of one world
				const char *seed = getenv("BUILDAT_LUANTI_SEED");
				if(save && seed && seed[0]){
					const ss_ dir = save->path()+"/luanti";
					interface::fs::create_directories(dir);
					std::ofstream f(dir+"/world.mt", std::ios::app);
					f<<"fixed_map_seed = "<<seed<<"\n";
				}
			}
		});
		if(!save){
			ss_ message = "Could not open or create the save "+world_name;
			m_starting = false;
			if(peer == 0){
				m_server->shutdown(1, message);
				return;
			}
			menu_error(peer, message);
			return;
		}
		// Which game a save needs is the save's to remember, so that the
		// menu can say it without opening the game
		save->store("main")->set("gameid", gameid);
		log_i(MODULE, "Running world %s (game %s) in %s",
				cs(world_name), cs(gameid), cs(save->path()));
		// A file of Lua into the game's environment, before its mods load.
		// What this is for is a game of one's own on top of a Luanti game
		// -- which is what load_lua() is in the module's interface for --
		// and, while there is no such game here, for looking into one that
		// misbehaves.
		const char *extra_lua = getenv("BUILDAT_LUANTI_LUA");
		if(extra_lua && extra_lua[0]){
			std::ifstream ifs(extra_lua, std::ios::binary);
			if(!ifs.good()){
				m_server->shutdown(1, ss_()+"Cannot read "+extra_lua);
				return;
			}
			std::ostringstream os;
			os<<ifs.rdbuf();
			log_i(MODULE, "Loading %s into the Luanti environment",
					extra_lua);
			luanti::access(m_server, [&](luanti::Interface *i){
				i->load_lua(os.str(), extra_lua);
			});
		}

		// A Luanti world's own map, read into the save once. The world
		// directory is opened read-only; what it says about which game it
		// wants is what chose the game above.
		// The menu's import names one; BUILDAT_LUANTI_IMPORT is the other
		// way in and is what every check here uses
		const char *env_import = getenv("BUILDAT_LUANTI_IMPORT");
		const ss_ import_from = !import_world_from.empty() ?
				import_world_from :
				ss_(env_import && env_import[0] ? env_import : "");
		luanti::access(m_server, [&](luanti::Interface *i){
			// What the server is doing, to whoever is waiting for the world:
			// a game of 220 mods takes minutes, and "Creating <name>..."
			// left on the screen for that long looks hung. The handler runs
			// on this thread from inside run_game(), and a packet sent from
			// it reaches the client because network::send() writes to the
			// socket there and then.
			i->set_progress_handler([this, peer](const ss_ &line){
				if(peer == 0)
					return;
				sv_<ss_> values{line};
				std::ostringstream os(std::ios::binary);
				{
					cereal::PortableBinaryOutputArchive ar(os);
					ar(values);
				}
				const ss_ data = os.str();
				network::access(m_server, [&](network::Interface *inetwork){
					inetwork->send(peer, "main:progress", data);
				});
			});
			// What the world is made out of goes in before it is made, and
			// so does the world itself: the map is read from inside
			// run_game(), between the game's nodes being registered and
			// the first section being asked for
			if(!import_from.empty()){
				i->import_world_settings(import_from, save);
				i->import_world(import_from);
			}
			// No singleplayer: its privileges are everyone's
			// ([VANILLA_PUBLIC] 3)
			if(m_public)
				i->load_lua("core.__public = true", "vanilla_public");
			i->run_game(game_path, save);
		});
	}
};

// BUILDAT_CONTENTDB_URL: a mirror in a test ([FIRST_RUN]: a directory
// served by python3 -m http.server, made by util/contentdb_mirror.sh),
// since the real one over the network in a daily run is a flake
const char *Module::CONTENTDB = getenv("BUILDAT_CONTENTDB_URL") ?
		getenv("BUILDAT_CONTENTDB_URL") : "https://content.luanti.org";

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
