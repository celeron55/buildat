#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
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
		m_server->sub_event(this,
				Event::t("network:packet_received/core:request_file"));
		m_server->sub_event(this,
				Event::t("network:packet_received/core:all_files_transferred"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:new_client", on_new_client, network::NewClient)
		EVENT_TYPEN("network:packet_received/core:request_file", on_request_file,
				network::Packet)
		EVENT_TYPEN("network:packet_received/core:all_files_transferred",
				on_all_files_transferred, network::Packet)
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
		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(new_client.info.id,
					"core:tell_after_all_files_transferred", "");
		});
	}

	void on_request_file(const network::Packet &packet)
	{
		ss_ file_name;
		ss_ file_hash;
		std::istringstream is(packet.data, std::ios::binary);
		{
			cereal::BinaryInputArchive ar(is);
			ar(file_name);
			ar(file_hash);
		}
		log_v(MODULE, "File request: %s %s", cs(file_name),
				cs(interface::sha1::hex(file_hash)));
		auto it = m_files.find(file_name);
		if(it == m_files.end()){
			log_w(MODULE, "Requested file does not exist: \"%s\"", cs(file_name));
			return;
		}
		const FileInfo &info = *it->second.get();
		if(info.hash != file_hash){
			log_w(MODULE, "Requested file differs in hash: \"%s\": "
					"requested %s, actual %s", cs(file_name),
					cs(interface::sha1::hex(file_hash)),
					cs(interface::sha1::hex(info.hash)));
			return;
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::BinaryOutputArchive ar(os);
			ar(info.name);
			ar(info.hash);
			ar(info.content);
		}
		network::access(m_server, [&](network::Interface * inetwork){
			inetwork->send(packet.sender, "core:file_content", os.str());
		});
	}

	void on_all_files_transferred(const network::Packet &packet)
	{
		m_server->emit_event(ss_()+"client_file:files_transmitted",
				new FilesTransmitted(packet.sender));
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
