// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/sha1.h"
#include "interface/file_watch.h"
#include "interface/fs.h"
#include "interface/compress.h"
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
#define MODULE "client_file"

using interface::Event;

struct FileInfo {
	ss_ name;
	// What the file holds, for a file that has no path behind it. A
	// path-backed file is read from disk when it is sent instead: a game
	// whose media is hundreds of megabytes should cost the server none of
	// it. Luanti's m_media holds a path and a hash for the same reason.
	ss_ content;
	ss_ hash;
	ss_ path; // Empty if not a physical file
	FileInfo(const ss_ &name, const ss_ &content, const ss_ &hash, const ss_ &path):
		name(name), content(content), hash(hash), path(path){}
};

// How much a bunch of file contents is packed to before it is sent. Luanti
// uses the same number and says why in sendRequestedMedia: too many packets
// on one side, over-large split packets on the other. A file bigger than
// this goes on its own, whole.
static const size_t FILE_BUNCH_SIZE = 5000;

// A packet body, compressed when that is worth doing.
//
// The gain on a game's media is small -- PNG and OGG are compressed already
// -- and it is real on models, translation files and the announce packet,
// which is a few thousand names and hashes. Luanti compresses for protocol
// 48 and up and buildat is compared with it, so this is not a feature to be
// without.
//
// A flag byte says which it is, because zstd on incompressible data is
// larger than the data: the smaller of the two is sent and the client is
// told which it got. Trying costs one pass over the bytes and saves a game's
// worth of bandwidth on the half of it that does compress.
static const char PACKET_PLAIN = 0;
static const char PACKET_ZSTD = 1;

static ss_ pack_packet(const ss_ &body)
{
	std::ostringstream os(std::ios::binary);
	interface::compress_zstd(body, os);
	ss_ compressed = os.str();
	if(compressed.size() + 1 >= body.size() + 1)
		return ss_(1, PACKET_PLAIN) + body;
	return ss_(1, PACKET_ZSTD) + compressed;
}

static bool read_whole_file(const ss_ &path, ss_ &content_out)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		return false;
	content_out.assign((std::istreambuf_iterator<char>(f)),
			std::istreambuf_iterator<char>());
	return true;
}

namespace client_file {

struct Module;

struct FileWatchThread: public interface::ThreadedThing
{
	Module *m_module = nullptr;

	FileWatchThread(Module *module):
		m_module(module)
	{}

	void run(interface::Thread *thread);
	void on_crash(interface::Thread *thread);
};

struct Module: public interface::Module, public client_file::Interface
{
	interface::Server *m_server;
	sm_<ss_, sp_<FileInfo>> m_files;
	sp_<interface::FileWatch> m_watch;
	// What one request's worth of bunches cost, for the log line that says
	// whether compressing them was worth it
	size_t m_bytes_sent = 0;
	size_t m_bytes_raw = 0;
	up_<interface::Thread> m_thread;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server),
		m_watch(interface::createFileWatch())
	{
		log_d(MODULE, "client_file construct");
	}

	~Module()
	{
		log_d(MODULE, "client_file destruct");
		m_thread->request_stop();
		m_thread->join();
	}

