#include "core/log.h"
#include "interface/module.h"
#include "interface/module_info.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "interface/event.h"
#include "loader/api.h"

using interface::Event;

namespace __loader {

struct Module: public interface::Module
{
	interface::Server *m_server;
	ss_ m_shutdown_reason;

	Module(interface::Server *server):
		interface::Module("__loader"),
		m_server(server)
	{
		log_v(MODULE, "__loader construct");
	}

	~Module()
	{
		log_v(MODULE, "__loader destruct");
		if(m_shutdown_reason != ""){
			log_w(MODULE, "Shut down: %s", cs(m_shutdown_reason));
		}
	}

	void init()
	{
		log_v(MODULE, "__loader init");
		m_server->sub_event(this, Event::t("core:load_modules"));
		m_server->sub_event(this, Event::t("core:module_modified"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:load_modules", on_load_modules)
		EVENT_TYPEN("core:module_modified", on_module_modified,
				interface::ModuleModifiedEvent)
	}

	void on_load_modules()
	{
		interface::ModuleInfo info;
		info.name = "loader";
		info.path = m_server->get_builtin_modules_path()+"/"+info.name;

		bool ok = m_server->load_module(info);
		if(!ok){
			m_shutdown_reason = ss_()+"Error loading builtin/loader";
			m_server->shutdown(1);
			return;
		}

		loader::access(m_server, [&](loader::Interface * i){
			i->activate();
		});
	}

	void on_module_modified(const interface::ModuleModifiedEvent &event)
	{
		log_v(MODULE, "__loader::on_module_modified(): %s", cs(event.name));
		if(event.name == "__loader")
			return;
		m_server->reload_module(event.name);
	}
};

extern "C" {
	EXPORT void* createModule___loader(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
