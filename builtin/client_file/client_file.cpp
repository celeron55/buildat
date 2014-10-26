// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/sha1.h"
#include "interface/file_watch.h"
#include "interface/fs.h"
#include "interface/thread.h"
#include "interface/select_handler.h"
#include "client_file/api.h"
#include "network/api.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/tuple.hpp>
#include <fstream>
#include <streambuf>

using interface::Event;

struct FileInfo {
	ss_ name;
	ss_ content;
	ss_ hash;
	ss_ path; // Empty if not a physical file
	FileInfo(const ss_ &name, const ss_ &content, const ss_ &hash, const ss_ &path):
		name(name), content(content), hash(hash), path(path){}
};

namespace client_file {

struct Module;

struct FileWatchThread: public interface::ThreadedThing
{
	static constexpr const char *MODULE = "client_file";

	Module *m_module = nullptr;

	FileWatchThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
};

struct Module: public interface::Module, public client_file::Interface
{
	interface::Server *m_server;
	sm_<ss_, sp_<FileInfo>> m_files;
	sp_<interface::FileWatch> m_watch;
	sp_<interface::Thread> m_thread;

	Module(interface::Server *server):
		interface::Module("client_file"),
		m_server(server),
		m_watch(interface::createFileWatch())
	{
		log_d(MODULE, "client_file construct");

		m_thread.reset(interface::createThread(new FileWatchThread(this)));
		m_thread->start();
	}

	~Module()
	{
		log_d(MODULE, "client_file destruct");
	}

	void init()
	{
		log_d(MODULE, "client_file init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this,
				Event::t("network:packet_received/core:request_file"));
		m_server->sub_event(this,
				Event::t("network:packet_received/core:all_files_transferred"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:packet_received/core:request_file", on_request_file,
				network::Packet)
		EVENT_TYPEN("network:packet_received/core:all_files_transferred",
				on_all_files_transferred, network::Packet)
	}

	void on_start()
	{
	}

	void on_unload()
	{
		log_v(MODULE, "on_unload");

		// name, content, path
		sv_<std::tuple<ss_, ss_, ss_>> file_restore_info;
		for(auto &pair : m_files){
			const FileInfo &info = *pair.second.get();
			if(info.path != ""){
				file_restore_info.push_back(std::tuple<ss_, ss_, ss_>(
							info.name, "", info.path));
			} else {
				file_restore_info.push_back(std::tuple<ss_, ss_, ss_>(
							info.name, info.content, ""));
			}
		}

		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(file_restore_info);
		}
		m_server->tmp_store_data("client_file:restore_info", os.str());
	}

	void on_continue()
	{
		log_v(MODULE, "on_continue");
		ss_ data = m_server->tmp_restore_data("client_file:restore_info");
		// name, content, path
		sv_<std::tuple<ss_, ss_, ss_>> file_restore_info;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(file_restore_info);
		}
		for(auto &tuple : file_restore_info){
			const ss_ &name = std::get<0>(tuple);
			const ss_ &content = std::get<1>(tuple);
			const ss_ &path = std::get<2>(tuple);
			log_i(MODULE, "Restoring: %s", cs(name));
			if(path != ""){
				add_file_path(name, path);
			} else {
				add_file_content(name, content);
			}
		}
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "Sending file hashes to new client %zu",
				client_connected.info.id);

