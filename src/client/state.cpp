#include "client/state.h"
#include "core/log.h"
#include "interface/tcpsocket.h"
//#include <cereal/archives/binary.hpp>
//#include <cereal/types/string.hpp>
#include <cstring>
#include <deque>
#include <sys/socket.h>
#define MODULE "__state"

namespace client {

struct ClientPacketTypeRegistry
{
	sm_<ss_, PacketType> m_types;
	sm_<PacketType, ss_> m_names;

	void set(PacketType type, const ss_ &name){
		m_types[name] = type;
		m_names[type] = name;
	}
	PacketType get_type(const ss_ &name){
		auto it = m_types.find(name);
		if(it != m_types.end())
			return it->second;
		throw Exception(ss_()+"Packet not known: "+name);
	}
	ss_ get_name(PacketType type){
		auto it = m_names.find(type);
		if(it != m_names.end())
			return it->second;
		throw Exception(ss_()+"Packet not known: "+itos(type));
	}
};

struct CState: public State
{
	sp_<interface::TCPSocket> m_socket;
	std::deque<char> m_socket_buffer;
	ClientPacketTypeRegistry m_packet_types;

	CState():
		m_socket(interface::createTCPSocket())
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
			log_i(MODULE, "Peer disconnected");
			return;
		}
		log_i(MODULE, "Received %zu bytes", r);
		m_socket_buffer.insert(m_socket_buffer.end(), buf, buf + r);
	}

	void handle_socket_buffer()
	{
		for(;;){
			if(m_socket_buffer.size() < 6)
				return;
			size_t type =
					(m_socket_buffer[0]&0xff)<<0 |
					(m_socket_buffer[1]&0xff)<<8;
			size_t size =
					(m_socket_buffer[2]&0xff)<<0 |
					(m_socket_buffer[3]&0xff)<<8 |
					(m_socket_buffer[4]&0xff)<<16 |
					(m_socket_buffer[5]&0xff)<<24;
			log_i(MODULE, "size=%zu", size);
			if(m_socket_buffer.size() < 6 + size)
				return;
			log_i(MODULE, "Received full packet; type=%zu, length=6+%zu",
					type, size);
			ss_ data(&m_socket_buffer[6], size);
			m_socket_buffer.erase(m_socket_buffer.begin(),
					m_socket_buffer.begin() + 6 + size);
			try {
				handle_packet(type, data);
			} catch(std::exception &e){
				log_w(MODULE, "Exception on handling packet: %s",
						e.what());
			}
		}
	}

	void handle_packet(size_t type, const ss_ &data)
	{
		// Type 0 is packet definition packet
		if(type == 0){
			PacketType type1 =
					data[0]<<0 |
					data[1]<<8;
			size_t name1_size =
					data[2]<<0 |
					data[3]<<8 |
					data[4]<<16 |
					data[5]<<24;
			if(data.size() < 6 + name1_size)
				return;
			ss_ name1(&data.c_str()[6], name1_size);
			log_i(MODULE, "Packet definition: %zu = %s", type1, cs(name1));
			m_packet_types.set(type1, name1);
			return;
		}

		ss_ packet_name = m_packet_types.get_name(type);
		log_i(MODULE, "Received packet name: %s", cs(packet_name));

		if(packet_name == "core:run_script"){
			log_i(MODULE, "Asked to run script:\n----\n%s\n----", cs(data));
			return;
		}
	}
};

State* createState()
{
	return new CState();
}
}
