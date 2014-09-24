#include "interface/module.h"
#include "interface/server.h"
#include "interface/fs.h"
#include "interface/event.h"
#include "core/log.h"

using interface::Event;

namespace __loader {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		interface::Module("__loader"),
		m_server(server)
	{
		log_v(MODULE, "__loader construct");
	}

	~Module()
	{
		log_v(MODULE, "__loader destruct");
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
		ss_ builtin = m_server->get_builtin_modules_path();
		ss_ current = m_server->get_modules_path();

		sv_<std::pair<ss_, ss_>> load_list = {
			{builtin, "network"},
			{builtin, "client_file"},
			{builtin, "client_lua"},
			{builtin, "client_data"},
			{current, "test1"},
			//{current, "test2"},
			//{current, "minigame"},
		};
		for(auto &pair : load_list){
			const ss_ &name = pair.second;
			const ss_ &path = pair.first+"/"+pair.second;
			bool ok = m_server->load_module(name, path);
			if(!ok){
				m_server->shutdown(1);
				break;
			}
		}

		/*// TODO: Dependencies
		auto list = interface::getGlobalFilesystem()->list_directory(m_server->get_modules_path());
		for(const interface::Filesystem::Node &n : list){
			if(n.name == "__loader")
				continue;
			m_server->load_module(n.name, m_server->get_modules_path()+"/"+n.name);
		}*/
	}

	void on_module_modified(const interface::ModuleModifiedEvent &event)
	{
		log_v(MODULE, "__loader::on_module_modified(): %s", cs(event.name));
		if(event.name == "__loader")
			return;
		m_server->reload_module(event.name, event.path);
	}
};

extern "C" {
	EXPORT void* createModule___loader(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
