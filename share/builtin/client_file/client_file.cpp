#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/sha1.h"
#include "client_file/include/api.h"
#include "network/include/api.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <fstream>
#include <streambuf>

using interface::Event;

struct FileInfo {
	ss_ name;
	ss_ content;
	ss_ hash;
	FileInfo(const ss_ &name, const ss_ &content, const ss_ &hash):
		name(name), content(content), hash(hash){}
};

namespace client_file {

struct Module: public interface::Module, public client_file::Interface
{
	interface::Server *m_server;
	sm_<ss_, sp_<FileInfo>> m_files;

	Module(interface::Server *server):
		m_server(server),
		interface::Module("client_file")
	{
		log_v(MODULE, "client_file construct");
	}

	~Module()
	{
		log_v(MODULE, "client_file destruct");
	}

	void init()
	{
		log_v(MODULE, "client_file init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:new_client"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
	}

	void on_start()
	{
	}

	void on_new_client(const network::NewClient &new_client)
	{
		log_i(MODULE, "client_file::on_new_client: id=%zu", new_client.info.id);

		// Tell file hashes to client
		for(auto &pair : m_files){
			const FileInfo &info = *pair.second.get();
			std::ostringstream os(std::ios::binary);
			{
				cereal::BinaryOutputArchive ar(os);
				ar(info.name);
				ar(info.hash);
			}
			network::access(m_server, [&](network::Interface * inetwork){
				inetwork->send(new_client.info.id, "core:announce_file", os.str());
			});
		}
		m_server->emit_event(ss_()+"client_file:files_sent",
				new FilesSent(new_client.info.id));

#if 0
		sv_<ss_> module_names = m_server->get_loaded_modules();

		for(const ss_ &module_name : module_names){
			ss_ module_path = m_server->get_module_path(module_name);
			ss_ client_file_path = module_path+"/client_file";
			auto list = interface::getGlobalFilesystem()->list_directory(client_file_path);

			sv_<ss_> log_list;
			for(const interface::Filesystem::Node &n : list){
				if(n.is_directory)
					continue;
				log_list.push_back(n.name);
			}
			log_i(MODULE, "client_file: %s: %s", cs(module_name), cs(dump(log_list)));

			for(const interface::Filesystem::Node &n : list){
				if(n.is_directory)
					continue;
				std::ifstream f(client_file_path+"/"+n.name);
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
			m_server->emit_event(ss_()+"client_file:files_sent:"+module_name,
					new FilesSent(new_client.info.id));
		}
#endif
	}

	// Interface

	void add_file_content(const ss_ &name, const ss_ &content)
	{
		ss_ hash = interface::sha1::calculate(content);
		log_v(MODULE, "File: %s: %s", cs(name),
				cs(interface::sha1::hex(hash)));
		m_files[name] = up_<FileInfo>(new FileInfo(name, content, hash));
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	EXPORT void* createModule_client_file(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
