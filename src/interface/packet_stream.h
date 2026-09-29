// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <functional>
#include <deque>

namespace interface
{
	typedef size_t PacketType;

	struct UnknownPacketReceived: public Exception {
		ss_ msg;
		UnknownPacketReceived(const ss_ &msg): Exception(msg){}
	};

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
			throw UnknownPacketReceived(ss_()+"Packet type not known: "+itos(type));
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
			throw UnknownPacketReceived(ss_()+"Packet not known: "+name);
		}
		ss_ get_name(PacketType type){
			auto it = m_names.find(type);
			if(it != m_names.end())
				return it->second;
			throw UnknownPacketReceived(ss_()+"Packet not known: "+itos(type));
		}
	};

	struct PacketStream
	{
		OutgoingPacketTypeRegistry m_outgoing_types;
		IncomingPacketTypeRegistry m_incoming_types;
		PacketType m_highest_known_type = 99;
		// How much of this stream has been read. Only the error message
		// wants it, and it is what tells a lost type definition from a
		// stream read at the wrong offset: a definition arrives before the
		// first payload that uses it, so an unknown type early is a
		// definition that went missing and one after megabytes of traffic
		// is framing.
		uint64_t m_input_offset = 0;

		// Bulk is sliced ([NET_CHANNELS]): a payload over FRAGMENT_BYTES
		// goes down the wire as core:fragment packets of that size, each
		// carrying the sequence's id, its index and count and the
		// payload's type, and the reader hands the whole back under its
		// own name. What it buys is that a small packet queued behind a
		// megabyte waits one fragment, not the megabyte, once the queue
		// in front of the socket takes it first. On the wire nothing
		// else changes: a payload under the size is what it always was.
		static const size_t FRAGMENT_BYTES = 64 * 1024;
		uint32_t m_next_fragment_id = 1;
		struct Fragments {
			ss_ name;
			size_t count = 0;
			sv_<ss_> parts;
			size_t have = 0;
		};
		sm_<uint32_t, Fragments> m_incoming_fragments;

		PacketStream(){
			m_outgoing_types.set(0, "core:define_packet_type");
			m_incoming_types.set(0, "core:define_packet_type");
			m_outgoing_types.set(1, "core:fragment");
			m_incoming_types.set(1, "core:fragment");
		}

		// budget_us: stop after a packet whose handling took the total
		// over this, leaving the rest in socket_buffer for the caller's
		// next turn; 0 drains everything, which is what it did before
		// there was a budget ([PACKET_STALL]: one update took every
		// buffered packet, and one of them can be 80 ms).
		void input(std::deque<char> &socket_buffer,
				std::function<void(const ss_&name, const ss_&data)> cb,
				int64_t budget_us = 0);

		// The callback is told whether what it is given may be thrown away
		// when a peer is behind: a payload may, and the
		// core:define_packet_type that names a type may never. The type is
		// counted as known as soon as it is written, so a definition
		// dropped is a definition never sent again, and that peer cannot
		// read anything of that type for the rest of the session.
		void output(const ss_ &name, const ss_ &data,
				std::function<void(const ss_&packet_data, bool droppable)> cb,
				bool droppable = true);
	};
}
// vim: set noet ts=4 sw=4:
