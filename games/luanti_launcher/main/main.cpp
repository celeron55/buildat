// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Runs a Luanti world and extends nothing. Games and worlds are scanned from
// cache/luanti, which is buildat's own directory on purpose: nothing here
// reads the content of a real Luanti install, and nothing here can write to
// one.
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

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
	}

	ss_ luanti_path()
	{
		ss_ rccpp = m_server->get_config().get<ss_>("rccpp_build_path");
		return interface::fs::strip_file_name(rccpp)+"/luanti";
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

	void on_start()
	{
		sv_<World> worlds = list_worlds();
		if(worlds.empty()){
			m_server->shutdown(1, "No worlds in "+luanti_path()+"/worlds");
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
		ss_ game_path = luanti_path()+"/games/"+chosen->gameid;
		if(!interface::fs::path_exists(game_path+"/game.conf")){
			m_server->shutdown(1, "World "+chosen->name+" wants game "+
					chosen->gameid+", which is not in "+luanti_path()+"/games");
			return;
		}
		log_i(MODULE, "Running world %s (game %s)",
				cs(chosen->name), cs(chosen->gameid));
		ss_ world_path = chosen->path;
		luanti::access(m_server, [&](luanti::Interface *i){
			i->run_game(game_path, world_path);
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