		// Tell file hashes to client
		for(auto &pair : m_files){
			const FileInfo &info = *pair.second.get();
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(info.name);
				ar(info.hash);
			}
			network::access(m_server, [&](network::Interface *inetwork){
				inetwork->send(client_connected.info.id, "core:announce_file",
						os.str());
			});
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(client_connected.info.id,
					"core:tell_after_all_files_transferred", "");
		});
	}

	void on_request_file(const network::Packet &packet)
	{
		ss_ file_name;
		ss_ file_hash;
		std::istringstream is(packet.data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
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
			cereal::PortableBinaryOutputArchive ar(os);
			ar(info.name);
			ar(info.hash);
			ar(info.content);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "core:file_content", os.str());
		});
	}

	void on_all_files_transferred(const network::Packet &packet)
	{
		m_server->emit_event(ss_()+"client_file:files_transmitted",
				new FilesTransmitted(packet.sender));
	}

	// Interface for FileWatchThread

	sv_<int> get_sockets()
	{
		return m_watch->get_fds();
	}

	void handle_active_socket(int fd)
	{
		log_d(MODULE, "handle_active_socket(): fd=%i", fd);
		m_watch->report_fd(fd);
	}

	// Interface

	void update_file_content(const ss_ &name, const ss_ &content)
	{
		ss_ hash = interface::sha1::calculate(content);

		auto it = m_files.find(name);
		if(it != m_files.end()){
			// File already added; ignore if content wasn't modified
			sp_<FileInfo> old_info = it->second;
			if(old_info->hash == hash){
				log_d(MODULE, "File stayed the same: %s: %s", cs(name),
						cs(interface::sha1::hex(hash)));
				return;
			}
		}

		log_v(MODULE, "File updated: %s: %s", cs(name),
				cs(interface::sha1::hex(hash)));
		m_files[name] = sp_<FileInfo>(new FileInfo(name, content, hash, ""));

		// Notify clients of modified file
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(name);
			ar(hash);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			sv_<network::PeerInfo::Id> peers = inetwork->list_peers();
			for(const network::PeerInfo::Id &peer: peers){
				inetwork->send(peer, "core:announce_file", os.str());
			}
		});
	}

	void add_file_content(const ss_ &name, const ss_ &content)
	{
		update_file_content(name, content);
	}

	void add_file_path(const ss_ &name, const ss_ &path)
	{
		std::ifstream f(path, std::ios::binary);
		if(!f.good())
			throw Exception("client_file::add_file_path(): Couldn't open \""+
						  name+"\" from \""+path+"\"");
		std::string content((std::istreambuf_iterator<char>(f)),
			std::istreambuf_iterator<char>());
		ss_ hash = interface::sha1::calculate(content);
		log_v(MODULE, "File added: %s: %s (%s)", cs(name),
				cs(interface::sha1::hex(hash)), cs(path));
		m_files[name] = sp_<FileInfo>(new FileInfo(name, content, hash, path));

		// Tell path to server so that it can be used in network-synced Scene
		m_server->add_file_path(name, path);

		ss_ dir_path = interface::Filesystem::strip_file_name(path);
		m_watch->add(dir_path, [this, name, path](const ss_ &path_){
			if(path_ != path){
				//log_d(MODULE, "Ignoring file watch callback: %s (we want %s)",
				//		cs(path_), cs(path));
				return;
			}
			log_d(MODULE, "File watch callback: %s (%s)", cs(name), cs(path_));
			std::ifstream f(path, std::ios::binary);
			if(!f.good()){
				log_w(MODULE, "client_file: Couldn't open updated file "
						"\"%s\" from \"%s\"", cs(name), cs(path));
				return;
			}
			std::string content((std::istreambuf_iterator<char>(f)),
					std::istreambuf_iterator<char>());
			if(content.empty()){
				log_w(MODULE, "client_file: Updated file is empty: "
						"\"%s\" from \"%s\"", cs(name), cs(path));
				return;
			}
			update_file_content(name, content);
		});
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

void FileWatchThread::run(interface::Thread *thread)
{
	interface::SelectHandler handler;

	while(!thread->stop_requested()){
		sv_<int> sockets;
		// We can avoid implementing our own mutex locking in Module by using
		// interface::Server::access_module() instead of directly accessing it.
		client_file::access(m_module->m_server,
				[&](client_file::Interface *iclient_file)
		{
			sockets = m_module->get_sockets();
		});

		sv_<int> active_sockets;
		bool ok = handler.check(500000, sockets, active_sockets);
		(void)ok; // Unused

		client_file::access(m_module->m_server,
				[&](client_file::Interface *iclient_file)
		{
			for(int fd: active_sockets){
				m_module->handle_active_socket(fd);
			}
		});
	}
}

extern "C" {
	BUILDAT_EXPORT void* createModule_client_file(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
