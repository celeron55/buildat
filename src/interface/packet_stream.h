// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <functional>
#include <deque>

namespace interface
{
	typedef size_t PacketType;

	struct OutgoingPacketTypeRegistry
	{
		sm_<ss_, PacketType> m_types;
		sm_<PacketType, ss_> m_names;
		PacketType m_next_type = 100;

		void set(PacketType type, const ss_ &name){
			m_types[name] = type;
			m_names[type] = name;
		}
		PacketType get(const ss_ &name){
			auto it = m_types.find(name);
			if(it != m_types.end())
				return it->second;
			PacketType type = m_next_type++;
			m_types[name] = type;
			m_names[type] = name;
			return type;
		}
		ss_ get_name(PacketType type){
			auto it = m_names.find(type);
			if(it != m_names.end())
				return it->second;
			throw Exception(ss_()+"Packet type not known: "+itos(type));
		}
	};

	struct IncomingPacketTypeRegistry
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

	struct PacketStream
	{
		OutgoingPacketTypeRegistry m_outgoing_types;
		IncomingPacketTypeRegistry m_incoming_types;
		PacketType m_highest_known_type = 99;

		PacketStream(){
			m_outgoing_types.set(0, "core:define_packet_type");
			m_incoming_types.set(0, "core:define_packet_type");
		}

		void input(std::deque<char> &socket_buffer,
				std::function<void(const ss_ &name, const ss_ &data)> cb);

		void output(const ss_ &name, const ss_ &data,
				std::function<void(const ss_ &packet_data)> cb);
	};
}
