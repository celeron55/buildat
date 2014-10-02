// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "client/state.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include "interface/sha1.h"
#include "interface/fs.h"
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/string.hpp>
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstrict-aliasing"
#include <Node.h>
#include <Scene.h>
#include <MemoryBuffer.h>
#include <SmoothedTransform.h>
#pragma GCC diagnostic pop
#include <cstring>
#include <fstream>
#include <deque>
#include <sys/socket.h>
#define MODULE "__state"
namespace magic = Urho3D;

using magic::Node;
using magic::Component;
using magic::SmoothedTransform;

extern client::Config g_client_config;

namespace client {

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;
	std::deque<char> m_socket_buffer;
	interface::PacketStream m_packet_stream;
	sp_<app::App> m_app;
	ss_ m_remote_cache_path;
	ss_ m_tmp_path;
	sm_<ss_, ss_> m_file_hashes; // name -> hash
	set_<ss_> m_waiting_files; // name
	bool m_tell_after_all_files_transferred_requested = false;
	// Connecting is possible only once. After that has happened, the whole
	// state has to be recreated for making a new connection.
	// In actuality the whole client application has to be recreated because
	// otherwise unwanted Lua state remains.
	bool m_connected = false;
	sm_<ss_, std::function<void(const ss_&, const ss_&)>> m_packet_handlers;

	CState(sp_<app::App> app):
		m_socket(interface::createTCPSocket()),
		m_app(app),
		m_remote_cache_path(g_client_config.cache_path+"/remote"),
		m_tmp_path(g_client_config.cache_path+"/tmp")
	{
		// Create directory for cached files
		auto *fs = interface::getGlobalFilesystem();
		fs->create_directories(m_remote_cache_path);
		fs->create_directories(m_tmp_path);

		setup_packet_handlers();
	}

	void update()
	{
		if(m_socket->wait_data(0)){
			read_socket();
			handle_socket_buffer();
		}
	}

	bool connect(const ss_ &address, const ss_ &port, ss_ *error)
	{
		if(m_connected){
			log_i(MODULE, "client::State: Cannot re-use state for new connection");
			if(error)
				*error = "Cannot re-use state for new connection";
			return false;
		}

		bool ok = m_socket->connect_fd(address, port);
		if(ok){
			log_i(MODULE, "client::State: Connect succeeded (%s:%s)",
					cs(address), cs(port));
			m_connected = true;
		} else {
			log_i(MODULE, "client::State: Connect failed (%s:%s)",
					cs(address), cs(port));
			if(error)
				*error = "Connect failed";
		}
		return ok;
	}

	void send_packet(const ss_ &name, const ss_ &data)
	{
		log_v(MODULE, "send_packet(): name=%s", cs(name));
		m_packet_stream.output(name, data, [&](const ss_ & packet_data){
			m_socket->send_fd(packet_data);
		});
	}

	ss_ get_file_path(const ss_ &name, ss_ *dst_file_hash)
	{
		auto it = m_file_hashes.find(name);
		if(it == m_file_hashes.end())
			return "";
		const ss_ &file_hash = it->second;
		ss_ file_hash_hex = interface::sha1::hex(file_hash);
		ss_ path = m_remote_cache_path+"/"+file_hash_hex;
		if(dst_file_hash != nullptr)
			*dst_file_hash = file_hash;
		return path;
	}

	ss_ get_file_content(const ss_ &name)
	{
		ss_ file_hash;
		ss_ path = get_file_path(name, &file_hash);
		std::ifstream f(path);
		if(!f.good())
			throw Exception(ss_()+"Could not open file: "+path);
		std::string file_content((std::istreambuf_iterator<char>(f)),
				std::istreambuf_iterator<char>());
		ss_ file_hash2 = interface::sha1::calculate(file_content);
		if(file_hash != file_hash2){
			log_e(MODULE, "Opened file differs in hash: \"%s\": "
					"requested %s, actual %s", cs(name),
					cs(interface::sha1::hex(file_hash)),
					cs(interface::sha1::hex(file_hash2)));
			throw Exception(ss_()+"Invalid file content: "+path);
		}
		return file_content;
	}

	void read_socket()
	{
		int fd = m_socket->fd();
		char buf[100000];
		ssize_t r = recv(fd, buf, 100000, 0);
		if(r == -1)
			throw Exception(ss_()+"Receive failed: "+strerror(errno));
		if(r == 0){
			log_w(MODULE, "Peer disconnected");
			return;
		}
		log_d(MODULE, "Received %zu bytes", r);
		m_socket_buffer.insert(m_socket_buffer.end(), buf, buf + r);
	}

	void handle_socket_buffer()
	{
		m_packet_stream.input(m_socket_buffer,
		[&](const ss_ & name, const ss_ & data){
			try {
				handle_packet(name, data);
			} catch(std::exception &e){
				log_w(MODULE, "Exception on handling packet: %s", e.what());
			}
		});
	}

	void setup_packet_handlers();

	void handle_packet(const ss_ &packet_name, const ss_ &data)
	{
		auto it = m_packet_handlers.find(packet_name);
		if(it == m_packet_handlers.end()){
			// Pass forward
			m_app->handle_packet(packet_name, data);
		} else {
			// Use handler
			auto &handler = it->second;
			handler(packet_name, data);
		}
	}
};

