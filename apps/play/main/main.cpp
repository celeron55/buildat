// [PLAY_PAGE] play.buildat.org: a server that serves the web client and
// has no game of its own. The page starts on the launch menu, which joins
// any server in place, so the client code is from this one origin
// ([WEB_ID_TRUST] (d)). Served from util/web_play_dir.sh's directory:
//   util/web_play_dir.sh /srv/play
//   buildat_server -m apps/play -W /srv/play
// behind a TLS proxy, and the origin in each Starport's web_clients.
#include "interface/module.h"
#include "interface/server.h"
#define MODULE "main"

namespace play {

struct Module: public interface::Module
{
	Module(interface::Server *server):
		interface::Module(MODULE)
	{}

	void init()
	{}

	void event(const interface::Event::Type &type,
			const interface::Event::Private *p)
	{}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