	void init()
	{
		log_d(MODULE, "client_file init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("network:client_connected"));
		m_server->sub_event(this,
				Event::t("network:packet_received/core:request_files"));
		m_server->sub_event(this,
				Event::t("network:packet_received/core:all_files_transferred"));

		// Don't start thread in constructor because in there this module is not
		// guaranteed to be available by server->access_module()
		m_thread.reset(interface::createThread(new FileWatchThread(this)));
		m_thread->set_name("client_file/select");
		m_thread->start();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
		EVENT_TYPEN("network:packet_received/core:request_files",
				on_request_files, network::Packet)
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

	// One packet with every file's name and hash in it, rather than a packet
	// per file: a Luanti game is thousands of files, and thousands of packets
	// at connect is thousands of packets. Luanti's TOCLIENT_ANNOUNCE_MEDIA is
	// the same one packet.
	void announce_files(network::PeerInfo::Id peer,
			const sv_<std::tuple<ss_, ss_>> &files)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(files);
		}
		const ss_ packet = pack_packet(os.str());
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:announce_files", packet);
		});
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
		log_v(MODULE, "Announcing %zu files to new client %zu", m_files.size(),
				client_connected.info.id);

		sv_<std::tuple<ss_, ss_>> files;
		files.reserve(m_files.size());
		for(auto &pair : m_files){
			const FileInfo &info = *pair.second.get();
			files.push_back(std::tuple<ss_, ss_>(info.name, info.hash));
		}
		announce_files(client_connected.info.id, files);
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(client_connected.info.id,
					"core:tell_after_all_files_transferred", "");
		});
	}

	void send_bunch(network::PeerInfo::Id peer,
			const sv_<std::tuple<ss_, ss_, ss_>> &bunch)
	{
		if(bunch.empty())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(bunch);
		}
		const ss_ body = os.str();
		const ss_ packet = pack_packet(body);
		m_bytes_sent += packet.size();
		m_bytes_raw += body.size();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "core:file_contents", packet);
		});
	}

	void on_request_files(const network::Packet &packet)
	{
		sv_<std::tuple<ss_, ss_>> requested;
		std::istringstream is(packet.data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(requested);
		}
		log_v(MODULE, "%zu files requested by peer %zu", requested.size(),
				packet.sender);

		// name, hash, content
		sv_<std::tuple<ss_, ss_, ss_>> bunch;
		size_t bunch_size = 0;
		for(const auto &pair : requested){
			const ss_ &file_name = std::get<0>(pair);
			const ss_ &file_hash = std::get<1>(pair);
			auto it = m_files.find(file_name);
			if(it == m_files.end()){
				log_w(MODULE, "Requested file does not exist: \"%s\"",
						cs(file_name));
				continue;
			}
			const FileInfo &info = *it->second.get();
			if(info.hash != file_hash){
				log_w(MODULE, "Requested file differs in hash: \"%s\": "
						"requested %s, actual %s", cs(file_name),
						cs(interface::sha1::hex(file_hash)),
						cs(interface::sha1::hex(info.hash)));
				continue;
			}
			ss_ content;
			if(info.path.empty()){
				content = info.content;
			} else if(!read_whole_file(info.path, content)){
				log_w(MODULE, "Cannot read \"%s\" from \"%s\"",
						cs(file_name), cs(info.path));
				continue;
			}
			// The hash is not checked against what was just read. The client
			// checks it anyway -- it has to, since a file can change between
			// the announce and the request -- and hashing every file again on
			// every request is what a large game would pay for it.
			bunch_size += content.size();
			bunch.push_back(std::tuple<ss_, ss_, ss_>(
					info.name, info.hash, content));
			if(bunch_size >= FILE_BUNCH_SIZE){
				send_bunch(packet.sender, bunch);
				bunch.clear();
				bunch_size = 0;
			}
		}
		send_bunch(packet.sender, bunch);
		log_v(MODULE, "%zu files to peer %zu: %zu bytes over the wire for "
				"%zu of content", requested.size(), packet.sender,
				m_bytes_sent, m_bytes_raw);
		m_bytes_sent = 0;
		m_bytes_raw = 0;
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

	// content is what the file holds now and is only there to be hashed; it
	// is kept only when there is no path to read it from again.
	void set_file(const ss_ &name, const ss_ &content, const ss_ &path)
	{
		ss_ hash = interface::sha1::calculate(content);

		auto it = m_files.find(name);
		if(it != m_files.end() && it->second->hash == hash &&
				it->second->path == path){
			log_d(MODULE, "File stayed the same: %s: %s", cs(name),
					cs(interface::sha1::hex(hash)));
			return;
		}

		if(path.empty()){
			log_v(MODULE, "File updated: %s: %s", cs(name),
					cs(interface::sha1::hex(hash)));
			m_files[name] = sp_<FileInfo>(
					new FileInfo(name, content, hash, path));
		} else {
			log_v(MODULE, "File added: %s: %s (%s)", cs(name),
					cs(interface::sha1::hex(hash)), cs(path));
			m_files[name] = sp_<FileInfo>(new FileInfo(name, "", hash, path));
		}

		// Tell the connected clients, which is what makes an edited file
		// reach a running client. One entry in the same packet the whole set
		// goes out in at connect.
		sv_<std::tuple<ss_, ss_>> files{std::tuple<ss_, ss_>(name, hash)};
		sv_<network::PeerInfo::Id> peers;
		network::access(m_server, [&](network::Interface *inetwork){
			peers = inetwork->list_peers();
		});
		for(const network::PeerInfo::Id &peer : peers)
			announce_files(peer, files);
	}

	void add_file_content(const ss_ &name, const ss_ &content)
	{
		set_file(name, content, "");
	}

	void add_file_path(const ss_ &name, const ss_ &path)
	{
		ss_ content;
		if(!read_whole_file(path, content))
			throw Exception("client_file::add_file_path(): Couldn't open \""+
					name+"\" from \""+path+"\"");
		set_file(name, content, path);

		// Tell path to server so that it can be used in network-synced Scene
		m_server->add_file_path(name, path);

		if(!m_server->get_config().get<bool>("watch_client_files"))
			return;

		ss_ dir_path = interface::fs::strip_file_name(path);
		m_watch->add(dir_path, [this, name, path](const ss_ &path_){
			if(path_ != path){
				//log_d(MODULE, "Ignoring file watch callback: %s (we want %s)",
				//		cs(path_), cs(path));
				return;
			}
			log_d(MODULE, "File watch callback: %s (%s)", cs(name), cs(path_));
			ss_ content;
			if(!read_whole_file(path, content)){
				log_w(MODULE, "client_file: Couldn't open updated file "
						"\"%s\" from \"%s\"", cs(name), cs(path));
				return;
			}
			if(content.empty()){
				log_w(MODULE, "client_file: Updated file is empty: "
						"\"%s\" from \"%s\"", cs(name), cs(path));
				return;
			}
			set_file(name, content, path);
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

		if(active_sockets.empty())
			continue;

		client_file::access(m_module->m_server,
				[&](client_file::Interface *iclient_file)
		{
			for(int fd: active_sockets){
				m_module->handle_active_socket(fd);
			}
		});
	}
}

void FileWatchThread::on_crash(interface::Thread *thread)
{
	m_module->m_server->shutdown(1, "FileWatchThread crashed");
}

extern "C" {
	BUILDAT_EXPORT void* createModule_client_file(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
