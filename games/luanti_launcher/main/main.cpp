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
#define MODULE "main"

using interface::Event;

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

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("luanti:game_loaded"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("luanti:game_loaded", on_game_loaded, luanti::GameLoaded)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
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
			return;
		}
		show_world_to(event.recipient);
	}

	void show_world_to(network::PeerInfo::Id peer)
	{
		replicate::access(m_server, [&](replicate::Interface *ireplicate){
			ireplicate->assign_scene_to_peer(m_scene, peer);
		});
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:run_script",
					"buildat.run_script_file(\"main/init.lua\")");
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

	void on_start()
	{
		ss_ gameid;
		ss_ world_name;

		// A game by name: what the visual check runs, and what anyone wanting
		// the bundled game wants.
		const char *wanted_game = getenv("BUILDAT_LUANTI_GAME");
		if(wanted_game && wanted_game[0]){
			gameid = wanted_game;
			// Which save and which game it needs are two facts, and the
			// menu M6 is about is where they stop pretending to be one.
			// Until then the save is named after the game unless something
			// says otherwise, which is what running two imports of the same
			// game into two saves needs.
			const char *wanted_save = getenv("BUILDAT_LUANTI_SAVE");
			world_name = (wanted_save && wanted_save[0]) ? wanted_save :
					gameid+"_world";
		} else {
			sv_<World> worlds = list_worlds();
			if(worlds.empty()){
				m_server->shutdown(1, "No worlds in "+luanti_path()+"/worlds;"
						" try BUILDAT_LUANTI_GAME=minimal");
				return;
			}
			const char *wanted = getenv("BUILDAT_LUANTI_WORLD");
			const World *chosen = &worlds[0];
			if(wanted){
				chosen = nullptr;
				for(const World &w : worlds){
					if(w.name == wanted)
						chosen = &w;
				}
				if(!chosen){
					m_server->shutdown(1, ss_()+"No world called "+wanted);
					return;
				}
			}
			// The Luanti world is read for the one thing it knows that
			// nothing else does -- which game it wants -- and for nothing
			// else. What is run is a buildat save of the same name; when
			// the importer exists (M7) it is what fills that save from this
			// directory's map.sqlite.
			gameid = chosen->gameid;
			world_name = chosen->name;
		}

		ss_ game_path = find_game(gameid);
		if(game_path.empty()){
			m_server->shutdown(1, "World "+world_name+" wants game "+gameid+
					", which is not in "+luanti_path()+"/games");
			return;
		}

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
			m_server->shutdown(1, "Could not open or create the save "+
					world_name);
			return;
		}
		log_i(MODULE, "Running world %s (game %s) in %s",
				cs(world_name), cs(gameid), cs(save->path()));
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
