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
	// A world runs once: what a second choice would be is a second Luanti
	// environment in one server, which is not what the module is
	bool m_starting = false;

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:dig"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:place"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:get_saves"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:open"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:create"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/main:where"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/main:dig", on_dig,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:place", on_place,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:get_saves", on_get_saves,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:open", on_open,
				network::Packet)
		EVENT_TYPEN("network:packet_received/main:create", on_create,
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

	// Where the client's camera is, which is where its player is. It sends
	// this a few times a second; nothing here moves a player otherwise.
	void on_where(const network::Packet &packet)
	{
		double x = 0, y = 0, z = 0, look_h = 0, look_v = 0;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(x, y, z, look_h, look_v);
		} catch(std::exception &e){
			log_w(MODULE, "main:where: %s", e.what());
			return;
		}
		luanti::access(m_server, [&](luanti::Interface *i){
			i->set_player_pos(player_name_of(packet.sender),
					(float)x, (float)y, (float)z,
					(float)look_h, (float)look_v);
		});
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

	void menu_error(network::PeerInfo::Id peer, const ss_ &message)
	{
		log_w(MODULE, "%s", cs(message));
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
			network::PeerInfo::Id peer)
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
		const char *import_from = getenv("BUILDAT_LUANTI_IMPORT");
		luanti::access(m_server, [&](luanti::Interface *i){
			i->run_game(game_path, save);
			if(import_from && import_from[0])
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
