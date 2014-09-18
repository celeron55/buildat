#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "client_file/include/api.h"
#include "client_lua/include/api.h"
#include "network/include/api.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <fstream>
#include <streambuf>

using interface::Event;

namespace client_lua {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server),
		interface::Module("client_lua")
	{
		log_v(MODULE, "client_lua construct");
	}

	~Module()
	{
		log_v(MODULE, "client_lua destruct");
	}

	void init()
	{
		log_v(MODULE, "client_lua init");
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
		ss_ client_lua_path = module_path+"/client_lua";
		auto list = interface::getGlobalFilesystem()
				->list_directory(client_lua_path);

		sv_<ss_> log_list;
		for(const interface::Filesystem::Node &n : list){
			if(n.is_directory)
				continue;
			log_list.push_back(n.name);
		}
		log_i(MODULE, "client_lua: %s: %s", cs(module_name), cs(dump(log_list)));

		for(const interface::Filesystem::Node &n : list){
			if(n.is_directory)
				continue;
			const ss_ &file_name = n.name;
			std::ifstream f(client_lua_path+"/"+file_name);
			std::string file_content((std::istreambuf_iterator<char>(f)),
					std::istreambuf_iterator<char>());

			client_file::access(m_server, [&](client_file::Interface * i){
				i->add_file_content(file_name, file_content);
			});
		}
	}

	void on_module_unloaded(const interface::ModuleUnloadedEvent &event)
	{
		log_v(MODULE, "on_module_unloaded(): %s", cs(event.name));
		// TODO
	}

	void on_new_client(const network::NewClient &new_client)
	{
		log_i(MODULE, "client_lua::on_new_client: id=%zu", new_client.info.id);

		ss_ module_path = m_server->get_module_path(MODULE);

#if 0
		// Not sure what this is useful for
		std::ifstream f(module_path+"/boot.lua");
		std::string script_content((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());

		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(new_client.info.id, "core:run_script", script_content);
		});
#endif
#if 0
		sv_<ss_> module_names = m_server->get_loaded_modules();

		for(const ss_ &module_name : module_names){
			ss_ module_path = m_server->get_module_path(module_name);
			ss_ client_lua_path = module_path+"/client_lua";
			auto list = interface::getGlobalFilesystem()
					->list_directory(client_lua_path);

			sv_<ss_> log_list;
			for(const interface::Filesystem::Node &n : list){
				if(n.is_directory)
					continue;
				log_list.push_back(n.name);
			}
			log_i(MODULE, "client_lua: %s: %s", cs(module_name), cs(dump(log_list)));

			for(const interface::Filesystem::Node &n : list){
				if(n.is_directory)
					continue;
				std::ifstream f(client_lua_path+"/"+n.name);
				std::string file_content((std::istreambuf_iterator<char>(f)),
						std::istreambuf_iterator<char>());

				std::ostringstream os(std::ios::binary);
				{
					cereal::BinaryOutputArchive ar(os);
					ar(n.name);
					ar(file_content);
				}
				network::access(m_server, [&](network::Interface * inetwork){
					inetwork->send(new_client.info.id, "core:cache_file", os.str());
				});
			}
			m_server->emit_event(ss_()+"client_lua:files_sent:"+module_name,
					new FilesSent(new_client.info.id));
		}
#endif
	}
};

extern "C" {
	EXPORT void* createModule_client_lua(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
