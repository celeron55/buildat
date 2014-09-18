#include "core/log.h"
#include "client/state.h"
#include "client/app.h"
#include "client/config.h"
#include "interface/tcpsocket.h"
#include "interface/packet_stream.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <cstring>
#include <fstream>
#include <deque>
#include <sys/socket.h>
#define MODULE "__state"

extern client::Config g_client_config;

namespace client {

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;
	std::deque<char> m_socket_buffer;
	interface::PacketStream m_packet_stream;
	sp_<app::App> m_app;

	CState(sp_<app::App> app):
		m_socket(interface::createTCPSocket()),
		m_app(app)
	{}

	bool connect(const ss_ &address, const ss_ &port)
	{
		bool ok = m_socket->connect_fd(address, port);
		if(ok)
			log_i(MODULE, "client::State: Connect succeeded (%s:%s)",
					cs(address), cs(port));
		else
			log_i(MODULE, "client::State: Connect failed (%s:%s)",
					cs(address), cs(port));
		return ok;
	}

	bool send(const ss_ &data)
	{
		return m_socket->send_fd(data);
	}

	void update()
	{
		if(m_socket->wait_data(0)){
			read_socket();
			handle_socket_buffer();
		}
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

	void handle_packet(const ss_ &packet_name, const ss_ &data)
	{
		log_i(MODULE, "Received packet name: %s", cs(packet_name));

		if(packet_name == "core:run_script"){
			log_i(MODULE, "Asked to run script:\n----\n%s\n----", cs(data));
			if(m_app)
				m_app->run_script(data);
			return;
		}
		if(packet_name == "core:announce_file"){
			ss_ file_name;
			ss_ file_hash;
			std::istringstream is(data, std::ios::binary);
			{
				cereal::BinaryInputArchive ar(is);
				ar(file_name);
				ar(file_hash);
			}
			// TODO: Check if we already have this file
			ss_ path = g_client_config.cache_path+"/remote/"+file_hash;
			std::ifstream ifs(path, std::ios::binary);
			if(ifs.good()){
				// We have it; no need to ask this file
			} else {
				// We don't have it; request this file
			}
		}
		if(packet_name == "core:transfer_file"){
			ss_ file_name;
			ss_ file_content;
			std::istringstream is(data, std::ios::binary);
			{
				cereal::BinaryInputArchive ar(is);
				ar(file_name);
				ar(file_content);
			}
			// TODO: Check filename for malicious characters "/.\"\\"
			ss_ path = g_client_config.cache_path+"/remote/"+file_name;
			std::ofstream of(path, std::ios::binary);
			of<<file_content;
		}
	}
};

State* createState(sp_<app::App> app)
{
	return new CState(app);
}
}