void CState::setup_packet_handlers()
{
	m_packet_handlers["core:run_script"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		log_i(MODULE, "Asked to run script:\n----\n%s\n----", cs(data));
		if(m_app)
			m_app->run_script(data);
	};

	m_packet_handlers["core:announce_file"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		ss_ file_name;
		ss_ file_hash;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(file_name);
			ar(file_hash);
		}
		m_file_hashes[file_name] = file_hash;
		ss_ file_hash_hex = interface::sha1::hex(file_hash);
		log_v(MODULE, "Server announces file: %s %s",
				cs(file_hash_hex), cs(file_name));
		// Check if we already have this file
		ss_ path = m_remote_cache_path+"/"+file_hash_hex;
		std::ifstream ifs(path, std::ios::binary);
		bool cached_is_ok = false;
		if(ifs.good()){
			std::string content((std::istreambuf_iterator<char>(ifs)),
					std::istreambuf_iterator<char>());
			ss_ content_hash = interface::sha1::calculate(content);
			if(content_hash == file_hash){
				// We have it; no need to ask this file
				log_i(MODULE, "%s %s: cached",
						cs(file_hash_hex), cs(file_name));
				cached_is_ok = true;
			} else {
				// Our copy is broken, re-request it
				log_i(MODULE, "%s %s: Our copy is broken (has hash %s)",
						cs(file_hash_hex), cs(file_name),
						cs(interface::sha1::hex(content_hash)));
			}
		}
		if(cached_is_ok){
			// Let Lua resource wrapper know that this happened so it can update
			// the copy made for Urho3D's resource cache
			m_app->file_updated_in_cache(file_name, file_hash, path);
		} else {
			// We don't have it; request this file
			log_i(MODULE, "%s %s: requesting",
					cs(file_hash_hex), cs(file_name));
			std::ostringstream os(std::ios::binary);
			{
				cereal::PortableBinaryOutputArchive ar(os);
				ar(file_name);
				ar(file_hash);
			}
			send_packet("core:request_file", os.str());
			m_waiting_files.insert(file_name);
		}
	};

	m_packet_handlers["core:tell_after_all_files_transferred"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		if(m_waiting_files.empty()){
			send_packet("core:all_files_transferred", "");
		} else {
			m_tell_after_all_files_transferred_requested = true;
		}
	};

	m_packet_handlers["core:file_content"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		ss_ file_name;
		ss_ file_hash;
		ss_ file_content;
		std::istringstream is(data, std::ios::binary);
		{
			cereal::PortableBinaryInputArchive ar(is);
			ar(file_name);
			ar(file_hash);
			ar(file_content);
		}
		if(m_waiting_files.count(file_name) == 0){
			log_w(MODULE, "Received file was not requested: %s %s",
					cs(interface::sha1::hex(file_hash)), cs(file_name));
			return;
		}
		m_waiting_files.erase(file_name);
		ss_ file_hash2 = interface::sha1::calculate(file_content);
		if(file_hash != file_hash2){
			log_w(MODULE, "Requested file differs in hash: \"%s\": "
					"requested %s, actual %s", cs(file_name),
					cs(interface::sha1::hex(file_hash)),
					cs(interface::sha1::hex(file_hash2)));
			return;
		}
		ss_ file_hash_hex = interface::sha1::hex(file_hash);
		ss_ path = g_client_config.cache_path+"/remote/"+file_hash_hex;
		log_i(MODULE, "Saving %s to %s", cs(file_name), cs(path));
		std::ofstream of(path, std::ios::binary);
		of<<file_content;
		if(m_tell_after_all_files_transferred_requested){
			if(m_waiting_files.empty()){
				send_packet("core:all_files_transferred", "");
				m_tell_after_all_files_transferred_requested = false;
			}
		}
		// Let Lua resource wrapper know that this happened so it can update
		// the copy made for Urho3D's resource cache
		m_app->file_updated_in_cache(file_name, file_hash, path);
	};

	m_packet_handlers["entitysync:new_node"] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
		// For a reference implementation of this kind of network
		// synchronization, see Urho3D's Network/Connection.cpp

		magic::Scene *scene = m_app->get_scene();
		magic::MemoryBuffer msg(data.c_str(), data.size());
		uint node_id = msg.ReadNetID();
		Node *node = scene->GetNode(node_id);
		if(!node){
			log_v(MODULE, "Creating node %i", node_id);
			// Add to the root level; it may be moved as we receive the parent
			// attribute
			node = scene->CreateChild(node_id, magic::REPLICATED);
			node->CreateComponent<SmoothedTransform>(magic::LOCAL);
		}
		// Read initial attributes
		node->ReadDeltaUpdate(msg);
		// Skip transition to first position
		SmoothedTransform *transform = node->GetComponent<SmoothedTransform>();
		if(transform)
			transform->Update(1.0f, 0.0f);

		// Read initial user variables
		uint num_vars = msg.ReadVLE();
		while(num_vars){
			auto key = msg.ReadStringHash();
			node->SetVar(key, msg.ReadVariant());
			num_vars--;
		}

		// Read components
		uint num_c = msg.ReadVLE();
		while(num_c){
			num_c--;

			auto type = msg.ReadStringHash();
			uint c_id = msg.ReadNetID();

			Component *c = scene->GetComponent(c_id);
			if(!c || c->GetType() != type || c->GetNode() != node){
				if(c)
					c->Remove();
				log_v(MODULE, "Creating component %i", c_id);
				c = node->CreateComponent(type, magic::REPLICATED, c_id);
				if(!c){
					log_e(MODULE, "Could not create component %i", c_id);
					return;
				}
			}
			c->ReadDeltaUpdate(msg);
			c->ApplyAttributes();
		}
	};

	m_packet_handlers[""] =
			[this](const ss_ &packet_name, const ss_ &data)
	{
	};
}

State* createState(sp_<app::App> app)
{
	return new CState(app);
}
}
// vim: set noet ts=4 sw=4:
