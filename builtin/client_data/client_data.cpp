// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "client_file/api.h"
#include "network/api.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <fstream>
#include <streambuf>

using interface::Event;

namespace client_data {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server),
		interface::Module("client_data")
	{
		log_v(MODULE, "client_data construct");
	}

	~Module()
	{
		log_v(MODULE, "client_data destruct");
	}

	void init()
	{
		log_v(MODULE, "client_data init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:module_loaded"));
		m_server->sub_event(this, Event::t("core:module_unloaded"));
		m_server->sub_event(this, Event::t("network:new_client"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:module_loaded", on_module_loaded,
				interface::ModuleLoadedEvent)
		EVENT_TYPEN("core:module_unloaded", on_module_unloaded,
				interface::ModuleUnloadedEvent)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
	}

	void on_start()
	{
	}

	void on_module_loaded(const interface::ModuleLoadedEvent &event)
	{
		log_v(MODULE, "on_module_loaded(): %s", cs(event.name));
		ss_ module_name = event.name;
		ss_ module_path = m_server->get_module_path(module_name);
		ss_ client_data_path = module_path+"/client_data";
		auto list = interface::getGlobalFilesystem()
				->list_directory(client_data_path);

		sv_<ss_> log_list;
		for(const interface::Filesystem::Node &n : list){
			if(n.is_directory)
				continue;
			log_list.push_back(n.name);
		}
		log_i(MODULE, "client_data: %s: %s", cs(module_name), cs(dump(log_list)));

		for(const interface::Filesystem::Node &n : list){
			if(n.is_directory)
				continue;
			const ss_ &file_path = client_data_path+"/"+n.name;
			const ss_ &public_file_name = module_name+"/"+n.name;
			client_file::access(m_server, [&](client_file::Interface * i){
				i->add_file_path(public_file_name, file_path);
			});
		}
	}

	void on_module_unloaded(const interface::ModuleUnloadedEvent &event)
	{
		log_v(MODULE, "on_module_unloaded(): %s", cs(event.name));
		// TODO: Tell client_file to remove files
	}

	void on_new_client(const network::NewClient &new_client)
	{
	}
};

extern "C" {
	EXPORT void* createModule_client_data(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
