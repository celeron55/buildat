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
#include <cstdlib>
#include <fstream>
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
		if(!m_scene)
			return;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->remove_player(player_name_of(old_client.info.id));
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
		luanti::access(m_server, [&](luanti::Interface *i){
			i->chat_message(player_name_of(packet.sender), message);
		});
	}

	// Which hotbar slot the player is holding. The keys and the wheel are
	// the client's, and what is in hand is what the next dig or place asks
	// the module about.
	void on_wield(const network::Packet &packet)
	{
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
		if(!m_scene){
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
		sv_<ss_> flat;
		sv_<ss_> saves;
		storage::access(m_server, [&](storage::Interface *istorage){
			sv_<storage::SaveInfo> infos = istorage->list();
			// The one played last is the one most likely wanted next
			std::sort(infos.begin(), infos.end(),
					[](const storage::SaveInfo &a, const storage::SaveInfo &b){
				return a.modified_us > b.modified_us;
			});
			for(const storage::SaveInfo &info : infos)
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
		return luanti_path()+"/launcher.json";
	}
	ss_ read_render_mode()
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
			if(root.get_object_key(i).as_string() == "render_mode" &&
					root.get_object_value(i).get_type() == sajson::TYPE_STRING)
				return root.get_object_value(i).as_string();
		}
		return "";
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
	void write_settings(const sv_<ss_> &paths, const ss_ &mode)
	{
		interface::fs::create_directories(luanti_path());
		std::ofstream f(settings_path(), std::ios::trunc);
		f << "{\"render_mode\": \"" << mode << "\", \"import_paths\": [";
		for(size_t i = 0; i < paths.size(); i++){
			f << (i ? ", \"" : "\"");
			for(char c : paths[i]){
				if(c == '"' || c == '\\')
					f << '\\' << c;
				else if((unsigned char)c < 0x20)
					f << ' ';
				else
					f << c;
			}
			f << "\"";
		}
		f << "]}\n";
		if(!f.good())
			log_w(MODULE, "could not write %s", cs(settings_path()));
	}
	void send_settings(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			sv_<ss_> list = read_import_paths();
			ss_ mode = read_render_mode();
			list.push_back("render_mode="+(mode.empty() ? ss_("pbr") : mode));
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
		enum Kind { LIST, INSTALL } kind;
		network::PeerInfo::Id peer;
		ss_ q; // LIST: the query; INSTALL: author/name
		ss_ name; // INSTALL: the game's directory
		ss_ zip_path, into_dir;
		ss_ result, error;
		std::atomic<uint64_t> got{0}, total{0};
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
					interface::fs::remove_all(into_dir);
					interface::zip_extract(zip_path, into_dir);
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
					to+" yourself if you mean to replace it.");
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
				if(job->kind == Job::INSTALL && job->total > 0){
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
						"rename "+from);
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
	}

	void on_get_settings(const network::Packet &packet)
	{
		send_settings(packet.sender);
	}
	// The whole list, replacing what was there: the screen adds and
	// removes, and sends the result
	void on_set_settings(const network::Packet &packet)
	{
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
		ss_ mode = "pbr";
		for(const ss_ &v : values){
			if(v.compare(0, 12, "render_mode=") == 0){
				const ss_ m = v.substr(12);
				if(m == "unlit" || m == "shadows" || m == "pbr")
					mode = m;
			} else if(!v.empty() && v.size() <= 4096)
				paths.push_back(v);
		}
		write_settings(paths, mode);
		log_i(MODULE, "settings: %zu import paths and render_mode %s "
				"written to %s", paths.size(), cs(mode), cs(settings_path()));
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
			add(path, "launcher.json");
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
		ss_ gameid = gameid_of_save(name);
		if(gameid == ""){
			menu_error(packet.sender, "The save "+name+" does not say which"
					" game it needs");
			return;
		}
		start_world(gameid, name, packet.sender);
	}

	void on_create(const network::Packet &packet)
	{
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
		bool valid = false;
		storage::access(m_server, [&](storage::Interface *istorage){
			valid = istorage->valid_name(name);
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
				if(!seed.empty()){
					const ss_ dir = save->path()+"/luanti";
					interface::fs::create_directories(dir);
					std::ofstream f(dir+"/world.mt", std::ios::app);
					f<<"fixed_map_seed = "<<seed<<"\n";
				}
				istorage->close(save);
			}
		});
		if(!save){
			menu_error(packet.sender, "There is already a save called "+name);
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
		luanti::access(m_server, [&](luanti::Interface *i){
			i->add_player(player_name_of(peer), peer);
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
		if(wanted_game && wanted_game[0]){
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
			// Whoever connects picks; see on_get_saves()
			log_i(MODULE, "Waiting for a save to be chosen");
			return;
		}
		start_world(gameid, world_name, 0);
	}

	// Runs the game in the save, or says why it cannot. peer is who asked,
	// for the saying; zero is nobody, and then a failure is fatal because
	// nothing was there to ask.
	void start_world(const ss_ &gameid, const ss_ &world_name,
			network::PeerInfo::Id peer, const ss_ &import_world_from = "")
	{
		if(m_starting){
			menu_error(peer, "A world is already starting");
			return;
		}
		ss_ game_path = find_game(gameid);
		if(game_path.empty()){
			ss_ message = "World "+world_name+" wants game "+gameid+
					", which is not in "+luanti_path()+"/games";
			if(peer == 0){
				m_server->shutdown(1, message);
				return;
			}
			menu_error(peer, message);
			return;
		}
		m_starting = true;

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
