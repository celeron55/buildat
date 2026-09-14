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
#include <sstream>
#include <algorithm>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
#include "interface/polyvox_cereal.h"
#include <PolyVoxCore/Vector.h>
#define MODULE "main"

using interface::Event;

namespace pv = PolyVox;

#define PV3I_FORMAT "(%i, %i, %i)"
#define PV3I_PARAMS(p) p.getX(), p.getY(), p.getZ()

namespace luanti_launcher {

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
	// Where each client last said its player is, applied on the next tick;
	// see on_where()
	struct Where { double x = 0, y = 0, z = 0, look_h = 0, look_v = 0; };
	sm_<network::PeerInfo::Id, Where> m_pending_where;
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
				"network:packet_received/main:import_game"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:import_world"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:where"));
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
		EVENT_TYPEN("network:packet_received/main:where", on_where,
				network::Packet)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
	}

	// A Luanti player per client. The name is this game's to choose and the
	// client does not send one, so it is the peer's number: what it is for
	// is to be the key everything about the player hangs off, and a mod
	// that prints it gets something it can tell apart.
	static ss_ player_name_of(network::PeerInfo::Id peer)
	{
		return "client"+itos(peer);
	}

	void on_client_disconnected(const network::OldClient &old_client)
	{
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
			ar(w.x, w.y, w.z, w.look_h, w.look_v);
		} catch(std::exception &e){
			log_w(MODULE, "main:where: %s", e.what());
			return;
		}
		m_pending_where[packet.sender] = w;
	}

	// And the tick is where they are handed over: one visit to the module
	// for every player who has moved since the last one -- and not on every
	// tick, the server's being thirty a second, but at the rate a client
	// sends at. One visit per fifth of a second for the lot of them is what
	// this is for; thirty would be worse than what it replaced.
	void on_tick(const interface::TickEvent &event)
	{
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
						(float)pair.second.look_v);
			}
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

	// The two lists the menu is: every save this game has, with the Luanti
	// game each one says it needs, and every Luanti game there is to choose
	// from. Flat, with the number of saves leading, because that is what one
	// array of strings can carry.
	void on_get_saves(const network::Packet &packet)
	{
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
	sv_<ss_> import_roots()
	{
		sv_<ss_> out;
		auto add = [&](const ss_ &path){
			if(path.empty() || !interface::fs::path_exists(path))
				return;
			for(const ss_ &had : out){
				if(had == path)
					return;
			}
			out.push_back(path);
		};
		const char *extra = getenv("LUANTI_EXTRA_IMPORT_PATH");
		if(extra && extra[0]){
			// Several, separated the way every other path variable does it
			ss_ rest = extra;
			while(!rest.empty()){
				size_t colon = rest.find(':');
				ss_ one = colon == ss_::npos ? rest : rest.substr(0, colon);
				add(one);
				rest = colon == ss_::npos ? "" : rest.substr(colon + 1);
			}
		}
		const char *home = getenv("HOME");
		if(home && home[0]){
			// Luanti's user directory was renamed in 5.10 and a machine can
			// have either, or both
			add(ss_(home)+"/.luanti");
			add(ss_(home)+"/.minetest");
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
		for(const ss_ &root : import_roots()){
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
		storage::Save *save = nullptr;
		storage::access(m_server, [&](storage::Interface *istorage){
			save = istorage->create(name);
			if(save){
				save->store("main")->set("gameid", gameid);
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
	void menu_message(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_i(MODULE, "%s", cs(message));
		send_menu_message(peer, message);
	}

	void menu_error(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_w(MODULE, "%s", cs(message));
		send_menu_message(peer, message);
	}

	void send_menu_message(network::PeerInfo::Id peer, const ss_ &message)
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
			inetwork->send(peer, "main:menu_error", os.str());
		});
	}

	void show_world_to(network::PeerInfo::Id peer)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_scene, peer);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			// The menu takes itself away first: it is a script of its own
			// and has no other way of knowing that it is done with
			inetwork->send(peer, "main:menu_done", "");
			inetwork->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
		});
		luanti::access(m_server, [&](luanti::Interface *i){
			i->add_player(player_name_of(peer), peer);
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
		ss_ gameid;
		ss_ world_name;

		// A game by name: what the visual check runs, and what anyone wanting
		// the bundled game wants.
		const char *wanted_game = getenv("BUILDAT_LUANTI_GAME");
		const char *wanted_world = getenv("BUILDAT_LUANTI_WORLD");
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
			if(!save)
				save = istorage->create(world_name);
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
			// What the world is made out of goes in before it is made; the
			// rest of it is read once the game's nodes are registered
			if(!import_from.empty())
				i->import_world_settings(import_from, save);
			i->run_game(game_path, save);
			if(!import_from.empty())
				i->import_world(import_from);
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
