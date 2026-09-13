// A shim, not Luanti's: see README.txt. The numbers and the shape are
// Luanti's own, and the shape is also buildat's: a voxel word under
// VoxelFormat::luanti() is this struct's three fields in the same order.
#ifndef LUANTI_SHIM_MAPNODE_H
#define LUANTI_SHIM_MAPNODE_H
#include "irrlichttypes_bloated.h"
#include <string>
#include <iosfwd>

// The three reserved content ids. Luanti's own numbers are 125, 126 and 127;
// these are the ids the module reserves instead -- a content id here is a
// buildat VoxelRegistry id, and the registry hands out 0 for "nothing has
// generated this yet", which is what ignore is. They have to be the same
// numbers as core.CONTENT_IGNORE, core.CONTENT_UNKNOWN and core.CONTENT_AIR
// in builtin/luanti/lua/bootstrap.lua, because a mapgen writes air itself
// and the module reads what it wrote; VendoredGenerator's constructor
// checks that they still are.
#define CONTENT_IGNORE 0
#define CONTENT_UNKNOWN 1
#define CONTENT_AIR 2

// What a node's light does, packed into a byte the way Luanti packs it
struct ContentLightingFlags {
	u8 light_source : 4;
	bool has_light : 1;
	bool light_propagates : 1;
	bool sunlight_propagates : 1;

	bool operator==(const ContentLightingFlags &o) const {
		return has_light == o.has_light &&
				light_propagates == o.light_propagates &&
				sunlight_propagates == o.sunlight_propagates &&
				light_source == o.light_source;
	}
	bool operator!=(const ContentLightingFlags &o) const {
		return !(*this == o);
	}
};

// How a node or a schematic is turned, which is Luanti's own enum
enum Rotation {
	ROTATE_0,
	ROTATE_90,
	ROTATE_180,
	ROTATE_270,
	ROTATE_RAND,
};

enum LightBank
{
	LIGHTBANK_DAY,
	LIGHTBANK_NIGHT
};

#define LIGHT_MAX 14
#define LIGHT_SUN 15

struct alignas(u32) MapNode
{
	u16 param0 = CONTENT_IGNORE;
	u8 param1 = 0;
	u8 param2 = 0;

	MapNode() = default;
	constexpr MapNode(content_t content, u8 a_param1 = 0,
			u8 a_param2 = 0) noexcept:
		param0(content), param1(a_param1), param2(a_param2)
	{}

	bool operator==(const MapNode &o) const noexcept {
		return param0 == o.param0 && param1 == o.param1 &&
				param2 == o.param2;
	}
	bool operator!=(const MapNode &o) const noexcept { return !(*this == o); }

	content_t getContent() const noexcept { return param0; }
	void setContent(content_t c) noexcept { param0 = c; }
	u8 getParam1() const noexcept { return param1; }
	void setParam1(u8 p) noexcept { param1 = p; }
	u8 getParam2() const noexcept { return param2; }
	void setParam2(u8 p) noexcept { param2 = p; }

	// A node turned a quarter at a time around the vertical, which is how
	// a schematic is placed one of four ways. What it means depends on the
	// node's param2 kind; this is Luanti's own rule for facedir and
	// wallmounted, and nothing for the rest.
	void rotateAlongYAxis(const class NodeDefManager *nodemgr,
			Rotation rot);

	// Luanti serializes a whole block of these at once; what needs it here
	// is a schematic file, which this build does not read yet. See
	// serialization.h.
	static void deSerializeBulk(std::istream &is, int version,
			MapNode *nodes, u32 nodecount, u8 content_width,
			u8 params_width);
	static std::string serializeBulk(int version, const MapNode *nodes,
			u32 nodecount, u8 content_width, u8 params_width);

	// The light in one bank, which is the nibble it is kept in
	u8 getLight(LightBank bank, ContentLightingFlags f) const noexcept {
		u8 stored = (bank == LIGHTBANK_DAY) ? (param1 & 0x0f) :
				((param1 >> 4) & 0x0f);
		return stored > f.light_source ? stored : f.light_source;
	}
	u8 getLightRaw(LightBank bank, ContentLightingFlags f) const noexcept {
		if(!f.has_light)
			return 0;
		return (bank == LIGHTBANK_DAY) ? (param1 & 0x0f) :
				((param1 >> 4) & 0x0f);
	}
	void setLight(LightBank bank, u8 light, ContentLightingFlags f) noexcept {
		if(!f.has_light)
			return;
		if(bank == LIGHTBANK_DAY)
			param1 = (param1 & 0xf0) | (light & 0x0f);
		else
			param1 = (param1 & 0x0f) | ((light & 0x0f) << 4);
	}
};

#endif
