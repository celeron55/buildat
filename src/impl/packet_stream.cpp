#include "interface/packet_stream.h"
#include "core/log.h"
#define MODULE "__packet_stream"

namespace interface {

void PacketStream::input(std::deque<char> &socket_buffer,
                         std::function<void(const ss_ &name, const ss_ &data)> cb)
{
	for(;;){
		if(socket_buffer.size() < 6)
			return;
		size_t type =
				socket_buffer[0]<<0 |
				socket_buffer[1]<<8;
		size_t size =
				socket_buffer[2]<<0 |
				socket_buffer[3]<<8 |
				socket_buffer[4]<<16 |
				socket_buffer[5]<<24;
		log_d(MODULE, "size=%zu", size);
		if(socket_buffer.size() < 6 + size)
			return;
		log_d(MODULE, "Received full packet; type=%zu, "
				"length=6+%zu", type, size);
		ss_ data(&socket_buffer[6], size);
		socket_buffer.erase(socket_buffer.begin(),
				socket_buffer.begin() + 6 + size);

		ss_ name = m_incoming_types.get_name(type);

		if(name == "core:define_packet_type"){
			PacketType type1 =
					data[0]<<0 |
					data[1]<<8;
			size_t name1_size =
					data[2]<<0 |
					data[3]<<8 |
					data[4]<<16 |
					data[5]<<24;
			if(data.size() < 6 + name1_size)
				continue;
			ss_ name1(&data.c_str()[6], name1_size);
			log_i(MODULE, "Packet definition: %zu = %s", type1, cs(name1));
			m_incoming_types.set(type1, name1);
			continue;
		}

		cb(name, data);
	}
}

void PacketStream::output(const ss_ &name, const ss_ &data,
                          std::function<void(const ss_ &packet_data)> cb)
{
	PacketType type = m_outgoing_types.get(name);
	log_d(MODULE, "output(): name=\"%s\", data.size()=%zu",
			cs(name), data.size());

	// Send new packet types if needed
	log_d(MODULE, "m_outgoing_types.m_next_type=%zu"
			", m_highest_known_type=%zu",
			m_outgoing_types.m_next_type, m_highest_known_type);
	if(m_outgoing_types.m_next_type > m_highest_known_type + 1){
		PacketType highest_known_type_was = m_highest_known_type;
		m_highest_known_type = m_outgoing_types.m_next_type - 1;
		for(PacketType t1 = highest_known_type_was + 1;
				t1 < m_outgoing_types.m_next_type; t1++){
			ss_ name = m_outgoing_types.get_name(t1);
			log_d(MODULE, "Sending type %zu = %s", t1, cs(name));
			std::ostringstream os(std::ios::binary);
			os<<(char)((t1>>0) & 0xff);
			os<<(char)((t1>>8) & 0xff);
			os<<(char)((name.size()>>0) & 0xff);
			os<<(char)((name.size()>>8) & 0xff);
			os<<(char)((name.size()>>16) & 0xff);
			os<<(char)((name.size()>>24) & 0xff);
			os<<name;
			output("core:define_packet_type", os.str(), cb);
		}
	}

	// Create actual packet including type and length
	std::ostringstream os(std::ios::binary);
	os<<(char)((type>>0) & 0xff);
	os<<(char)((type>>8) & 0xff);
	os<<(char)((data.size()>>0) & 0xff);
	os<<(char)((data.size()>>8) & 0xff);
	os<<(char)((data.size()>>16) & 0xff);
	os<<(char)((data.size()>>24) & 0xff);
	os<<data;
	cb(os.str());
}

}
