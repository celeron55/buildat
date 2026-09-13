// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// One Luanti mapblock, as a world's map.sqlite holds it. Read-only and
// one-shot: this is what the importer reads a Luanti world with, and it
// bails on anything it does not recognise rather than guessing.
//
// The format is Luanti's MapBlock::deSerialize, serialization versions 25 to
// 29 -- what every world written since 2013 is in. A block is 16x16x16
// nodes, x fastest and then y and then z, and each node is a content id, a
// param1 and a param2. The content ids are the block's own: every block
// carries the name-id mapping it was written with, which is what makes a
// world readable by a game that registers its nodes in another order.
//
// What hangs off the nodes comes too: the metadata of every node that has
// any, as its fields and its inventory lists. The static objects a block
// holds are walked past -- an imported world starts without its entities,
// which want a static_save that means something here first.
//
// The two shapes, which is the whole of the version difference here:
//
//   25..28  version | flags | [27+: lighting_complete] | widths
//           | zlib(nodes) | zlib(metadata) | static objects | timestamp
//           | name-id mapping | node timers
//   29      version | zstd( flags | lighting_complete | timestamp
//           | name-id mapping | widths | nodes | metadata | ... )
//
// So at 29 everything wanted is in front and the rest of the frame is left
// unread; below it the name-id mapping is at the back and the two streams
// and the static objects in between have to be walked past.
#pragma once
#include "core/types.h"
#include "interface/compress.h"
#include <PolyVoxCore/Vector.h>
#include <sstream>
#include <cstring>

namespace luanti_mapblock
{
	namespace pv = PolyVox;

	static const size_t BLOCK_SIDE = 16;
	static const size_t NODECOUNT = BLOCK_SIDE * BLOCK_SIDE * BLOCK_SIDE;

	// What hangs off one node: a chest's contents, a sign's text
	struct NodeMeta
	{
		sm_<ss_, ss_> fields;
		// List name to the item string in each slot, "" for an empty one
		sm_<ss_, sv_<ss_>> lists;
	};

	struct Block
	{
		uint16_t param0[NODECOUNT];
		uint8_t param1[NODECOUNT];
		uint8_t param2[NODECOUNT];
		// The block's own content ids to the names they stand for
		sm_<uint16_t, ss_> names;
		// Keyed by the index into the block, which is what the format keys
		// it by: x + 16*y + 256*z
		sm_<uint16_t, NodeMeta> meta;
	};

	// A cursor over a string, big-endian, that throws rather than reading
	// past the end
	struct Reader
	{
		const ss_ &s;
		size_t p = 0;

		Reader(const ss_ &s, size_t p = 0): s(s), p(p){}

		void need(size_t n)
		{
			if(p + n > s.size())
				throw Exception("mapblock: ran out of data");
		}
		uint8_t u8()
		{
			need(1);
			return (uint8_t)s[p++];
		}
		uint16_t u16()
		{
			need(2);
			uint16_t v = ((uint8_t)s[p] << 8) | (uint8_t)s[p + 1];
			p += 2;
			return v;
		}
		uint32_t u32()
		{
			need(4);
			uint32_t v = ((uint32_t)(uint8_t)s[p] << 24) |
					((uint32_t)(uint8_t)s[p + 1] << 16) |
					((uint32_t)(uint8_t)s[p + 2] << 8) |
					(uint32_t)(uint8_t)s[p + 3];
			p += 4;
			return v;
		}
		ss_ string16()
		{
			size_t n = u16();
			need(n);
			ss_ v = s.substr(p, n);
			p += n;
			return v;
		}
		ss_ string32()
		{
			size_t n = u32();
			need(n);
			ss_ v = s.substr(p, n);
			p += n;
			return v;
		}
		// Up to the next newline, which is how an inventory is written
		ss_ line()
		{
			size_t end = s.find('\n', p);
			if(end == ss_::npos)
				end = s.size();
			ss_ v = s.substr(p, end - p);
			p = end < s.size() ? end + 1 : s.size();
			if(!v.empty() && v[v.size() - 1] == '\r')
				v.resize(v.size() - 1);
			return v;
		}
		void skip(size_t n)
		{
			need(n);
			p += n;
		}
		ss_ rest() const
		{
			return s.substr(p);
		}
	};

	// u8 version, u16 count, then id and name each
	static void read_name_id_mapping(Reader &r, Block &block)
	{
		uint8_t version = r.u8();
		if(version != 0)
			throw Exception("mapblock: name-id mapping version "+
					itos(version));
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			uint16_t id = r.u16();
			block.names[id] = r.string16();
		}
	}

	// The three arrays, one after the other rather than one node at a time,
	// which is how Luanti writes them
	static void read_nodes(Reader &r, Block &block,
			uint8_t content_width, uint8_t params_width)
	{
		if(content_width != 1 && content_width != 2)
			throw Exception("mapblock: content_width "+itos(content_width));
		if(params_width != 2)
			throw Exception("mapblock: params_width "+itos(params_width));
		r.need(NODECOUNT * (content_width + params_width));
		for(size_t i = 0; i < NODECOUNT; i++)
			block.param0[i] = content_width == 1 ? r.u8() : r.u16();
		for(size_t i = 0; i < NODECOUNT; i++)
			block.param1[i] = r.u8();
		for(size_t i = 0; i < NODECOUNT; i++){
			block.param2[i] = r.u8();
			// The oldest trick in the format: with one byte of content, the
			// ids above 0x7f take four bits of param2 with them
			if(content_width == 1 && block.param0[i] > 0x7f){
				block.param0[i] = (block.param0[i] << 4) |
						((block.param2[i] & 0xf0) >> 4);
				block.param2[i] &= 0x0f;
			}
		}
	}

	// An inventory is lines: "List <name> <size>", then one line per slot,
	// then "EndInventoryList", and "EndInventory" at the end of the lot.
	static void read_inventory(Reader &r, NodeMeta &meta)
	{
		sv_<ss_> *list = nullptr;
		while(r.p < r.s.size()){
			ss_ line = r.line();
			size_t sp = line.find(' ');
			ss_ head = line.substr(0, sp);
			ss_ rest = sp == ss_::npos ? "" : line.substr(sp + 1);
			if(head == "EndInventory" || head == "end")
				return;
			if(head == "List"){
				size_t sp2 = rest.find(' ');
				ss_ name = rest.substr(0, sp2);
				list = &meta.lists[name];
				list->clear();
			} else if(head == "EndInventoryList"){
				list = nullptr;
			} else if(head == "Item" && list){
				list->push_back(rest);
			} else if((head == "Empty" || head == "Keep") && list){
				list->push_back("");
			}
		}
	}

	// The metadata of every node in the block that has any
	static void read_node_metadata(Reader &r, Block &block)
	{
		uint8_t version = r.u8();
		if(version == 0)
			return; // Nothing in this block has any
		if(version > 2)
			throw Exception("mapblock: node metadata version "+itos(version));
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			uint16_t index = r.u16();
			NodeMeta meta;
			uint32_t num_vars = r.u32();
			for(uint32_t j = 0; j < num_vars; j++){
				ss_ name = r.string16();
				ss_ value = r.string32();
				if(version >= 2)
					r.u8(); // private, which is a client-side matter
				meta.fields[name] = value;
			}
			read_inventory(r, meta);
			block.meta[index] = meta;
		}
	}

	// Static objects: what a block holds of the world's entities. Walked
	// past rather than read; see the header.
	static void skip_static_objects(Reader &r)
	{
		r.u8(); // version
		uint16_t count = r.u16();
		for(uint16_t i = 0; i < count; i++){
			r.u8();       // type
			r.skip(12);   // position, as three 1/1000ths
			r.string16(); // the object's own data
		}
	}

	// Everything a zlib stream holds, and where in the data it ended
	static size_t read_zlib_stream(const ss_ &data, size_t begin, ss_ &out)
	{
		std::istringstream is(data.substr(begin), std::ios::binary);
		std::ostringstream os(std::ios::binary);
		interface::decompress_zlib(is, os);
		out = os.str();
		// decompress_zlib ungets what inflate did not take, so tellg is
		// where the stream ended
		std::streampos end = is.tellg();
		if(end < 0)
			throw Exception("mapblock: zlib stream has no end");
		return begin + (size_t)end;
	}

	void deserialize_block(const ss_ &data, Block &block)
	{
		if(data.size() < 2)
			throw Exception("mapblock: two bytes is not a block");
		uint8_t version = (uint8_t)data[0];
		if(version < 25 || version > 29)
			throw Exception("mapblock: serialization version "+itos(version)+
					", and this reads 25 to 29");
		if(version >= 29){
			ss_ raw;
			{
				std::ostringstream os(std::ios::binary);
				interface::decompress_zstd(data.substr(1), os);
				raw = os.str();
			}
			Reader r(raw);
			r.u8();  // flags
			r.u16(); // lighting_complete
			r.u32(); // timestamp
			read_name_id_mapping(r, block);
			uint8_t content_width = r.u8();
			uint8_t params_width = r.u8();
			read_nodes(r, block, content_width, params_width);
			read_node_metadata(r, block);
			return;
		}
		Reader r(data);
		r.u8();  // version
		r.u8();  // flags
		if(version >= 27)
			r.u16(); // lighting_complete
		uint8_t content_width = r.u8();
		uint8_t params_width = r.u8();
		{
			ss_ raw;
			r.p = read_zlib_stream(data, r.p, raw);
			Reader nodes(raw);
			read_nodes(nodes, block, content_width, params_width);
		}
		{
			ss_ raw;
			r.p = read_zlib_stream(data, r.p, raw);
			Reader meta(raw);
			read_node_metadata(meta, block);
		}
		skip_static_objects(r);
		r.u32(); // timestamp
		read_name_id_mapping(r, block);
	}

	// What a map.sqlite row's key is: three twelve-bit coordinates, offset
	// so that the negative ones are non-negative. Luanti's
	// MapDatabase::getIntegerAsBlock.
	pv::Vector3DInt16 block_pos_of_key(int64_t key)
	{
		int64_t i = key + 0x800800800LL;
		return pv::Vector3DInt16(
				(int16_t)((i & 0xfff) - 0x800),
				(int16_t)(((i >> 12) & 0xfff) - 0x800),
				(int16_t)(((i >> 24) & 0xfff) - 0x800));
	}
}
// vim: set noet ts=4 sw=4:
