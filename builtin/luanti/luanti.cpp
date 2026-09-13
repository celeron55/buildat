// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// A Luanti game's own Lua -- its builtin layer and a game's mods -- running
// inside buildat_server. Luanti's network protocol is nowhere in this; the
// game logic is Luanti's and everything around it is buildat's. See
// doc/luanti_module.txt and doc/plan/luanti_module_plan.md.
//
// This file is deliberately thin. Lua 5.1 comes with io and os, so reading
// files, splitting paths and running chunks all happen in Lua; the only
// things C++ has that Lua does not are a directory listing, the log and the
// clock. The arrangement -- what a mod is, what order mods load in, what the
// core table holds -- is in lua/ beside this file, where it can be read.
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include "client_file/api.h"
#include "network/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include "interface/mutex.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/compress.h"
#include "luanti/mapblock.h"
#include <sqlite3.h>
#include <fstream>
#include <sstream>
#include <unordered_map>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
extern "C" {
#include <Lua/lua.h>
#include <Lua/lualib.h>
#include <Lua/lauxlib.h>
}
// Luanti's core.encode_png() is a real function of its API and devtest checks
// what comes out of it, so it is written rather than stubbed. Urho3D ships
// stb_image_write but does not export it, so it is compiled in here; it is
// one header and the only C++ in this file that is not glue.
#include <Scene.h>
#include <Node.h>
#include <StaticModel.h>
#include <Model.h>
#include <Material.h>
#include <ResourceCache.h>
#include <Context.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include <STB/stb_image_write.h>
#define MODULE "luanti"

using interface::Event;
namespace pv = PolyVox;
namespace magic = Urho3D;

namespace luanti {

using main_context::SceneReference;

// A colour for a node that has no texture yet, from its name, so that two
// nodes are two colours and the same node is the same colour between runs.
// M3 replaces every one of these with the node's real tiles; until then a
// world is legible as blocks of colour, which is what M2 has to show.
static void node_colour(const ss_ &name, uint8_t rgb[3])
{
	uint32_t h = 2166136261u;
	for(char c : name){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	// Kept well below white: these are albedo, and a game lighting a scene
	// in HDR with a tone curve over it turns anything near white into a
	// flat blown-out surface. 0.12 to 0.55 is roughly what the hand-drawn
	// voxel textures in this tree sit at.
	rgb[0] = 30 + (h & 0x6f);
	rgb[1] = 30 + ((h >> 8) & 0x6f);
	rgb[2] = 30 + ((h >> 16) & 0x6f);
}

// A media file's name as the client knows it. A namespace of its own, and
// not the module's own "luanti/", because that is where client_file serves a
// module's client_lua from: a game with a texture called module.lua would
// otherwise land on top of this module's client half.
static ss_ media_resource_name(const ss_ &file_name)
{
	return "luanti_media/"+file_name;
}

// A tile that is a texture modifier gets a name of its own, by what it is:
// the same expression in two node definitions is one texture. The client is
// what composes it; see the texmods packet.
static ss_ texmod_resource_name(const ss_ &expr)
{
	uint32_t h = 2166136261u;
	for(char c : expr){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	char buf[48];
	snprintf(buf, sizeof buf, "luanti_texmod/%08x.png", h);
	return buf;
}

static ss_ node_texture_name(const ss_ &name)
{
	uint32_t h = 2166136261u;
	for(char c : name){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	char buf[32];
	snprintf(buf, sizeof buf, "luanti_gen/node_%08x.png", (unsigned)h);
	return buf;
}


// Which way a node faces, out of its param2.
//
// Luanti's own dir_to_tile[24][8] from mapblock_mesh.cpp, read at the
// six directions buildat's faces are in -- +Y, -Y, +X, -X, +Z, -Z, which
// is the order Luanti keeps its tiles in too. Taken from
// extensions/luanti_client/shapes.lua, which read them out first and
// checks them in its engine_test.lua.
//
// This is what VoxelVariant::tile_order and tile_turns are for: the
// twenty-four turns of a facedir are twenty-four variants over one
// definition's six textures, rather than a voxel type per rotation.
// Which of the six tiles each face wears, per facedir
static const uint8_t FACEDIR_TILES[24][6] = {
	{0, 1, 2, 3, 4, 5},
	{0, 1, 4, 5, 3, 2},
	{0, 1, 3, 2, 5, 4},
	{0, 1, 5, 4, 2, 3},
	{5, 4, 2, 3, 0, 1},
	{2, 3, 4, 5, 0, 1},
	{4, 5, 3, 2, 0, 1},
	{3, 2, 5, 4, 0, 1},
	{4, 5, 2, 3, 1, 0},
	{3, 2, 4, 5, 1, 0},
	{5, 4, 3, 2, 1, 0},
	{2, 3, 5, 4, 1, 0},
	{3, 2, 0, 1, 4, 5},
	{5, 4, 0, 1, 3, 2},
	{2, 3, 0, 1, 5, 4},
	{4, 5, 0, 1, 2, 3},
	{2, 3, 1, 0, 4, 5},
	{4, 5, 1, 0, 3, 2},
	{3, 2, 1, 0, 5, 4},
	{5, 4, 1, 0, 2, 3},
	{1, 0, 3, 2, 4, 5},
	{1, 0, 5, 4, 3, 2},
	{1, 0, 2, 3, 5, 4},
	{1, 0, 4, 5, 2, 3},
};

// How far that tile is turned inside its face, in quarter turns
static const uint8_t FACEDIR_TURNS[24][6] = {
	{0, 0, 0, 0, 0, 0},
	{3, 1, 0, 0, 0, 0},
	{2, 2, 0, 0, 0, 0},
	{1, 3, 0, 0, 0, 0},
	{0, 2, 3, 1, 2, 0},
	{0, 2, 3, 1, 1, 1},
	{0, 2, 3, 1, 0, 2},
	{0, 2, 3, 1, 3, 3},
	{2, 0, 1, 3, 2, 0},
	{2, 0, 1, 3, 3, 3},
	{2, 0, 1, 3, 0, 2},
	{2, 0, 1, 3, 1, 1},
	{3, 3, 3, 3, 1, 3},
	{3, 3, 2, 0, 1, 3},
	{3, 3, 1, 1, 1, 3},
	{3, 3, 0, 2, 1, 3},
	{1, 1, 1, 1, 3, 1},
	{1, 1, 2, 0, 3, 1},
	{1, 1, 3, 3, 3, 1},
	{1, 1, 0, 2, 3, 1},
	{2, 2, 2, 2, 2, 2},
	{3, 1, 2, 2, 2, 2},
	{0, 0, 2, 2, 2, 2},
	{1, 3, 2, 2, 2, 2},
};

// The rotation a facedir is, as a matrix, derived from the table above rather
// than from Luanti's handedness conventions: FACEDIR_TILES[d][f] says world
// face f wears the tile of local face s, which means the rotation takes the
// local face s to the world direction of f. Three of those give the columns,
// and check_shapes() asserts that what comes out is a proper rotation.
//
// out[r][c], so that out * v is the rotated v.
static void facedir_matrix(uint8_t d, int out[3][3])
{
	// Face f points this way: +Y, -Y, +X, -X, +Z, -Z
	static const int FACE_DIR[6][3] = {
		{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
		{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
	};
	// Local face 2 is +X, 0 is +Y and 4 is +Z, so those three give the
	// columns of the matrix
	static const uint8_t AXIS_FACE[3] = {2, 0, 4};
	for(size_t c = 0; c < 3; c++){
		const uint8_t s = AXIS_FACE[c];
		for(size_t f = 0; f < 6; f++){
			if(FACEDIR_TILES[d][f] != s)
				continue;
			for(size_t r = 0; r < 3; r++)
				out[r][c] = FACE_DIR[f][r];
			break;
		}
	}
}

// A shape turned the way a facedir turns it. The quads keep the tiles they
// name -- a quad's texture is the local face it was built on, and that
// travels with it -- so only the corners move.
//
// simplified: the texture is not turned inside the quad. tile_turns is what
// does that for a cube's faces and the mesher does not apply it to a shape's
// quads, so a turned node box wears its textures straight.
static void turn_quads(const sv_<interface::VoxelQuad> &in, uint8_t d,
		sv_<interface::VoxelQuad> &out)
{
	int m[3][3] = {};
	facedir_matrix(d, m);
	out = in;
	for(interface::VoxelQuad &q : out){
		for(size_t i = 0; i < 4; i++){
			const float x = q.p[i][0], y = q.p[i][1], z = q.p[i][2];
			for(size_t r = 0; r < 3; r++)
				q.p[i][r] = (float)(m[r][0] * x + m[r][1] * y + m[r][2] * z);
		}
	}
}

// One point turned a quarter at a time in the plane of two of its axes, and
// the same by an arbitrary angle. Irrlicht's rotateXZBy and friends, which is
// all Luanti's own node shapes turn by.
static void turn_quarters(float v[3], int ia, int ib, int quarters)
{
	static const float SIN[4] = {0, 1, 0, -1};
	static const float COS[4] = {1, 0, -1, 0};
	const int i = ((quarters % 4) + 4) % 4;
	const float a = v[ia], b = v[ib];
	v[ia] = COS[i] * a - SIN[i] * b;
	v[ib] = SIN[i] * a + COS[i] * b;
}

static void turn_degrees(float v[3], int ia, int ib, float deg)
{
	// Not M_PI: the module compile has Urho3D's own M_PI in scope
	const float r = deg * 3.14159265358979323846f / 180.0f;
	const float s = std::sin(r), c = std::cos(r);
	const float a = v[ia], b = v[ib];
	v[ia] = c * a - s * b;
	v[ib] = s * a + c * b;
}

// How far the single quad of a sign or a torch is turned for each wall
// direction, in quarters. It starts against +X; Luanti's drawSignlikeNode
// and drawTorchlikeNode.
static int wall_quad_turn(size_t wall)
{
	switch(wall){
	case 2: return 0;
	case 3: return 2;
	case 4: return 1;
	case 5: return -1;
	default: return 0;
	}
}

// A rail's tile and turn per mask of its four horizontal connections, which
// is Luanti's own rail_kinds table from content_mapblock.cpp: a rail with
// nothing or one thing beside it is straight, two opposite ones straight, two
// beside each other a curve, three a junction and four a crossing. The tiles
// are the node's first four in that order, and what turns is the quad rather
// than the texture, which is what Luanti turns too.
//
// The mask's bits are Luanti's own for this: +Z is 1, -Z is 2, -X is 4 and
// +X is 8. Taken from extensions/luanti_client/shapes.lua.
struct RailKind { uint8_t tile; int degrees; };
static const RailKind RAIL_KINDS[16] = {
	{0, 0}, {0, 0}, {0, 0}, {0, 0},
	{0, 90}, {1, 180}, {1, 270}, {2, 180},
	{0, 90}, {1, 90}, {1, 0}, {2, 0},
	{0, 90}, {2, 90}, {2, 270}, {3, 0},
};

// And the turn of a rail that climbs towards one of the four, in the order
// the masks 16...19 are in: +Z, -Z, -X, +X. Luanti's rail_slope_angle.
static const int RAIL_SLOPE_TURNS[4] = {0, 180, 90, -90};

// One family for every fence, because a fence reaches any other fence
// whatever kind it is -- which is Luanti's rule for them. Rails will want one
// per raillike group when they arrive; see connect_group in
// interface/voxel.h, which has thirty-two.
static const uint8_t FENCE_CONNECT_GROUP = 1;

// A wallmounted direction is a facedir too; Luanti's own
// wallmounted_to_facedir[]. 6 and 7 are the two spare states, which are
// the ceiling and the floor turned a quarter.
static const uint8_t WALLMOUNTED_FACEDIR[8] = {20, 0, 17, 15, 8, 6, 21, 1};

// How many variants a kind of facing needs, and which one a param2 picks.
// The colour* kinds put a palette index in the high bits and the
// direction in the same low ones, so they are the same lookup; see
// Luanti's MapNode::getFaceDir.
static size_t facing_variant_count(const ss_ &facing)
{
	if(facing == "facedir")
		return 24;
	if(facing == "4dir")
		return 4;
	if(facing == "wallmounted")
		return 8;
	return 0;
}

static uint8_t facing_variant_of_param(const ss_ &facing, uint8_t param)
{
	if(facing == "facedir")
		return (uint8_t)((param & 0x1f) % 24);
	if(facing == "4dir")
		return (uint8_t)(param & 0x03);
	if(facing == "wallmounted")
		return (uint8_t)(param & 0x07);
	return 0;
}

// The facedir a variant of this kind stands for
static uint8_t facing_facedir(const ss_ &facing, size_t variant)
{
	if(facing == "wallmounted")
		return WALLMOUNTED_FACEDIR[variant & 7];
	return (uint8_t)(variant % 24);
}


// The Lua state's own log lines land here, so a mod's core.log() is a buildat
// log line with the mod's level
static void log_from_lua(const ss_ &level, const ss_ &text)
{
	if(level == "error")
		log_e(MODULE, "%s", cs(text));
	else if(level == "warning")
		log_w(MODULE, "%s", cs(text));
	else if(level == "verbose" || level == "debug" || level == "deprecated")
		log_v(MODULE, "%s", cs(text));
	else
		log_i(MODULE, "%s", cs(text));
}

static int l_log(lua_State *L)
{
	ss_ level = "action";
	ss_ text;
	if(lua_gettop(L) >= 2){
		level = lua_tostring(L, 1) ? lua_tostring(L, 1) : "action";
		text = lua_tostring(L, 2) ? lua_tostring(L, 2) : "";
	} else {
		text = lua_tostring(L, 1) ? lua_tostring(L, 1) : "";
	}
	log_from_lua(level, text);
	return 0;
}

static int l_get_us_time(lua_State *L)
{
	lua_pushnumber(L, (lua_Number)interface::os::time_us());
	return 1;
}

// The one thing Lua 5.1 cannot do for itself. Returns an array of
// {name=..., is_directory=...}, or an empty array for a path that is not a
// directory -- a caller that cares checks with io.open first.
static int l_list_dir(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	lua_newtable(L);
	int i = 1;
	try {
		for(const interface::fs::Node &n : interface::fs::list_directory(path)){
			if(n.name == "." || n.name == "..")
				continue;
			lua_newtable(L);
			lua_pushstring(L, n.name.c_str());
			lua_setfield(L, -2, "name");
			lua_pushboolean(L, n.is_directory);
			lua_setfield(L, -2, "is_directory");
			lua_rawseti(L, -2, i++);
		}
	} catch(...){
		// A path that is not there is an empty listing, which is what every
		// caller here wants
	}
	return 1;
}

static int l_create_directories(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	lua_pushboolean(L, interface::fs::create_directories(path));
	return 1;
}

// (width, height, components, pixel bytes) -> a PNG. The caller decided how
// many components the image wants; see core.encode_png in lua/png.lua.
static void png_write_cb(void *context, void *data, int size)
{
	ss_ *out = (ss_*)context;
	out->append((const char*)data, size);
}

// core.sha1(data, raw) and core.sha256(data, raw): the digest as hex unless
// the raw bytes are asked for. Luanti has both and mods hash with them.
static int l_sha1(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ raw = interface::sha1::calculate(ss_(p, n));
	if(lua_toboolean(L, 2)){
		lua_pushlstring(L, raw.c_str(), raw.size());
		return 1;
	}
	ss_ hex = interface::sha1::hex(raw);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

static int l_sha256(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ raw = interface::sha256::calculate(ss_(p, n));
	if(lua_toboolean(L, 2)){
		lua_pushlstring(L, raw.c_str(), raw.size());
		return 1;
	}
	ss_ hex = interface::sha256::hex(raw);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

// core.compress(data, method, level) and core.decompress(data, method), with
// the three methods Luanti has: "deflate" is zlib's own framing,
// "raw_deflate" the same stream without it, and "zstd" what a mapblock is in.
static int l_compress(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ data(p, n);
	ss_ method = luaL_optstring(L, 2, "deflate");
	int level = (int)luaL_optinteger(L, 3, method == "zstd" ? 3 : 6);
	std::ostringstream os(std::ios::binary);
	try {
		if(method == "deflate")
			interface::compress_zlib(data, os, level);
		else if(method == "raw_deflate")
			interface::compress_deflate_raw(data, os, level);
		else if(method == "zstd")
			interface::compress_zstd(data, os, level);
		else
			return luaL_error(L, "compress(): no such method: %s",
					method.c_str());
	} catch(std::exception &e){
		return luaL_error(L, "compress(): %s", e.what());
	}
	ss_ out = os.str();
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

static int l_decompress(lua_State *L)
{
	size_t n = 0;
	const char *p = luaL_checklstring(L, 1, &n);
	ss_ data(p, n);
	ss_ method = luaL_optstring(L, 2, "deflate");
	std::ostringstream os(std::ios::binary);
	try {
		if(method == "zstd"){
			interface::decompress_zstd(data, os);
		} else {
			std::istringstream is(data, std::ios::binary);
			if(method == "deflate")
				interface::decompress_zlib(is, os);
			else if(method == "raw_deflate")
				interface::decompress_deflate_raw(is, os);
			else
				return luaL_error(L, "decompress(): no such method: %s",
						method.c_str());
		}
	} catch(std::exception &e){
		return luaL_error(L, "decompress(): %s", e.what());
	}
	ss_ out = os.str();
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

static int l_encode_png(lua_State *L)
{
	int w = luaL_checkinteger(L, 1);
	int h = luaL_checkinteger(L, 2);
	int components = luaL_checkinteger(L, 3);
	size_t data_len = 0;
	const char *data = luaL_checklstring(L, 4, &data_len);
	if(w <= 0 || h <= 0 || components < 1 || components > 4)
		return luaL_error(L, "encode_png: bad size or component count");
	if(data_len != (size_t)w * (size_t)h * (size_t)components)
		return luaL_error(L, "encode_png: %d bytes for %dx%dx%d",
				(int)data_len, w, h, components);
	ss_ out;
	if(!stbi_write_png_to_func(png_write_cb, &out, w, h, components,
			data, w * components))
		return luaL_error(L, "encode_png: failed");
	lua_pushlstring(L, out.c_str(), out.size());
	return 1;
}

// What a traceback is added by; lua_pcall's error handler
static int l_traceback(lua_State *L)
{
	const char *msg = lua_tostring(L, 1);
	lua_getglobal(L, "debug");
	lua_getfield(L, -1, "traceback");
	lua_remove(L, -2);
	lua_pushstring(L, msg ? msg : "(non-string error)");
	lua_pushinteger(L, 2);
	lua_call(L, 2, 1);
	return 1;
}

// 21 bits each, which covers Luanti's +-31000 map many times over
static int64_t pos_key(int32_t x, int32_t y, int32_t z)
{
	return ((int64_t)(x & 0x1fffff) << 42) |
			((int64_t)(y & 0x1fffff) << 21) |
			((int64_t)(z & 0x1fffff));
}

struct Module: public interface::Module, public luanti::Interface
{
	interface::Server *m_server;
	lua_State *m_lua = nullptr;
	// Two of this module's handlers can be inside Lua at once: a queued
	// core:tick runs on the module's own thread while core:shutdown is
	// emitted synchronously from another, and the server does not serialise
	// the two. One lua_State under two threads is a crash, and a step that
	// does real work -- the ABM sweep -- is long enough to hit it every
	// time. Everything that enters Lua takes this first.
	//
	// simplified: the engine is what should serialise a module's handlers,
	// and then this would be unnecessary. It is one mutex here against a
	// change to how every module is called; see ModuleThread::handle_event
	// in src/server/state.cpp, which takes no lock where emit_event_sync
	// takes the container's.
	interface::Mutex m_lua_mutex;
	// What the importer resolved a Luanti node name to, so that a world of
	// three hundred thousand blocks asks Lua once per name and not once per
	// node
	sm_<ss_, std::pair<uint32_t, bool>> m_import_ids;
	// The voxel a generated section is filled with; see
	// on_generation_request(). Zero until the first section is generated,
	// which is after the mods have loaded and named it.
	uint32_t m_singlenode_word = 0;
	// The texture modifier expressions the game's nodes are drawn with, by
	// the resource name each is composed under. The client is what composes
	// them; this is what it is sent when it asks.
	sm_<ss_, ss_> m_texmods;
	// Whether the save has node metadata in it, so that a world that has
	// none does not get a blob written for it every shutdown
	bool m_had_node_meta = false;
	// The same for the players; a world nobody has been in stays that way
	bool m_had_players = false;
	// Which client a player is, so that what is sent to one has somewhere to
	// go, and which player a client is, for what comes back. Whoever names a
	// player says which peer it is; see add_player().
	sm_<ss_, size_t> m_player_peers;
	sm_<size_t, ss_> m_peer_players;
	bool m_game_running = false;
	// What load_lua() was handed before run_game(), in the order it came
	sv_<std::pair<ss_, ss_>> m_pending_lua;

	// The map. One voxelworld instance, in a scene of this module's own: the
	// module is what knows the Luanti world's shape, its node ids and its
	// light, so it is what owns them. The launcher is told about the scene by
	// luanti:game_loaded.
	SceneReference m_scene = nullptr;
	// The save the world is. Opened by whoever called run_game(), and theirs
	// to close; the store is this module's own namespace in it, holding what
	// is not the map -- the clock so far.
	storage::Save *m_save = nullptr;
	storage::Store *m_store = nullptr;
	// The world's bounds in sections. A section is voxelworld's load and
	// unload unit and sixty-four voxels a side; Luanti's map limit is 31000
	// voxels in every direction, which is this many of them. Nothing outside
	// is ever loaded and the sky is above the top of it -- what is loaded is
	// what the load points below keep, which is far less.
	static const int32_t MAP_LIMIT_SECTIONS = 484;
	pv::Region m_section_region{
			pv::Vector3DInt32(-MAP_LIMIT_SECTIONS, -MAP_LIMIT_SECTIONS,
					-MAP_LIMIT_SECTIONS),
			pv::Vector3DInt32(MAP_LIMIT_SECTIONS, MAP_LIMIT_SECTIONS,
					MAP_LIMIT_SECTIONS)};
	// Luanti's three ranges, in the same descending order and for the same
	// reasons, in sections rather than its blocks of sixteen voxels:
	// max_block_send_distance (12 blocks) is the client's own and capped by
	// the load radius, max_block_generate_distance (10) is what is filled,
	// and active_block_range (4 blocks, which is exactly one section) is
	// what the ABM and LBM sweeps touch.
	static const int16_t LOAD_RADIUS_XZ = 3;
	static const int16_t LOAD_RADIUS_Y = 2;
	static const int16_t GENERATE_RADIUS_XZ = 2;
	static const int16_t GENERATE_RADIUS_Y = 1;
	static const int32_t ACTIVE_RADIUS = 1;
	// The world around the origin, which is where a mod puts things while
	// the game loads and where a player with nowhere else to be spawns. It
	// is what the world was in its entirety before it streamed.
	static const int16_t SPAWN_RADIUS = 1;
	// Where each player is, in voxels. Written by set_player_pos() a few
	// times a second and read once a step; it is what the world streams
	// around, and what says which sections are active.
	sm_<ss_, pv::Vector3DInt32> m_player_pos;
	pv::Vector3DInt16 m_section_size{0, 0, 0};
	// The media file names the game shipped, so that a tile naming one can
	// be handed to the client as it is
	set_<ss_> m_served_media;
	// See glass_edge_material()
	sm_<ss_, interface::EdgeMaterialId> m_glass_edge_materials;
	uint32_t m_next_glass_edge_material = 10;
	bool m_glass_edge_materials_exhausted = false;
	// See rail_connect_group()
	sm_<int, uint8_t> m_rail_connect_groups;
	uint32_t m_next_rail_connect_group = FENCE_CONNECT_GROUP + 1;
	bool m_rail_connect_groups_exhausted = false;
	// See liquid_shape_group()
	sm_<ss_, uint8_t> m_liquid_shape_groups;
	uint32_t m_next_liquid_shape_group = 1;
	bool m_liquid_shape_groups_exhausted = false;

	// The write-behind buffer. core.set_node writes here and voxelworld sees
	// it once per Luanti step, inside a single access() -- one commit covers
	// every chunk the step touched, instead of a skylight pass and a 32^3
	// serialize-and-replicate per node placed. core.get_node reads through
	// it, because Luanti's semantics are that a write is visible immediately
	// and the callbacks in the same step will look.
	struct PendingNode { int32_t x, y, z; uint32_t word; };
	std::unordered_map<int64_t, PendingNode> m_node_writes;

	// Luanti steps at dedicated_server_step (0.09 s), buildat ticks at 30 Hz;
	// a mod's globalstep dtime is written against the former
	static constexpr float STEP_S = 0.09f;
	float m_step_accum = 0.0f;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		if(m_lua)
			lua_close(m_lua);
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("voxelworld:generation_request"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_texmods"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_images"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_object_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:fields"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:inv_action"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("voxelworld:generation_request", on_generation_request,
				voxelworld::GenerationRequest)
		EVENT_TYPEN("network:packet_received/luanti:get_texmods",
				on_get_texmods, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_item_images",
				on_get_item_images, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_object_props",
				on_get_object_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:fields",
				on_fields, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:inv_action",
				on_inv_action, network::Packet)
	}

	void on_start(){}
	void on_unload(){}
	void on_continue(){}

	// The last node writes and the clock. voxelworld has a core:shutdown
	// handler of its own and may have run it already -- subscribers are
	// called in the order the modules were loaded -- so this asks the world
	// to save rather than trusting that it has not saved yet. Asking twice
	// costs nothing: a section that has not changed is not written.
	void on_shutdown()
	{
		if(!m_game_running)
			return;
		flush_node_writes();
		save_clock();
		save_node_meta();
		save_players();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->save();
		});
	}

	// The clock, in the save's object store beside the map: a world put down
	// at dusk is picked up at dusk. Luanti keeps the same three numbers in
	// its env_meta.txt.
	//
	// simplified: written at shutdown and not before, so a server that is
	// killed loses the day it was on. Luanti writes its own every 5.3
	// seconds with the map; the upgrade path is to do the same, once
	// anything else here is worth a periodic checkpoint.
	void load_clock()
	{
		if(!m_store)
			return;
		ss_ data;
		if(!m_store->get("clock", data))
			return;
		double time_of_day = 0.5, game_time = 0.0;
		int32_t day_count = 0;
		{
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			uint8_t version = 0;
			ar(version);
			if(version != 1){
				log_w(MODULE, "The save's clock is version %i and this build "
						"writes 1; the world starts at noon", (int)version);
				return;
			}
			ar(time_of_day, game_time, day_count);
		}
		lua_State *L = m_lua;
		interface::MutexScope ms(m_lua_mutex);
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__set_clock");
		lua_pushnumber(L, time_of_day);
		lua_pushnumber(L, game_time);
		lua_pushnumber(L, day_count);
		if(lua_pcall(L, 3, 0, 0) != 0)
			log_w(MODULE, "__set_clock(): %s", lua_tostring(L, -1));
		lua_settop(L, base);
		log_v(MODULE, "Clock read from the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}

	// Step 5c of doc/plan/world_persistence_plan.md: what hangs off the
	// voxels -- a chest's contents, a sign's text -- goes into the save
	// beside the clock. One blob, because the world is the sections a mod
	// can reach; lua/bootstrap.lua names the upgrade path where it builds it.
	void save_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__save_node_meta");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "__save_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		ss_ data = lua_tostring(L, -2) ? lua_tostring(L, -2) : "";
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		if(n == 0 && !m_had_node_meta)
			return; // Nothing to write and nothing there to clear
		m_had_node_meta = (n != 0);
		m_store->set("node_meta", data);
		log_v(MODULE, "Node metadata written to the save: %i positions", n);
	}

	void load_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data))
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_node_meta");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		m_had_node_meta = (n != 0);
		log_v(MODULE, "Node metadata read from the save: %i positions", n);
	}

	// The players, in the save beside the node metadata and written the same
	// way: what a player carries is item strings as well. lua/entity.lua says
	// what one row is.
	void save_players()
	{
		if(!m_store || !m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__save_players");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "__save_players(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		ss_ data(p ? p : "", p ? len : 0);
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		if(n == 0 && !m_had_players)
			return; // Nothing to write and nothing there to clear
		m_had_players = (n != 0);
		m_store->set("players", data);
		log_v(MODULE, "Players written to the save: %i", n);
	}

	void load_players()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("players", data))
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__load_players");
		lua_pushlstring(L, data.c_str(), data.size());
		if(lua_pcall(L, 1, 1, 0) != 0){
			log_w(MODULE, "__load_players(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		m_had_players = (n != 0);
		log_v(MODULE, "Players read from the save: %i", n);
	}

	void save_clock()
	{
		if(!m_store || !m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__get_clock");
		if(lua_pcall(L, 0, 3, 0) != 0){
			log_w(MODULE, "__get_clock(): %s", lua_tostring(L, -1));
			lua_settop(L, base);
			return;
		}
		double time_of_day = lua_tonumber(L, -3);
		double game_time = lua_tonumber(L, -2);
		int32_t day_count = (int32_t)lua_tonumber(L, -1);
		lua_settop(L, base);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar((uint8_t)1, time_of_day, game_time, day_count);
		}
		m_store->set("clock", os.str());
		log_v(MODULE, "Clock written to the save: day %i, time %.4f, "
				"%.0f seconds played", (int)day_count, time_of_day, game_time);
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_game_running)
			return;
		m_step_accum += event.dtime;
		if(m_step_accum < STEP_S)
			return;
		m_step_accum = 0.0f;
		update_load_points();
		step_environment();
		flush_node_writes();
	}

	// One Luanti step: the clock now, the globalsteps and core.after later
	void step_environment()
	{
		char buf[64];
		snprintf(buf, sizeof buf, "core.__step(%f)", (double)STEP_S);
		try {
			run_chunk_string(buf, "step");
		} catch(Exception &e){
			log_w(MODULE, "step: %s", e.what());
		}
	}

	// The map

	// Floor division, because a section boundary is not at zero and C's
	// division rounds towards it
	static int32_t floordiv(int32_t a, int32_t b)
	{
		return (a >= 0) ? (a / b) : -((-a + b - 1) / b);
	}

	pv::Vector3DInt16 section_of(const pv::Vector3DInt32 &p)
	{
		if(m_section_size.getX() <= 0)
			return pv::Vector3DInt16(0, 0, 0);
		return pv::Vector3DInt16(
				(int16_t)floordiv(p.getX(), m_section_size.getX()),
				(int16_t)floordiv(p.getY(), m_section_size.getY()),
				(int16_t)floordiv(p.getZ(), m_section_size.getZ()));
	}

	// Where the world stays loaded: every player, and the origin whether or
	// not anybody is there. A player's point is tagged with their peer,
	// which is what makes it the point the world is sent to them from.
	void update_load_points()
	{
		if(!m_scene)
			return;
		sv_<voxelworld::LoadPoint> points;
		points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(0, 0, 0),
				SPAWN_RADIUS, SPAWN_RADIUS, SPAWN_RADIUS, SPAWN_RADIUS));
		for(const auto &pair : m_player_pos){
			size_t peer = 0;
			auto it = m_player_peers.find(pair.first);
			if(it != m_player_peers.end())
				peer = it->second;
			points.push_back(voxelworld::LoadPoint(pair.second,
					LOAD_RADIUS_XZ, LOAD_RADIUS_Y,
					GENERATE_RADIUS_XZ, GENERATE_RADIUS_Y, peer));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_load_points(points);
		});
	}

	// The active range is a section around a player and nothing where there
	// is none, which is what stops a furnace on the other side of the world
	// from firing into a section nobody has loaded
	void check_active_range()
	{
		sm_<ss_, pv::Vector3DInt32> saved;
		saved.swap(m_player_pos);
		assert(!is_section_active(pv::Vector3DInt16(0, 0, 0)));
		m_player_pos["__check"] = pv::Vector3DInt32(0, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(0, 0, 0)));
		assert(is_section_active(pv::Vector3DInt16(1, 0, -1)));
		assert(!is_section_active(pv::Vector3DInt16(2, 0, 0)));
		// A player one voxel the other side of a boundary is in the section
		// that side of it, and the range goes with them
		m_player_pos["__check"] = pv::Vector3DInt32(-1, 0, 0);
		assert(is_section_active(pv::Vector3DInt16(-2, 0, 0)));
		assert(!is_section_active(pv::Vector3DInt16(1, 0, 0)));
		m_player_pos = saved;
		log_v(MODULE, "check_active_range: the range is where the players are");
	}

	// Luanti's active_block_range: what is near a player is what steps.
	// Nobody near it means nothing runs in it, which is Luanti's answer too
	// -- a world with no players in it is a world where nothing happens.
	bool is_section_active(const pv::Vector3DInt16 &section_p)
	{
		for(const auto &pair : m_player_pos){
			pv::Vector3DInt16 c = section_of(pair.second);
			if(std::abs((int32_t)section_p.getX() - c.getX()) <= ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getY() - c.getY()) <= ACTIVE_RADIUS &&
					std::abs((int32_t)section_p.getZ() - c.getZ()) <= ACTIVE_RADIUS)
				return true;
		}
		return false;
	}

	void flush_node_writes()
	{
		if(m_node_writes.empty() || !m_scene)
			return;
		size_t n = m_node_writes.size();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// set_voxel() into a section that is not there does nothing and
			// says so in a warning. Luanti's set_node emerges the block it
			// writes into, so this does too -- and in a singlenode world
			// "generate" means nobody answers the request, which is what
			// makes the world void.
			pv::Vector3DInt16 size = world->get_section_size_voxels();
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				pv::Vector3DInt16 section_p(
						floordiv(node.x, size.getX()),
						floordiv(node.y, size.getY()),
						floordiv(node.z, size.getZ()));
				if(!world->is_section_loaded(section_p))
					world->load_or_generate_section(section_p);
			}
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				world->set_voxel(pv::Vector3DInt32(node.x, node.y, node.z),
						interface::VoxelInstance(node.word), true);
			}
		});
		m_node_writes.clear();
		log_d(MODULE, "Flushed %zu node writes", n);
	}

	void buffer_node_write(int32_t x, int32_t y, int32_t z, uint32_t word)
	{
		PendingNode node;
		node.x = x;
		node.y = y;
		node.z = z;
		node.word = word;
		m_node_writes[pos_key(x, y, z)] = node;
	}

	// A read that misses the buffer takes one voxelworld access(), which
	// commits on the way out. commit() is cheap with nothing dirty, but it
	// is not free; what reads a box reads it with read_region() below.
	uint32_t read_node(int32_t x, int32_t y, int32_t z)
	{
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end())
			return it->second.word;
		if(!m_scene)
			return 0;
		uint32_t word = 0;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			word = world->get_voxel(pv::Vector3DInt32(x, y, z), true).data;
		});
		return word;
	}

	// Luanti's own cap on how much map a call may look at in one go
	// (MAX_WORKING_VOLUME). A mod asking for more than this has made a
	// mistake, and quietly building a table of that many numbers is not the
	// way to tell it so.
	static const size_t MAX_REGION_VOXELS = 4096000;

	// A box of voxel words in one access(), x fastest and then y and then z.
	//
	// This is what the region reads are for. Written a voxel at a time in
	// Lua they took one access_module() each -- a module lock acquired and
	// the lock hierarchy validated per voxel, 125 of them for a 5x5x5 box --
	// and the work inside voxelworld was nearly free by comparison, since
	// the commit on the way out early-outs with nothing dirty.
	void read_region(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		size_t w = (size_t)(x1 - x0 + 1);
		size_t h = (size_t)(y1 - y0 + 1);
		size_t d = (size_t)(z1 - z0 + 1);
		out.assign(w * h * d, 0);
		if(!m_scene)
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// One read for the box rather than one per voxel: what asks for
			// this is a sweep -- an ABM, a find_nodes_in_area -- and the
			// difference is a clip per chunk against a section and buffer
			// lookup per voxel
			interface::VoxelVolume vol = world->get_volume(pv::Region(
					pv::Vector3DInt32(x0, y0, z0),
					pv::Vector3DInt32(x1, y1, z1)));
			interface::VoxelVolume::Sampler src(&vol);
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++){
				for(int32_t y = y0; y <= y1; y++){
					src.setPosition(x0, y, z);
					for(int32_t x = x0; x <= x1; x++, src.movePositiveX()){
						out[i++] = src.getVoxel().data;
					}
				}
			}
		});
		// What has been written and not flushed is not in voxelworld yet, so
		// it goes over the top -- the same order read_node() reads in. The
		// buffer is emptied every Luanti step, so sweeping it is cheaper
		// than a lookup per voxel of the box.
		for(const auto &pair : m_node_writes){
			const PendingNode &n = pair.second;
			if(n.x < x0 || n.x > x1 || n.y < y0 || n.y > y1 ||
					n.z < z0 || n.z > z1)
				continue;
			out[(size_t)(n.x - x0) + (size_t)(n.y - y0) * w +
					(size_t)(n.z - z0) * w * h] = n.word;
		}
	}

	// Lua

	ss_ module_path()
	{
		return m_server->get_module_path(MODULE);
	}

	// core.get_cache_path(): buildat's own cache, never the user's Luanti
	// install. The games and worlds themselves are under the user path; see
	// games/luanti_launcher.
	ss_ luanti_cache_path()
	{
		return m_server->get_config().get<ss_>("cache_path")+"/luanti";
	}

	void run_chunk_file(const ss_ &path)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadfile(L, path.c_str()) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: cannot load "+path+": "+err);
		}
		if(lua_pcall(L, 0, 0, base + 1) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: error in "+path+":\n"+err);
		}
		lua_settop(L, base);
	}

	void run_chunk_string(const ss_ &chunk, const ss_ &chunkname)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadbuffer(L, chunk.c_str(), chunk.size(),
				chunkname.c_str()) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: cannot load "+chunkname+": "+err);
		}
		if(lua_pcall(L, 0, 0, base + 1) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: error in "+chunkname+":\n"+err);
		}
		lua_settop(L, base);
	}

	void set_global_string(const char *name, const ss_ &value)
	{
		lua_pushstring(m_lua, value.c_str());
		lua_setglobal(m_lua, name);
	}

	void set_global_cfunction(const char *name, lua_CFunction f)
	{
		lua_pushcfunction(m_lua, f);
		lua_setglobal(m_lua, name);
	}

	// The world
	//
	// Built after the mods have loaded, because add_voxel() takes a finished
	// definition and hands out ids in call order -- so the definitions have
	// to be made in one pass in content id order, and only the final
	// core.registered_nodes is ever looked at. That is also what makes
	// core.override_item and core.unregister_item non-issues here.

	void create_world()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});

		// Singlenode: nothing generates anything, so the world is void and
		// the only nodes in it are the ones a mod places. The region is the
		// map's limits; what is loaded of it is what the load points keep.
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			iv->create_instance(m_scene, m_section_region);
		});

		// Before voxelworld's first tick, which is when a world that has
		// said nothing gets its whole region created
		update_load_points();

		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			// Luanti's cut of the voxel word: a 16-bit node id, param1 as
			// two light nibbles, param2 above them. Nothing is packed by
			// hand anywhere in this module because of this line.
			reg->set_format(interface::VoxelFormat::luanti());
			build_voxel_registry(reg);
			// After the registry and before anything asks for a section: the
			// save stores node names and the run owns the numbering, so the
			// content ids the mods asked for while loading are the ids this
			// run uses whatever a previous one did. See
			// doc/plan/world_persistence_plan.md.
			world->set_save(m_save, "main");
			m_section_size = world->get_section_size_voxels();
		});

		// Singlenode is a node everywhere, and this is where it is put.
		// Before the skylight is on: what the fill writes is a world of lit
		// air, and every voxel of it changing from nothing to air with the
		// light running would be a skylight seed -- seven million of them,
		// and eight seconds of startup to settle what the fill already
		// knows.
		generate_world();

		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			// The light is voxelworld's, so core.get_node_light is a read
			// and not a second store
			world->set_skylight_enabled(true);
		});

		check_active_range();
	}

	// The client half asks for these once it has loaded, rather than being
	// sent them when it connects: a packet that arrives before the script
	// that subscribes to it has nowhere to go.
	void on_get_texmods(const network::Packet &packet)
	{
		sv_<ss_> flat;
		flat.reserve(m_texmods.size() * 2);
		for(const auto &pair : m_texmods){
			flat.push_back(pair.first);
			flat.push_back(pair.second);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:texmods", os.str());
		});
		log_v(MODULE, "C%zu: %zu texture modifiers", (size_t)packet.sender,
				m_texmods.size());
	}

	// The mapgen, which at singlenode is one node everywhere: Luanti's own
	// MapgenSinglenode fills a generated block with whatever
	// "mapgen_singlenode" names, or with air when a game does not name one,
	// and sets the sunlight. So a generated section here is air as well --
	// what a mod reads out of a part of the world nobody has built in is
	// "air" and not "ignore", which is what every mod that looks before it
	// places is written against.
	//
	// merge_volume() and not set_volume(): this is a generator, and the
	// priorities in voxelworld's api.h are exactly what a generator wants --
	// anything a mod has already put there stays.
	//
	// simplified: the section is filled at once rather than a chunk at a
	// time as voxelworld asks, because a singlenode section is one word
	// repeated and the whole of it costs a few milliseconds. A real mapgen
	// is the milestone where that stops being true.
	uint32_t singlenode_word()
	{
		if(m_singlenode_word == 0){
			bool known = false;
			uint32_t id = import_content_id("mapgen_singlenode", known);
			if(!known)
				id = import_content_id("air", known);
			const interface::VoxelFormat f = interface::VoxelFormat::luanti();
			uint32_t word = 0;
			f.id.set(word, id);
			// Lit, because a world with nothing in it is a world the sky
			// reaches everywhere in -- and because this is written before
			// voxelworld's skylight is turned on, so nothing else will put
			// the light there. Luanti's MapgenSinglenode sets the same
			// sunlight for the same reason.
			f.light_sky.set(word, f.light_sky.mask());
			m_singlenode_word = word;
		}
		return m_singlenode_word;
	}

	void generate_section(voxelworld::Instance *world,
			const pv::Vector3DInt16 &section_p)
	{
		pv::Region region = world->get_section_region_voxels(section_p);
		interface::VoxelVolume vol(region);
		vol.fill(interface::VoxelInstance(singlenode_word()));
		world->merge_volume(vol, false);
	}

	void on_generation_request(const voxelworld::GenerationRequest &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			generate_section(world, event.section_p);
		});
	}

	// The world create_instance() just made, filled before anything reads
	// it. The generation requests for those sections are in this module's
	// event queue and will arrive after run_game() has returned, which is
	// too late for a check -- or for a mod -- that looks at the map while
	// the game starts.
	void generate_world()
	{
		const pv::Vector3DInt32 p0(-SPAWN_RADIUS, -SPAWN_RADIUS, -SPAWN_RADIUS);
		const pv::Vector3DInt32 p1(SPAWN_RADIUS, SPAWN_RADIUS, SPAWN_RADIUS);
		size_t n = 0, already = 0;
		int64_t t0 = interface::os::time_us();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int32_t z = p0.getZ(); z <= p1.getZ(); z++)
			for(int32_t y = p0.getY(); y <= p1.getY(); y++)
			for(int32_t x = p0.getX(); x <= p1.getX(); x++){
				pv::Vector3DInt16 section_p(x, y, z);
				// voxelworld makes the region's sections on its first tick
				// rather than when the instance is created, so that a game
				// has its chance to name a save first; that has happened by
				// now, and what is read next is the map, so they are asked
				// for here
				if(!world->is_section_loaded(section_p))
					world->load_or_generate_section(section_p);
				// A section that has been generated already holds this
				// node everywhere nothing else was built, so one voxel of
				// it says whether the fill has been here -- and a section
				// out of a save is not walked again for nothing. A save
				// from before there was a fill reads as undefined and gets
				// one, which is the migration.
				pv::Region r = world->get_section_region_voxels(section_p);
				if(world->get_voxel(r.getLowerCorner(), true).data != 0){
					already++;
					continue;
				}
				generate_section(world, section_p);
				n++;
			}
		});
		log_v(MODULE, "The world: %zu sections filled with one node in %i "
				"ms, %zu already there", n,
				(int)((interface::os::time_us() - t0) / 1000), already);
	}

	// lua/check_map.lua, with the flush this module does between its two
	// halves: a round trip that never leaves the write-behind buffer would
	// prove nothing about voxelworld.
	void check_map_round_trip()
	{
		run_chunk_string("if not core.__check_map_write() then\n"
				"    core.log('verbose', 'check_map: no node to write')\n"
				"    core.__check_map_read = function() end\n"
				"end\n", "check_map_write");
		flush_node_writes();
		run_chunk_string("core.__check_map_read()", "check_map_read");
		// The check puts air back where it wrote; that has to land too, or
		// the world starts with a block of cobble nobody asked for
		flush_node_writes();
	}

	// core.__voxel_defs() -> add_voxel(), in id order, with a solid colour
	// each until M3 brings the real tiles
	// One box of a node box, as six quads in the voxel's own -0.5...0.5
	// cube -- which is where Luanti's node boxes already are, so a box
	// arrives as it was written.
	//
	// The corners of each face go counter-clockwise seen from outside it,
	// because the mesher takes (p1-p0) x (p2-p0) for the normal. Each face
	// shows the part of the node's texture it covers, the way Luanti's
	// makeCuboid does: without that a slab wears the whole texture squeezed
	// into it. See doc/plan/luanti_module_plan.md, "What a VoxelQuad has to
	// be".
	static void add_box_quads(sv_<interface::VoxelQuad> &out,
			float x0, float y0, float z0, float x1, float y1, float z1)
	{
		if(x1 < x0) std::swap(x0, x1);
		if(y1 < y0) std::swap(y0, y1);
		if(z1 < z0) std::swap(z0, z1);
		// The box's extents as fractions of the cube, which is what the
		// texture is cut out by
		const float ux0 = x0 + 0.5f, ux1 = x1 + 0.5f;
		const float uy0 = y0 + 0.5f, uy1 = y1 + 0.5f;
		const float uz0 = z0 + 0.5f, uz1 = z1 + 0.5f;
		auto quad = [&](uint8_t tile,
				float ax, float ay, float az, float au, float av,
				float bx, float by, float bz, float bu, float bv,
				float cx, float cy, float cz, float cu, float cv,
				float dx, float dy, float dz, float du, float dv){
			interface::VoxelQuad q;
			const float p[4][3] = {{ax, ay, az}, {bx, by, bz},
					{cx, cy, cz}, {dx, dy, dz}};
			const float uv[4][2] = {{au, av}, {bu, bv}, {cu, cv}, {du, dv}};
			for(size_t i = 0; i < 4; i++){
				for(size_t j = 0; j < 3; j++)
					q.p[i][j] = p[i][j];
				q.uv[i][0] = uv[i][0];
				q.uv[i][1] = uv[i][1];
			}
			q.tile = tile;
			out.push_back(q);
		};
		// +Y, u along x and v against z, so the top reads the way it does on
		// a full cube
		quad(0, x0, y1, z1, ux0, 1-uz1,  x1, y1, z1, ux1, 1-uz1,
				x1, y1, z0, ux1, 1-uz0,  x0, y1, z0, ux0, 1-uz0);
		// -Y
		quad(1, x0, y0, z0, ux0, uz0,    x1, y0, z0, ux1, uz0,
				x1, y0, z1, ux1, uz1,    x0, y0, z1, ux0, uz1);
		// +X
		quad(2, x1, y0, z1, uz1, 1-uy0,  x1, y0, z0, uz0, 1-uy0,
				x1, y1, z0, uz0, 1-uy1,  x1, y1, z1, uz1, 1-uy1);
		// -X
		quad(3, x0, y0, z0, 1-uz0, 1-uy0, x0, y0, z1, 1-uz1, 1-uy0,
				x0, y1, z1, 1-uz1, 1-uy1, x0, y1, z0, 1-uz0, 1-uy1);
		// +Z
		quad(4, x0, y0, z1, 1-ux0, 1-uy0, x1, y0, z1, 1-ux1, 1-uy0,
				x1, y1, z1, 1-ux1, 1-uy1, x0, y1, z1, 1-ux0, 1-uy1);
		// -Z
		quad(5, x1, y0, z0, ux1, 1-uy0,  x0, y0, z0, ux0, 1-uy0,
				x0, y1, z0, ux0, 1-uy1,  x1, y1, z0, ux1, 1-uy1);
	}

	// Luanti's eight liquid levels, and how high the surface of one stands
	// in its own voxel. A liquid whose range is shorter than eight spends
	// its levels on the top of the voxel and everything below them is the
	// floor, which is Luanti's own arithmetic.
	//
	// The top level is the top of the voxel: that is what a node with the
	// same liquid above it or a source beside it comes to, and a node at the
	// top level is nearly always one of those. Between levels the mesher
	// averages the four columns around each corner -- Luanti's
	// getCornerLevel, which the engine already does for anything marked
	// is_liquid -- so a slope is a slope and not a flight of steps.
	static const int LIQUID_LEVELS = 8;

	static float liquid_level_top(int level, int range)
	{
		if(level >= LIQUID_LEVELS - 1)
			return 0.5f;
		if(range < 1)
			range = 1;
		if(range > LIQUID_LEVELS)
			range = LIQUID_LEVELS;
		const int floor_levels = LIQUID_LEVELS - range;
		level = (level <= floor_levels) ? 0 : level - floor_levels;
		return -0.5f + ((float)level + 0.5f) / (float)range;
	}

	// Luanti's plantlike: two quads crossing at the middle of the voxel,
	// drawn from both sides. visual_scale makes it wider and taller, rooted
	// at the bottom of the voxel, which is what Luanti does with it.
	//
	// base is where the plant stands: the floor of its own voxel for
	// plantlike, and the top of it for plantlike_rooted, whose plant is
	// drawn into the space above the cube it is rooted in.
	static void add_plant_quads(sv_<interface::VoxelQuad> &out, float scale,
			float base = -0.5f, uint8_t tile = 0)
	{
		const float r = 0.5f * scale;
		const float y0 = base;
		const float y1 = base + scale;
		auto quad = [&](float ax, float az, float bx, float bz){
			interface::VoxelQuad q;
			const float p[4][3] = {{ax, y0, az}, {bx, y0, bz},
					{bx, y1, bz}, {ax, y1, az}};
			const float uv[4][2] = {{0, 1}, {1, 1}, {1, 0}, {0, 0}};
			for(size_t i = 0; i < 4; i++){
				for(size_t j = 0; j < 3; j++)
					q.p[i][j] = p[i][j];
				q.uv[i][0] = uv[i][0];
				q.uv[i][1] = uv[i][1];
			}
			q.tile = tile;
			out.push_back(q);
		};
		quad(-r, -r, r, r);
		quad(-r, r, r, -r);
	}

	// One quad lying flat against the surface it is mounted on, which is what
	// a sign is: Luanti's drawSignlikeNode. It starts against the +X wall and
	// is turned to whichever wall the wallmounted direction names.
	static void add_sign_quads(sv_<interface::VoxelQuad> &out, float scale,
			size_t wall)
	{
		const float size = 0.5f * scale;
		const float off = 0.5f - 1.0f / 16.0f;
		float p[4][3] = {
			{off, size, size}, {off, size, -size},
			{off, -size, -size}, {off, -size, size},
		};
		for(size_t c = 0; c < 4; c++){
			if(wall == 0)
				turn_quarters(p[c], 0, 1, 1);       // Ceiling
			else if(wall == 1)
				turn_quarters(p[c], 0, 1, -1);      // Floor
			else
				turn_quarters(p[c], 0, 2, wall_quad_turn(wall));
		}
		push_quad(out, p, 0);
	}

	// One quad hanging off the wall at an angle, which is what a torch is:
	// Luanti's drawTorchlikeNode. The tile is the definition's second for a
	// ceiling and its third for a wall, as Luanti picks them.
	static void add_torch_quads(sv_<interface::VoxelQuad> &out, float scale,
			size_t wall)
	{
		const float size = 0.5f * scale;
		uint8_t tile = 0;
		float p[4][3] = {
			{-size, size, 0}, {size, size, 0},
			{size, -size, 0}, {-size, -size, 0},
		};
		for(size_t c = 0; c < 4; c++){
			if(wall == 0 || wall == 6){             // Ceiling
				tile = 1;
				p[c][1] += 0.5f - size;
				turn_degrees(p[c], 0, 2, wall == 0 ? -45.0f : 45.0f);
			} else if(wall == 1 || wall == 7){      // Floor
				p[c][1] += size - 0.5f;
				turn_degrees(p[c], 0, 2, wall == 1 ? 45.0f : -45.0f);
			} else {
				tile = 2;
				p[c][0] += 0.5f - size;
				turn_quarters(p[c], 0, 2, wall_quad_turn(wall));
			}
		}
		push_quad(out, p, tile);
	}

	static void add_wall_quads(const ss_ &kind,
			sv_<interface::VoxelQuad> &out, float scale, size_t wall)
	{
		if(kind == "torchlike")
			add_torch_quads(out, scale, wall);
		else
			add_sign_quads(out, scale, wall);
	}

	// A post in the middle and a pair of bars towards each direction that
	// has something to reach: Luanti's drawFencelikeNode, at its own
	// measurements -- an eighth for the post, a sixteenth for the bars, and
	// the bars a quarter of the way up and down from the middle.
	//
	// The bars carry connect_dir, so the mesher draws each pair only when
	// that direction connects. That is what connect_dir is for and it had no
	// user; the header names a fence as the case.
	static void add_fence_quads(sv_<interface::VoxelQuad> &out)
	{
		const float post = 1.0f / 8.0f;
		const float bar = 1.0f / 16.0f;
		const float h = 1.0f / 4.0f;
		add_box_quads(out, -post, -0.5f, -post, post, 0.5f, post);
		// The four horizontal faces, in the mesher's own order: +X, -X, +Z,
		// -Z, which are faces 2 to 5 and therefore connect_dir 3 to 6
		for(size_t f = 2; f < 6; f++){
			const bool along_x = (f < 4);
			const float sign = (f % 2 == 0) ? 1.0f : -1.0f;
			const float near_end = post * sign;
			const float far_end = 0.5f * sign;
			for(int level = 0; level < 2; level++){
				const float y = (level == 0 ? h : -h);
				const size_t first = out.size();
				if(along_x){
					add_box_quads(out, near_end, y - bar, -bar,
							far_end, y + bar, bar);
				} else {
					add_box_quads(out, -bar, y - bar, near_end,
							bar, y + bar, far_end);
				}
				for(size_t i = first; i < out.size(); i++)
					out[i].connect_dir = (uint8_t)(f + 1);
			}
		}
	}

	// One quad just off the floor, which is what a rail or anything else
	// painted on the ground is
	static void add_flat_quad(sv_<interface::VoxelQuad> &out, uint8_t tile)
	{
		const float y = -0.5f + 1.0f / 16.0f;
		const float d = 0.5f;
		const float p[4][3] = {
			{-d, y, d}, {d, y, d}, {d, y, -d}, {-d, y, -d},
		};
		push_quad(out, p, tile);
	}

	// A shape per mask of a rail's four horizontal connections: sixteen flat
	// ones and four that climb. What a "shape per mask" is for is a voxel
	// whose whole shape changes with what is around it rather than gaining a
	// piece per direction, and the mesher picks one of these per voxel; see
	// VoxelDefinition::shape_masked, which had no user before this.
	static void add_rail_shapes(sv_<interface::VoxelQuad> &out,
			uint16_t begin[21])
	{
		for(size_t mask = 0; mask < 16; mask++){
			begin[mask] = (uint16_t)out.size();
			const size_t first = out.size();
			add_flat_quad(out, RAIL_KINDS[mask].tile);
			turn_quads_y(out, first, RAIL_KINDS[mask].degrees / 90);
		}
		for(size_t i = 0; i < 4; i++){
			begin[16 + i] = (uint16_t)out.size();
			const size_t first = out.size();
			add_flat_quad(out, 0);
			// The +Z edge lifted by exactly one node, which is the ramp
			// Luanti draws. One node rather than "up to the top of the
			// voxel", so that the raised end meets the flat rail a step
			// above it whatever height a flat rail floats at: they are the
			// same quad, one node apart.
			out[first].p[0][1] += 1.0f;
			out[first].p[1][1] += 1.0f;
			turn_quads_y(out, first, RAIL_SLOPE_TURNS[i] / 90);
		}
		begin[20] = (uint16_t)out.size();
	}

	// The quads from first onwards, turned about Y in place
	static void turn_quads_y(sv_<interface::VoxelQuad> &out, size_t first,
			int quarters)
	{
		if(((quarters % 4) + 4) % 4 == 0)
			return;
		for(size_t i = first; i < out.size(); i++){
			for(size_t c = 0; c < 4; c++)
				turn_quarters(out[i].p[c], 0, 2, quarters);
		}
	}

	// Four corners and a tile, with the texture filling the quad
	static void push_quad(sv_<interface::VoxelQuad> &out, const float p[4][3],
			uint8_t tile)
	{
		static const float UV[4][2] = {{0, 0}, {1, 0}, {1, 1}, {0, 1}};
		interface::VoxelQuad q;
		for(size_t i = 0; i < 4; i++){
			for(size_t j = 0; j < 3; j++)
				q.p[i][j] = p[i][j];
			q.uv[i][0] = UV[i][0];
			q.uv[i][1] = UV[i][1];
		}
		q.tile = tile;
		out.push_back(q);
	}

	// Asserts what add_box_quads() and add_plant_quads() build, because the
	// winding is what makes the normal and a quad wound the wrong way is
	// invisible rather than wrong-looking. Runs once, from run_game().
	// The one runnable check the mapblock reader leaves behind: a block put
	// together here in each of the two shapes the format has, and read back.
	// It proves the reader against the spec it was written from; that it
	// agrees with Luanti was checked by importing real worlds at versions
	// 25, 28 and 29 and comparing what arrived with an independent decode of
	// the same database. See doc/plan/luanti_module_plan.md, M7.
	static void check_mapblock()
	{
		const size_t N = luanti_mapblock::NODECOUNT;
		// What the check puts in and expects back
		sv_<uint16_t> id(N, 0);
		sv_<uint8_t> p1(N, 0), p2(N, 0);
		for(size_t i = 0; i < N; i++){
			id[i] = (uint16_t)(i % 300);
			p1[i] = (uint8_t)(i % 251);
			p2[i] = (uint8_t)(i % 253);
		}
		auto u8s = [](ss_ &os, uint32_t v){ os += (char)(v & 0xff); };
		auto u16s = [&](ss_ &os, uint32_t v){
			u8s(os, v >> 8); u8s(os, v);
		};
		auto u32s = [&](ss_ &os, uint32_t v){
			u16s(os, v >> 16); u16s(os, v);
		};
		auto string16 = [&](ss_ &os, const ss_ &v){
			u16s(os, (uint32_t)v.size());
			os += v;
		};
		// Two names, one of them at an id that needs two bytes
		auto nimap = [&](ss_ &os){
			u8s(os, 0);
			u16s(os, 2);
			u16s(os, 7);
			string16(os, "check:stone");
			u16s(os, 299);
			string16(os, "check:sand");
		};
		auto nodes = [&](ss_ &os){
			for(size_t i = 0; i < N; i++)
				u16s(os, id[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p1[i]);
			for(size_t i = 0; i < N; i++)
				u8s(os, p2[i]);
		};
		// One node with something hanging off it: a field and a two-slot
		// inventory with one thing in it
		auto node_metadata = [&](){
			ss_ os;
			u8s(os, 2);                 // version
			u16s(os, 1);                // one node has any
			u16s(os, 258);              // x=2, y=0, z=1
			u32s(os, 1);                // one field
			string16(os, "infotext");
			u16s(os, 0);                // a field's length is four bytes
			u16s(os, 11);
			os += "a sign says";
			u8s(os, 0);                 // not private
			os += "List main 2\n";
			os += "Width 0\n";
			os += "Item check:stone 5\n";
			os += "Empty\n";
			os += "EndInventoryList\n";
			os += "EndInventory\n";
			return os;
		};
		auto check_block = [&](const luanti_mapblock::Block &b,
				const char *what){
			for(size_t i = 0; i < N; i++){
				if(b.param0[i] != id[i] || b.param1[i] != p1[i] ||
						b.param2[i] != p2[i])
					throw Exception(ss_("check_mapblock: ")+what+" came back "
							"wrong at "+itos(i));
			}
			if(b.names.size() != 2 || b.names.at(7) != "check:stone" ||
					b.names.at(299) != "check:sand")
				throw Exception(ss_("check_mapblock: ")+what+" lost its "
						"name-id mapping");
			if(b.meta.size() != 1 || b.meta.count(258) == 0)
				throw Exception(ss_("check_mapblock: ")+what+" came back "
						"with "+itos(b.meta.size())+" nodes of metadata");
			const luanti_mapblock::NodeMeta &m = b.meta.at(258);
			if(m.fields.size() != 1 ||
					m.fields.at("infotext") != "a sign says")
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"field hanging off a node");
			if(m.lists.size() != 1 || m.lists.at("main").size() != 2 ||
					m.lists.at("main")[0] != "check:stone 5" ||
					!m.lists.at("main")[1].empty())
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"inventory hanging off a node");
		};

		// Version 29: one zstd frame, and what is wanted is in front of it
		{
			ss_ inside;
			u8s(inside, 0x00);          // flags
			u16s(inside, 0xffff);       // lighting_complete
			u32s(inside, 12345);        // timestamp
			nimap(inside);
			u8s(inside, 2);             // content_width
			u8s(inside, 2);             // params_width
			nodes(inside);
			inside += node_metadata();
			inside += "and whatever else the frame holds";
			ss_ data;
			u8s(data, 29);
			std::ostringstream os(std::ios::binary);
			interface::compress_zstd(inside, os);
			data += os.str();
			luanti_mapblock::Block block;
			luanti_mapblock::deserialize_block(data, block);
			check_block(block, "the version 29 block");
		}

		// Version 25: two zlib streams, and the mapping at the back behind
		// the static objects
		{
			ss_ data;
			u8s(data, 25);
			u8s(data, 0x00);            // flags
			u8s(data, 2);               // content_width
			u8s(data, 2);               // params_width
			ss_ raw_nodes;
			nodes(raw_nodes);
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(raw_nodes, os);
				data += os.str();
			}
			{
				std::ostringstream os(std::ios::binary);
				interface::compress_zlib(node_metadata(), os);
				data += os.str();
			}
			// Static objects: one, to be walked past
			u8s(data, 0);
			u16s(data, 1);
			u8s(data, 7);
			for(int i = 0; i < 12; i++)
				u8s(data, 0);
			string16(data, "an object");
			u32s(data, 12345);          // timestamp
			nimap(data);
			u8s(data, 0);               // node timers, unread
			u16s(data, 0);
			luanti_mapblock::Block block;
			luanti_mapblock::deserialize_block(data, block);
			check_block(block, "the version 25 block");
		}

		// The key a row has, which is three twelve-bit coordinates in one
		// integer and has to survive the negative ones
		const int coords[6] = {0, 1, -1, 2047, -2048, -3};
		for(int i = 0; i < 6; i++){
			for(int j = 0; j < 6; j++){
				int64_t key = (int64_t)coords[j] * 0x1000000 +
						(int64_t)coords[i] * 0x1000 + (int64_t)coords[i];
				pv::Vector3DInt16 p =
						luanti_mapblock::block_pos_of_key(key);
				if(p.getX() != coords[i] || p.getY() != coords[i] ||
						p.getZ() != coords[j])
					throw Exception("check_mapblock: the block key of ("+
							itos(coords[i])+", "+itos(coords[i])+", "+
							itos(coords[j])+") came back as ("+
							itos(p.getX())+", "+itos(p.getY())+", "+
							itos(p.getZ())+")");
			}
		}
		log_v(MODULE, "check_mapblock: both shapes of a block read back");
	}

	static void check_shapes()
	{
		auto normal_of = [](const interface::VoxelQuad &q, float n[3]){
			float e1[3], e2[3];
			for(size_t i = 0; i < 3; i++){
				e1[i] = q.p[1][i] - q.p[0][i];
				e2[i] = q.p[2][i] - q.p[0][i];
			}
			n[0] = e1[1]*e2[2] - e1[2]*e2[1];
			n[1] = e1[2]*e2[0] - e1[0]*e2[2];
			n[2] = e1[0]*e2[1] - e1[1]*e2[0];
		};
		sv_<interface::VoxelQuad> box;
		add_box_quads(box, -0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.5f);
		assert(box.size() == 6);
		// Face f faces the way face f of a cube faces
		static const float WANT[6][3] = {
			{0, 1, 0}, {0, -1, 0}, {1, 0, 0},
			{-1, 0, 0}, {0, 0, 1}, {0, 0, -1},
		};
		for(size_t f = 0; f < 6; f++){
			float n[3];
			normal_of(box[f], n);
			assert(box[f].tile == f);
			for(size_t i = 0; i < 3; i++)
				assert(n[i] * WANT[f][i] >= 0.0f);
			float dot = n[0]*WANT[f][0] + n[1]*WANT[f][1] + n[2]*WANT[f][2];
			assert(dot > 0.0f);
			// Every corner is inside the cube and every uv inside the tile
			for(size_t c = 0; c < 4; c++){
				for(size_t i = 0; i < 3; i++)
					assert(box[f].p[c][i] >= -0.5f && box[f].p[c][i] <= 0.5f);
				for(size_t i = 0; i < 2; i++)
					assert(box[f].uv[c][i] >= 0.0f && box[f].uv[c][i] <= 1.0f);
			}
		}
		// A slab's top is at y=0 and its texture is the top half of the tile
		// in the two axes it spans, not a squeezed whole one
		assert(box[0].p[0][1] == 0.0f);
		assert(box[2].uv[0][1] == 1.0f && box[2].uv[2][1] == 0.5f);
		// A box given its corners the other way round is the same box
		sv_<interface::VoxelQuad> flipped;
		add_box_quads(flipped, 0.5f, 0.0f, 0.5f, -0.5f, -0.5f, -0.5f);
		assert(flipped.size() == box.size());
		for(size_t i = 0; i < box.size(); i++){
			for(size_t c = 0; c < 4; c++){
				for(size_t j = 0; j < 3; j++)
					assert(flipped[i].p[c][j] == box[i].p[c][j]);
			}
		}
		// The facedir tables: every row a permutation of the six faces, with
		// opposite faces still opposite -- which is what a rotation of a cube
		// can do and nothing else is. A transcription error shows up here
		// rather than as a chest with two lids.
		for(size_t d = 0; d < 24; d++){
			bool seen[6] = {};
			for(size_t f = 0; f < 6; f++){
				assert(FACEDIR_TILES[d][f] < 6);
				assert(!seen[FACEDIR_TILES[d][f]]);
				seen[FACEDIR_TILES[d][f]] = true;
				assert(FACEDIR_TURNS[d][f] < 4);
			}
			// Faces 0 and 1 are opposite, and so are 2 and 3 and 4 and 5
			for(size_t f = 0; f < 6; f += 2)
				assert((FACEDIR_TILES[d][f] ^ 1) == FACEDIR_TILES[d][f + 1]);
		}
		// Facedir 0 changes nothing
		for(size_t f = 0; f < 6; f++){
			assert(FACEDIR_TILES[0][f] == f);
			assert(FACEDIR_TURNS[0][f] == 0);
		}
		// Each facedir matrix is a proper rotation -- an orthonormal basis
		// with determinant 1 -- and it takes each local face to the world
		// face the table says wears its tile. Derived from the table, so
		// this is the table checking itself against what a rotation can be.
		for(size_t d = 0; d < 24; d++){
			int m[3][3] = {};
			facedir_matrix((uint8_t)d, m);
			const int det =
					m[0][0]*(m[1][1]*m[2][2] - m[1][2]*m[2][1]) -
					m[0][1]*(m[1][0]*m[2][2] - m[1][2]*m[2][0]) +
					m[0][2]*(m[1][0]*m[2][1] - m[1][1]*m[2][0]);
			assert(det == 1);
			for(size_t c = 0; c < 3; c++){
				int len = 0;
				for(size_t r = 0; r < 3; r++)
					len += m[r][c] * m[r][c];
				assert(len == 1);
			}
			// Facedir 0 turns nothing
			if(d == 0){
				for(size_t r = 0; r < 3; r++)
					for(size_t c = 0; c < 3; c++)
						assert(m[r][c] == (r == c ? 1 : 0));
			}
		}
		// A box turned four quarters about any axis is the box it was
		{
			sv_<interface::VoxelQuad> a, b;
			add_box_quads(a, -0.5f, -0.5f, -0.5f, 0.5f, 0.0f, 0.25f);
			turn_quads(a, 0, b);
			assert(b.size() == a.size());
			for(size_t i = 0; i < a.size(); i++){
				for(size_t c = 0; c < 4; c++){
					for(size_t j = 0; j < 3; j++)
						assert(a[i].p[c][j] == b[i].p[c][j]);
				}
			}
			// Facedir 20 is the node stood on its head: y flips
			turn_quads(a, 20, b);
			for(size_t i = 0; i < a.size(); i++){
				for(size_t c = 0; c < 4; c++)
					assert(b[i].p[c][1] == -a[i].p[c][1]);
			}
		}

		// A wallmounted direction is one of the twenty-four, and the two
		// that stand up are the ones a floor and a ceiling node get
		for(size_t i = 0; i < 8; i++)
			assert(WALLMOUNTED_FACEDIR[i] < 24);
		assert(facing_facedir("wallmounted", 1) == 0); // Floor: unturned
		assert(facing_variant_count("facedir") == 24);
		assert(facing_variant_count("4dir") == 4);
		assert(facing_variant_count("") == 0);
		assert(facing_variant_of_param("facedir", 31) == 7); // 31 % 24
		assert(facing_variant_of_param("4dir", 0xfe) == 2);

		// A fence is a post that is always drawn and four pairs of bars that
		// are drawn only when their direction connects, which is what
		// connect_dir says
		{
			sv_<interface::VoxelQuad> fence;
			add_fence_quads(fence);
			// One post and eight bars, six quads each
			assert(fence.size() == 9 * 6);
			size_t always = 0;
			uint8_t seen[7] = {};
			for(const interface::VoxelQuad &q : fence){
				assert(q.connect_dir < 7);
				if(q.connect_dir == 0)
					always++;
				else
					seen[q.connect_dir]++;
				for(size_t c = 0; c < 4; c++){
					for(size_t j = 0; j < 3; j++){
						assert(q.p[c][j] >= -0.5f && q.p[c][j] <= 0.5f);
					}
				}
			}
			assert(always == 6);           // The post
			for(size_t d = 3; d <= 6; d++)
				assert(seen[d] == 12);     // Two bars each way
			assert(seen[1] == 0 && seen[2] == 0); // Nothing up or down
		}

		// A rail is one quad per mask, twenty of them, and the offsets say
		// where each begins. The flat ones lie just off the floor; the four
		// that climb have two corners a node higher than the rest.
		{
			sv_<interface::VoxelQuad> rails;
			uint16_t begin[21] = {};
			add_rail_shapes(rails, begin);
			assert(rails.size() == 20);
			assert(begin[0] == 0 && begin[20] == 20);
			for(size_t m = 0; m < 20; m++){
				assert(begin[m + 1] == begin[m] + 1);
				const interface::VoxelQuad &q = rails[begin[m]];
				assert(q.tile < 4);
				int high = 0;
				for(size_t c = 0; c < 4; c++){
					// A turn about Y leaves x and z inside the voxel
					assert(q.p[c][0] >= -0.5f && q.p[c][0] <= 0.5f);
					assert(q.p[c][2] >= -0.5f && q.p[c][2] <= 0.5f);
					if(q.p[c][1] > 0.0f)
						high++;
				}
				assert(high == (m >= 16 ? 2 : 0));
			}
			// Nothing beside it and everything beside it are the two Luanti
			// draws with its first and fourth tiles
			assert(rails[begin[0]].tile == 0);
			assert(rails[begin[15]].tile == 3);

		}

		// A sign lies flat against the surface it is on, so its quad has a
		// normal along one axis and sits just off the boundary in that
		// direction. A torch leans, so its normal has no zero component in
		// the plane it leans in.
		for(size_t wall = 0; wall < 8; wall++){
			sv_<interface::VoxelQuad> sign, torch;
			add_sign_quads(sign, 1.0f, wall);
			add_torch_quads(torch, 1.0f, wall);
			assert(sign.size() == 1 && torch.size() == 1);
			for(const sv_<interface::VoxelQuad> *qs : {&sign, &torch}){
				for(size_t c = 0; c < 4; c++){
					for(size_t j = 0; j < 3; j++){
						// Inside the voxel, give or take the rounding a
						// 45 degree turn leaves
						assert((*qs)[0].p[c][j] > -0.71f &&
								(*qs)[0].p[c][j] < 0.71f);
					}
				}
			}
			// A wall torch wears the definition's third tile, a ceiling one
			// its second and a floor one its first; Luanti's own choice
			assert(torch[0].tile == (wall <= 1 || wall >= 6 ?
					(wall == 0 || wall == 6 ? 1 : 0) : 2));
		}

		// The plant is two quads that cross, standing on the voxel's floor
		sv_<interface::VoxelQuad> plant;
		add_plant_quads(plant, 1.0f);
		assert(plant.size() == 2);
		for(const interface::VoxelQuad &q : plant){
			float n[3];
			normal_of(q, n);
			assert(std::fabs(n[1]) < 1e-6f); // Upright
			assert(n[0] != 0.0f || n[2] != 0.0f);
			assert(q.p[0][1] == -0.5f && q.p[2][1] == 0.5f);
		}
	}

	// An edge material of its own for each kind of glass, so that the mesher
	// draws a face between glass and anything else and not between two of
	// the same glass -- which is what Luanti's glasslike is.
	//
	// simplified: 10 to 255 is what an EdgeMaterialId leaves free, so a game
	// with more than 246 glasslike node types shares the last one and its
	// panes merge into each other. Nothing that big has turned up; the
	// upgrade path is a wider EdgeMaterialId, which is an engine change.
	interface::EdgeMaterialId glass_edge_material(const ss_ &name)
	{
		auto it = m_glass_edge_materials.find(name);
		if(it != m_glass_edge_materials.end())
			return it->second;
		interface::EdgeMaterialId id = 255;
		if(m_next_glass_edge_material < 255){
			id = (interface::EdgeMaterialId)m_next_glass_edge_material++;
		} else if(!m_glass_edge_materials_exhausted){
			m_glass_edge_materials_exhausted = true;
			log_w(MODULE, "More than 246 glasslike node types; the rest share "
					"an edge material and their faces merge into each other");
		}
		m_glass_edge_materials[name] = id;
		return id;
	}

	// One shape group per liquid, so that the mesher drops the faces inside
	// a body of it -- the water in the middle of a lake -- and keeps the
	// ones against everything else. A source and its flowing form share a
	// group because they both name the source.
	//
	// simplified: 1 to 255 is what a shape group has, and 0 means "not
	// grouped", so a game with more than 255 distinct liquids shares the
	// last one and two of its liquids stop drawing the surface between
	// them. Nothing that big has turned up.
	uint8_t liquid_shape_group(const ss_ &group)
	{
		auto it = m_liquid_shape_groups.find(group);
		if(it != m_liquid_shape_groups.end())
			return it->second;
		uint8_t id = 255;
		if(m_next_liquid_shape_group < 255){
			id = (uint8_t)m_next_liquid_shape_group++;
		} else if(!m_liquid_shape_groups_exhausted){
			m_liquid_shape_groups_exhausted = true;
			log_w(MODULE, "More than 254 liquids; the rest share a shape "
					"group and draw no surface between each other");
		}
		m_liquid_shape_groups[group] = id;
		return id;
	}

	// One family per raillike group, because a rail reaches the rails of its
	// own group and no others. Fences have group 1; a connect group is five
	// bits of a thirty-two bit mask, so there are thirty-one left.
	uint8_t rail_connect_group(int raillike_group)
	{
		auto it = m_rail_connect_groups.find(raillike_group);
		if(it != m_rail_connect_groups.end())
			return it->second;
		uint8_t id = 32;
		if(m_next_rail_connect_group <= 32){
			id = (uint8_t)m_next_rail_connect_group++;
		} else if(!m_rail_connect_groups_exhausted){
			m_rail_connect_groups_exhausted = true;
			log_w(MODULE, "More than 31 raillike groups; the rest share one "
					"and their rails connect to each other");
		}
		m_rail_connect_groups[raillike_group] = id;
		return id;
	}

	// A tile the client can load as it stands: a plain file name the game
	// shipped. Anything with a texture modifier in it -- ^ for an overlay,
	// [ for a generator, ( for a grouping -- has to be composed, and the
	// client is what composes it, which is the rest of M3.
	// One texture of a definition, with the surface numbers every node of a
	// Luanti game gets until the nodedef carries its own
	static interface::AtlasSegmentDefinition make_segment(const ss_ &texture)
	{
		interface::AtlasSegmentDefinition seg;
		seg.resource_name = texture;
		seg.total_segments = magic::IntVector2(
				texture.empty() ? 0 : 1, texture.empty() ? 0 : 1);
		seg.select_segment = magic::IntVector2(0, 0);
		seg.roughness = 0.95f;
		seg.spec_strength = 0.15f;
		seg.bumpiness = 0.0f;
		return seg;
	}

	bool plain_media_name(const ss_ &tile)
	{
		if(tile.empty())
			return false;
		if(is_texmod(tile))
			return false;
		return m_served_media.count(tile) != 0;
	}

	// A tile that is not a file name but an expression over them: "^" for an
	// overlay, "[" for a generator, "(" for a group. The client composes
	// these; what is left for the flat colour is a plain name the game did
	// not ship.
	static bool is_texmod(const ss_ &tile)
	{
		return !tile.empty() && tile.find_first_of("^[(&") != ss_::npos;
	}

	// The resource name a tile is drawn under, and what the client has to
	// compose to have it. Empty for a tile that is neither a file the game
	// shipped nor an expression.
	ss_ texture_of_tile(const ss_ &tile)
	{
		if(plain_media_name(tile))
			return media_resource_name(tile);
		if(is_texmod(tile)){
			ss_ resource = texmod_resource_name(tile);
			m_texmods[resource] = tile;
			return resource;
		}
		return "";
	}

	void build_voxel_registry(interface::VoxelRegistry *reg)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__voxel_defs");
		if(lua_pcall(L, 0, 1, 0) != 0){
			ss_ err = lua_tostring(L, -1) ? lua_tostring(L, -1) : "?";
			lua_settop(L, base);
			throw Exception("luanti: __voxel_defs(): "+err);
		}
		size_t n = lua_objlen(L, -1);
		sv_<ss_> textures;
		size_t n_fallback = 0;
		size_t n_shaped = 0;
		size_t n_liquid = 0;
		size_t n_facing_nodes = 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			ss_ name = table_string(L, "name");
			bool sunlight = table_boolean(L, "sunlight");
			bool alpha_blend = table_boolean(L, "alpha_blend");
			bool empty = table_boolean(L, "empty");
			bool walkable = table_boolean(L, "walkable");
			ss_ drawtype = table_string(L, "drawtype");
			float visual_scale = (float)table_number(L, "visual_scale", 1.0);
			ss_ tiles[6];
			bool has_tiles = table_six_strings(L, "tiles", tiles);
			sv_<float> boxes;
			table_numbers(L, "node_box", boxes);
			ss_ facing = table_string(L, "facing");
			ss_ overlay_tile = table_string(L, "overlay_tile");
			ss_ liquid_group = table_string(L, "liquid_group");
			int raillike_group = (int)table_number(L, "raillike_group", 0);
			int liquid_range = (int)table_number(L, "liquid_range",
					LIQUID_LEVELS);
			lua_pop(L, 1);

			// The shape, where the drawtype is one this builds. Everything
			// else is still a cube; see the M3 entry in the module plan for
			// which and in what order.
			sv_<interface::VoxelQuad> shape;
			bool double_sided = false;
			bool lit_from_above = false;
			// "torchlike" or "signlike": a shape that is built per
			// wallmounted direction rather than turned
			ss_ wall_shape;
			// Which family this reaches out to, and which families it
			// reaches; see connect_dir in interface/voxel.h
			uint8_t connect_group = 0;
			uint32_t connect_mask = 0;
			bool connect_to_solid = false;
			// A shape per mask of which neighbours the voxel reaches; see
			// VoxelDefinition::shape_masked
			sv_<interface::VoxelQuad> masked_shape;
			uint16_t masked_begin[21] = {};
			// The shape is drawn as well as the voxel's cube faces, not
			// instead of them
			bool shape_over_cube = false;
			if(drawtype == "nodebox" && boxes.size() >= 6){
				for(size_t b = 0; b + 5 < boxes.size(); b += 6){
					add_box_quads(shape, boxes[b], boxes[b + 1], boxes[b + 2],
							boxes[b + 3], boxes[b + 4], boxes[b + 5]);
				}
			} else if(drawtype == "plantlike"){
				add_plant_quads(shape, visual_scale > 0.0f ? visual_scale : 1.0f);
				double_sided = true;
			} else if(drawtype == "raillike"){
				// One quad, and which tile it wears and which way it is
				// turned is what its neighbours say -- so it is a shape per
				// mask rather than a shape. A rail reaches other rails of
				// its own raillike group and nothing else.
				add_rail_shapes(masked_shape, masked_begin);
				connect_group = rail_connect_group(raillike_group);
				connect_mask = 1u << (connect_group - 1);
			} else if(drawtype == "fencelike"){
				// A post and a pair of bars per direction that has
				// something to reach. It reaches other fences, whatever
				// kind, and anything solid -- which is Luanti's rule.
				add_fence_quads(shape);
				connect_group = FENCE_CONNECT_GROUP;
				connect_mask = 1u << (FENCE_CONNECT_GROUP - 1);
				connect_to_solid = true;
			} else if(drawtype == "firelike"){
				// Luanti's fire is quads leaning against whatever is around
				// it; crossed quads are what it comes to when nothing is,
				// and what the extension draws for it either way.
				add_plant_quads(shape, visual_scale > 0.0f ? visual_scale : 1.0f);
				double_sided = true;
			} else if(drawtype == "torchlike" || drawtype == "signlike"){
				// One quad, and which way it lies is the wallmounted
				// direction rather than a rotation of one base shape -- a
				// torch on the floor leans and a torch on a wall does not.
				// So the shape is built per variant below; this is what a
				// node whose param2 says nothing comes to.
				wall_shape = drawtype;
				add_wall_quads(wall_shape, shape,
						visual_scale > 0.0f ? visual_scale : 1.0f, 1);
				double_sided = true;
			} else if(drawtype == "plantlike_rooted"){
				// The plant stands in the voxel above the one it is rooted
				// in, and the cube it is rooted in is ground drawn by the
				// cube path -- so this shape is over the cube rather than
				// instead of it, and the plant takes the light of the voxel
				// it stands in and not the ground's own. That is what
				// shape_lit_from_above is for.
				add_plant_quads(shape,
						visual_scale > 0.0f ? visual_scale : 1.0f, 0.5f, 6);
				double_sided = true;
				lit_from_above = true;
				shape_over_cube = true;
			} else if(!liquid_group.empty()){
				// A full voxel of it. The faces inside a body of the same
				// liquid are dropped by the shape group, and the surface is
				// levelled by the variants below.
				add_box_quads(shape, -0.5f, -0.5f, -0.5f, 0.5f, 0.5f, 0.5f);
			}

			// Which way the node faces, which is also param2: one variant
			// per direction, each permuting the definition's own six
			// textures rather than being a voxel type of its own.
			sv_<interface::VoxelVariant> facing_variants;
			const size_t n_facing = facing_variant_count(facing);
			for(size_t i = 0; i < n_facing; i++){
				interface::VoxelVariant var;
				const uint8_t d = facing_facedir(facing, i);
				for(size_t f = 0; f < 6; f++){
					var.tile_order[f] = FACEDIR_TILES[d][f];
					var.tile_turns[f] = FACEDIR_TURNS[d][f];
				}
				if(!wall_shape.empty()){
					// A torch or a sign: its own shape per wall, and the
					// variant index is the wallmounted direction itself
					add_wall_quads(wall_shape, var.shape,
							visual_scale > 0.0f ? visual_scale : 1.0f, i);
				} else if(!shape.empty() && !shape_over_cube && d != 0){
					// A node that has a shape turns the shape too: a stair
					// facing the other way is the same quads rotated, and
					// the tile each quad names travels with it. Only for a
					// shape that is the node's own cube -- a rooted plant's
					// shape stands in the voxel above and turning it would
					// take it sideways out of that voxel.
					turn_quads(shape, d, var.shape);
				}
				facing_variants.push_back(var);
			}

			// A flowing liquid carries its level in param2, which is what
			// VoxelVariant is for: one per level, each a box with its own
			// top, and the mesher averages the four columns around each
			// corner so that the surface between them is continuous.
			sv_<interface::VoxelVariant> liquid_variants;
			if(drawtype == "flowingliquid" && !liquid_group.empty()){
				liquid_variants.resize(LIQUID_LEVELS);
				for(int level = 0; level < LIQUID_LEVELS; level++){
					interface::VoxelVariant &var = liquid_variants[level];
					var.liquid_top = liquid_level_top(level, liquid_range);
					add_box_quads(var.shape, -0.5f, -0.5f, -0.5f,
							0.5f, var.liquid_top, 0.5f);
				}
			}

			// The generated flat colour, for a node whose tiles the client
			// cannot load as they stand -- a texture modifier, or a name the
			// game did not ship. It is what every node wore before the
			// game's own media was served, and it stays until the client
			// resolves modifiers itself.
			ss_ fallback = empty ? "" : node_texture_name(name);
			ss_ face_textures[6];
			bool any_fallback = false;
			for(size_t f = 0; f < 6; f++){
				if(empty)
					continue;
				ss_ texture = has_tiles ? texture_of_tile(tiles[f]) : "";
				if(!texture.empty()){
					face_textures[f] = texture;
				} else {
					face_textures[f] = fallback;
					any_fallback = true;
				}
			}
			// The plant of a rooted plant: a texture the cube it stands in
			// does not have, and the first of the definition's extra ones
			ss_ overlay_texture;
			if(!overlay_tile.empty() && !fallback.empty()){
				overlay_texture = texture_of_tile(overlay_tile);
				if(overlay_texture.empty()){
					overlay_texture = fallback;
					any_fallback = true;
				}
			}
			if(any_fallback && !fallback.empty()){
				textures.push_back(name);
				n_fallback++;
			}

			interface::VoxelDefinition vdef;
			vdef.name.block_name = name;
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t f = 0; f < 6; f++)
				vdef.textures[f] = make_segment(face_textures[f]);
			// The textures a shape's quads can wear beyond the six faces: a
			// rooted plant's plant, which is nothing the cube it stands in
			// has. Quad tile 6 is the first of these.
			if(!overlay_texture.empty())
				vdef.extra_textures.push_back(make_segment(overlay_texture));
			// Which faces are drawn, as far as the edge material carries
			// Luanti's rules:
			//  - airlike is nothing at all, and nothing draws a face
			//    against it
			//  - glasslike gets an edge material of its own, so a face is
			//    drawn against anything except more of the same glass --
			//    a pane of it is a pane and a wall of it is a wall
			//  - allfaces draws every face, even between two of its own
			//    kind, which is what makes a tree's leaves look like leaves
			//  - everything else draws a face wherever the material changes
			//
			// Whether light gets past is a separate question now, and
			// transmits_light below is the answer to it.
			vdef.edge_material_id = interface::EDGEMATERIALID_GROUND;
			if(empty){
				vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
			} else if(drawtype.compare(0, 9, "glasslike") == 0){
				vdef.edge_material_id = glass_edge_material(name);
			} else if(drawtype == "allfaces" ||
					drawtype == "allfaces_optional"){
				vdef.face_draw_type = interface::FaceDrawType::ALWAYS;
			}
			// An empty voxel already transmits light by being empty
			vdef.transmits_light = sunlight && !empty;
			vdef.physically_solid = walkable && !empty;
			vdef.fully_empty = empty;
			if(!masked_shape.empty()){
				vdef.shape_masked = masked_shape;
				for(size_t i = 0; i < 21; i++)
					vdef.shape_masked_begin[i] = masked_begin[i];
			}
			if(!shape.empty() || !masked_shape.empty()){
				vdef.shape = shape;
				vdef.shape_double_sided = double_sided;
				vdef.shape_lit_from_above = lit_from_above;
				if(!shape_over_cube){
					// A shaped voxel draws its shape and not cube faces, and
					// its neighbours draw theirs against it
					vdef.face_draw_type = interface::FaceDrawType::NEVER;
					vdef.edge_material_id = interface::EDGEMATERIALID_EMPTY;
				}
				n_shaped++;
			}
			vdef.connect_group = connect_group;
			vdef.connect_mask = connect_mask;
			vdef.connect_to_solid = connect_to_solid;
			if(!facing_variants.empty()){
				vdef.variants = facing_variants;
				for(size_t p = 0; p < 256; p++){
					vdef.variant_of_param[p] =
							facing_variant_of_param(facing, (uint8_t)p);
				}
				n_facing_nodes++;
			}
			if(!liquid_group.empty()){
				vdef.is_liquid = true;
				vdef.shape_group = liquid_shape_group(liquid_group);
				vdef.liquid_top = 0.5f;
				vdef.variants = liquid_variants;
				// param2's low three bits are the level; the rest of it is
				// flags this does not draw
				if(!liquid_variants.empty()){
					for(size_t p = 0; p < 256; p++)
						vdef.variant_of_param[p] = (uint8_t)(p % LIQUID_LEVELS);
				}
				n_liquid++;
			}
			// Which pass the faces go in. The mesher puts a translucent
			// voxel's faces on a child node of the chunk and
			// builtin/voxel_shading gives that one the blended technique.
			//
			// A liquid always, and anything the game asked to be blended
			// rather than alpha masked.
			vdef.translucent = alpha_blend || !liquid_group.empty();
			reg->add_voxel(vdef);
		}
		lua_settop(L, base);

		serve_node_textures(textures);
		log_i(MODULE, "%zu node types in the voxel registry: %zu have a shape "
				"of their own, %zu of those are liquids, %zu turn with their "
				"param2, %zu wear a generated colour because a tile is a "
				"texture modifier or was not shipped",
				n, n_shaped, n_liquid, n_facing_nodes, n_fallback);
	}

	// The game's own media, named the way Luanti names it: by basename and
	// nothing else, because a tile string says "default_stone.png" and says
	// nothing about where it came from. A clash between two mods is the
	// game's to avoid, which is the deal Luanti gives them too.
	//
	// Luanti draws no line between a texture, a model, a sound and a
	// translation: whatever sits under a mod's media directories and ends in
	// an extension on the whitelist is media and goes to the client. What
	// the client makes of it is the game's business, not the server's.
	void serve_game_media(const ss_ &game_path)
	{
		// Luanti's directories, in Luanti's order (src/server/mods.cpp)
		static const sv_<ss_> wanted = {"textures", "sounds", "media",
				"models", "locale", "fonts"};
		sv_<ss_> dirs;
		// The game's own textures/, beside its mods' (src/server.cpp)
		if(interface::fs::path_exists(game_path+"/textures"))
			dirs.push_back(game_path+"/textures");
		collect_dirs_named(game_path+"/mods", wanted, dirs, 0);
		sm_<ss_, ss_> files;
		for(const ss_ &dir : dirs)
			collect_files(dir, files, 0);
		client_file::access(m_server, [&](client_file::Interface *i){
			for(const auto &pair : files)
				i->add_file_path(media_resource_name(pair.first), pair.second);
		});
		for(const auto &pair : files)
			m_served_media.insert(pair.first);
		log_i(MODULE, "%zu media files from %zu directories under %s",
				files.size(), dirs.size(), cs(game_path));
	}

	// A mod is a directory with a textures/ or a models/ in it, and a modpack
	// is a directory of those, so this goes a few levels deep and no further
	void collect_dirs_named(const ss_ &path, const sv_<ss_> &wanted,
			sv_<ss_> &out, int depth)
	{
		if(depth > 3)
			return;
		for(const interface::fs::Node &n : interface::fs::list_directory(path)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			if(std::find(wanted.begin(), wanted.end(), n.name) != wanted.end())
				out.push_back(path+"/"+n.name);
			else
				collect_dirs_named(path+"/"+n.name, wanted, out, depth + 1);
		}
	}

	// Luanti's media whitelist: a plain name, and an extension the client
	// knows what to do with (Server::addMediaFile in src/server.cpp)
	static bool is_media_name(const ss_ &name)
	{
		if(name.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
				"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-") != ss_::npos)
			return false;
		static const char *exts[] = {
			"png", "jpg", "tga",
			"ogg",
			"x", "b3d", "obj", "gltf", "glb",
			"tr", "po", "mo", // translations
			"ttf", "woff", // fonts
			nullptr
		};
		for(const char **ext = exts; *ext; ext++)
			if(interface::fs::check_file_extension(cs(name), *ext))
				return true;
		return false;
	}

	static void check_media_names()
	{
		assert(is_media_name("default_stone.png"));
		assert(is_media_name("gltf_frog.gltf"));
		assert(is_media_name("default_cobble.x"));
		assert(is_media_name("soundstuff_mono.ogg"));
		// A mod's code, its documentation and its stray files stay home
		assert(!is_media_name("init.lua"));
		assert(!is_media_name("README.txt"));
		assert(!is_media_name("model.blend"));
		// An extension is not a name, and a name is not a path
		assert(!is_media_name("png"));
		assert(!is_media_name("a name with spaces.png"));
		assert(!is_media_name("../outside.png"));
		log_v(MODULE, "check_media_names: the whitelist holds");
	}

	// The first one under a name wins, which is what Luanti does with a
	// clash as well
	void collect_files(const ss_ &dir, sm_<ss_, ss_> &files, int depth)
	{
		if(depth > 4)
			return;
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.name == "." || n.name == "..")
				continue;
			if(n.is_directory){
				collect_files(dir+"/"+n.name, files, depth + 1);
				continue;
			}
			if(files.count(n.name) || !is_media_name(n.name))
				continue;
			files[n.name] = dir+"/"+n.name;
		}
	}

	// One flat PNG per node, generated and handed to client_file rather than
	// written to disk: there is no file behind these and there should not be
	// one. What still uses one is a node whose tile the client cannot load
	// as it stands.
	void serve_node_textures(const sv_<ss_> &names)
	{
		sm_<ss_, ss_> files;
		for(const ss_ &name : names){
			ss_ resource = node_texture_name(name);
			if(files.count(resource))
				continue;
			uint8_t rgb[3];
			node_colour(name, rgb);
			const int size = 16;
			ss_ pixels;
			pixels.reserve(size * size * 3);
			for(int i = 0; i < size * size; i++){
				pixels.push_back((char)rgb[0]);
				pixels.push_back((char)rgb[1]);
				pixels.push_back((char)rgb[2]);
			}
			ss_ png;
			if(!stbi_write_png_to_func(png_write_cb, &png, size, size, 3,
					pixels.c_str(), size * 3)){
				log_w(MODULE, "Could not encode a texture for %s", cs(name));
				continue;
			}
			files[resource] = png;
		}
		client_file::access(m_server, [&](client_file::Interface *ifile){
			for(const auto &pair : files)
				ifile->add_file_content(pair.first, pair.second);
		});
		log_v(MODULE, "%zu node textures served", files.size());
	}

	// Lua table helpers; the table is on top of the stack

	ss_ table_string(lua_State *L, const char *key)
	{
		lua_getfield(L, -1, key);
		ss_ v = lua_tostring(L, -1) ? lua_tostring(L, -1) : "";
		lua_pop(L, 1);
		return v;
	}

	bool table_boolean(lua_State *L, const char *key)
	{
		lua_getfield(L, -1, key);
		bool v = lua_toboolean(L, -1);
		lua_pop(L, 1);
		return v;
	}

	double table_number(lua_State *L, const char *key, double def)
	{
		lua_getfield(L, -1, key);
		double v = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : def;
		lua_pop(L, 1);
		return v;
	}

	// An array of numbers under key; left empty when it is not there
	void table_numbers(lua_State *L, const char *key, sv_<float> &out)
	{
		out.clear();
		lua_getfield(L, -1, key);
		if(!lua_istable(L, -1)){
			lua_pop(L, 1);
			return;
		}
		size_t n = lua_objlen(L, -1);
		out.reserve(n);
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			out.push_back((float)lua_tonumber(L, -1));
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
	}

	// An array of six strings under key, or false when it is not there
	bool table_six_strings(lua_State *L, const char *key, ss_ out[6])
	{
		lua_getfield(L, -1, key);
		if(!lua_istable(L, -1)){
			lua_pop(L, 1);
			return false;
		}
		bool ok = true;
		for(size_t i = 0; i < 6; i++){
			lua_rawgeti(L, -1, (int)i + 1);
			cc_ *v = lua_tostring(L, -1);
			if(v)
				out[i] = v;
			else
				ok = false;
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
		return ok;
	}

	// The two C functions the map goes through

	static Module* module_of(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__luanti_module");
		Module *self = (Module*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		return self;
	}

	// set_node(x, y, z, id, param1, param2)
	static int l_set_node(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x = luaL_checkinteger(L, 1);
		int32_t y = luaL_checkinteger(L, 2);
		int32_t z = luaL_checkinteger(L, 3);
		uint32_t id = (uint32_t)luaL_checkinteger(L, 4);
		uint32_t param1 = (uint32_t)luaL_optinteger(L, 5, 0);
		uint32_t param2 = (uint32_t)luaL_optinteger(L, 6, 0);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		uint32_t word = 0;
		f.id.set(word, id);
		// param1 is the two light nibbles, which the format binds as two
		// fields; voxelworld owns the sky half, so a mod writing param1
		// writes the lamp half and its own sky value is overwritten by the
		// next flood. That is the same deal Luanti gives a mod.
		f.light_sky.set(word, param1 & 0x0f);
		f.light_lamp.set(word, (param1 >> 4) & 0x0f);
		f.param.set(word, param2 & 0xff);
		self->buffer_node_write(x, y, z, word);
		return 0;
	}

	// get_node(x, y, z) -> id, param1, param2
	static int l_get_node(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x = luaL_checkinteger(L, 1);
		int32_t y = luaL_checkinteger(L, 2);
		int32_t z = luaL_checkinteger(L, 3);
		uint32_t word = self->read_node(x, y, z);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		lua_pushinteger(L, (lua_Integer)f.id.get(word));
		lua_pushinteger(L, (lua_Integer)(f.light_sky.get(word) |
				(f.light_lamp.get(word) << 4)));
		lua_pushinteger(L, (lua_Integer)f.param.get(word));
		return 3;
	}

	// get_region(x0, y0, z0, x1, y1, z1) -> a flat array of content ids, x
	// fastest and then y and then z. Only the ids: what asks for a box asks
	// what is in it, and a table three times the size would be three times
	// the garbage.
	// __luanti_active_boxes() -> the voxel box of every loaded section, as
	// {x0,y0,z0,x1,y1,z1}. This is Luanti's active block list under another
	// name: a sweep over the map -- an ABM -- runs where the map is loaded,
	// and takes one section at a time because the whole world at once is
	// more voxels than one region read is allowed.
	static int l_active_boxes(lua_State *L)
	{
		Module *self = module_of(L);
		const pv::Vector3DInt16 &size = self->m_section_size;
		lua_newtable(L);
		if(size.getX() <= 0 || !self->m_scene)
			return 1;
		int n = 0;
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &section_p :
					world->get_loaded_sections()){
				if(!self->is_section_active(section_p))
					continue;
				pv::Region r = world->get_section_region_voxels(section_p);
				const int32_t v[6] = {
					r.getLowerCorner().getX(), r.getLowerCorner().getY(),
					r.getLowerCorner().getZ(), r.getUpperCorner().getX(),
					r.getUpperCorner().getY(), r.getUpperCorner().getZ(),
				};
				lua_createtable(L, 6, 0);
				for(int i = 0; i < 6; i++){
					lua_pushinteger(L, v[i]);
					lua_rawseti(L, -2, i + 1);
				}
				lua_rawseti(L, -2, ++n);
			}
		});
		return 1;
	}

	// __luanti_show_objects{id, x, y, z, sx, sy, sz, yaw, ...}: where every
	// object is and how big it is, once per step, to every client. What one
	// looks like is the client half's, and __luanti_show_object_props says
	// which look it wears; this is only where they are.
	static int l_show_objects(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		size_t n = lua_objlen(L, 1);
		sv_<double> v(n, 0.0);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			v[i] = lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		self->show_objects(v);
		return 0;
	}

	// __luanti_show_object_props{id, kind, texture, ...}: what an object
	// looks like, sent when it changes rather than every step. kind is the
	// shape the client half draws; see appearance_of() in lua/entity.lua.
	static int l_show_object_props(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 1);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		self->broadcast("luanti:object_props", os.str());
		return 0;
	}

	// To every client there is: what the objects look like and where they
	// are is everybody's, unlike an inventory or a form
	void broadcast(const ss_ &name, const ss_ &data)
	{
		network::access(m_server, [&](network::Interface *inetwork){
			for(network::PeerInfo::Id peer : inetwork->list_peers())
				inetwork->send(peer, name, data);
		});
	}

	void show_objects(const sv_<double> &v)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(v);
		}
		broadcast("luanti:objects", os.str());
	}

	// __luanti_send_inventory(player_name, {list, size, item, item, ...}):
	// what a player is carrying, to their own client. The strings are flat
	// -- a list's name, how many slots it has, and then that many item
	// strings -- because that is what a cereal array of strings is, and
	// because the client half reads them straight back into lists.
	static int l_send_inventory(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_inventory(name, flat);
		return 0;
	}

	void send_inventory(const ss_ &name, const sv_<ss_> &flat)
	{
		send_to_player(name, "luanti:inventory", flat);
	}

	// An array of strings to one player's client, or nowhere if that name is
	// not on the other end of one
	void send_to_player(const ss_ &name, const ss_ &packet_name,
			const sv_<ss_> &flat)
	{
		auto it = m_player_peers.find(name);
		if(it == m_player_peers.end())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(it->second, packet_name, os.str());
		});
	}

	// __luanti_show_formspec(player_name, formname, spec): the window a mod
	// puts on a player's screen. An empty spec takes it away, which is what
	// core.close_formspec() is. The client draws it and sends back what was
	// pressed; see luanti:fields below.
	static int l_show_formspec(lua_State *L)
	{
		Module *self = module_of(L);
		sv_<ss_> flat;
		for(int i = 1; i <= 4; i++){
			size_t len = 0;
			const char *p = luaL_checklstring(L, i, &len);
			flat.push_back(ss_(p ? p : "", len));
		}
		ss_ name = flat[0];
		flat.erase(flat.begin());
		self->send_to_player(name, "luanti:formspec", flat);
		return 0;
	}

	// __luanti_send_node_inventory(player_name, {pos, list, size, item, ...}):
	// what is in the node the player's open form is about, to that one
	// client. The position leads because it is what says which node the
	// lists belong to; the rest is shaped the way a player's own lists are.
	static int l_send_node_inventory(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:node_inventory", flat);
		return 0;
	}

	// __luanti_player_formspec(player_name, spec): the form the player's own
	// inventory key opens, which is theirs until a mod changes it. Sent when
	// it changes rather than when it is asked for, because a client that has
	// it can open it without a round trip.
	static int l_player_formspec(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, spec_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *spec_p = luaL_checklstring(L, 2, &spec_len);
		sv_<ss_> flat;
		flat.push_back(ss_(spec_p ? spec_p : "", spec_len));
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:player_formspec", flat);
		return 0;
	}

	// What the client sends back when a form's button is pressed: the form's
	// name and then the fields, a name and a value each.
	void on_fields(const network::Packet &packet)
	{
		auto who = m_peer_players.find(packet.sender);
		if(who == m_peer_players.end())
			return;
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:fields: %s", e.what());
			return;
		}
		if(flat.empty())
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__player_receive_fields");
		lua_pushlstring(L, who->second.c_str(), who->second.size());
		lua_pushlstring(L, flat[0].c_str(), flat[0].size());
		lua_createtable(L, 0, (int)(flat.size() / 2));
		for(size_t i = 1; i + 1 < flat.size(); i += 2){
			lua_pushlstring(L, flat[i + 1].c_str(), flat[i + 1].size());
			lua_setfield(L, -2, flat[i].c_str());
		}
		if(lua_pcall(L, 3, 0, 0) != 0){
			log_w(MODULE, "__player_receive_fields(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// A stack picked up in one slot and put down in another. The strings are
	// what the move is; lua/entity.lua says what they mean.
	void on_inv_action(const network::Packet &packet)
	{
		auto who = m_peer_players.find(packet.sender);
		if(who == m_peer_players.end())
			return;
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:inv_action: %s", e.what());
			return;
		}
		if(flat.empty())
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__inventory_action");
		lua_pushlstring(L, who->second.c_str(), who->second.size());
		lua_createtable(L, (int)flat.size(), 0);
		for(size_t i = 0; i < flat.size(); i++){
			lua_pushlstring(L, flat[i].c_str(), flat[i].size());
			lua_rawseti(L, -2, (int)i + 1);
		}
		if(lua_pcall(L, 2, 0, 0) != 0){
			log_w(MODULE, "__inventory_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		}
		lua_settop(L, base);
	}

	// Every object's look, for a client that has just arrived: the props are
	// sent when they change and a client that was not there missed them.
	void on_get_object_props(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__object_appearances");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:object_props", os.str());
		});
		log_v(MODULE, "C%zu: %zu object looks", (size_t)packet.sender,
				flat.size() / 3);
	}

	// A core.__<name>() that answers with an array of strings, as a vector
	sv_<ss_> string_list_from_lua(const char *name)
	{
		sv_<ss_> flat;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, name);
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "%s(): %s", name,
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return flat;
		}
		size_t n = lua_objlen(L, -1);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, -1, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		return flat;
	}

	// What an item looks like, as the texture modifier expression the client
	// composes: its inventory image, or the first tile of the node it
	// places. Asked for the way the texmods are.
	//
	// simplified: one expression per item, so a node is drawn as one of its
	// tiles rather than as the little cube Luanti draws. The upgrade path is
	// sending the three tiles a cube shows and shearing them client-side,
	// which extensions/luanti_client does.
	void on_get_item_images(const network::Packet &packet)
	{
		sv_<ss_> flat;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__item_images");
			if(lua_pcall(L, 0, 1, 0) != 0){
				log_w(MODULE, "__item_images(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return;
			}
			size_t n = lua_objlen(L, -1);
			flat.reserve(n);
			for(size_t i = 0; i < n; i++){
				lua_rawgeti(L, -1, (int)i + 1);
				size_t len = 0;
				const char *p = lua_tolstring(L, -1, &len);
				flat.push_back(ss_(p ? p : "", p ? len : 0));
				lua_pop(L, 1);
			}
			lua_settop(L, base);
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:item_images", os.str());
		});
		log_v(MODULE, "C%zu: %zu item images", (size_t)packet.sender,
				flat.size() / 2);
	}

	// __luanti_find_ids(x0,y0,z0,x1,y1,z1, {ids, ids, ...})
	//         -> {{x,y,z, x,y,z, ...}, ...}, one list per set of ids
	//
	// The same read as __luanti_get_region, with the match done here: what a
	// sweep over the map wants is the handful of voxels that are of a kind,
	// not a table of a quarter of a million names it then walks. Many sets
	// at once because the read is what a sweep costs and every rule that is
	// due can share one. Flat lists because three numbers per hit is cheaper
	// than a table per hit, and the caller is the one loop that cares.
	static int l_find_ids(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		size_t n_sets = lua_objlen(L, 7);
		if(n_sets > 32)
			return luaL_error(L, "find_ids(): at most 32 sets at a time");
		lua_createtable(L, (int)n_sets, 0);
		for(size_t si = 1; si <= n_sets; si++){
			lua_newtable(L);
			lua_rawseti(L, -2, (int)si);
		}
		if(n_sets == 0 || x1 < x0 || y1 < y0 || z1 < z0)
			return 1;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "find_ids(): %.0f voxels is more than the "
					"%d this reads at once", volume, (int)MAX_REGION_VOXELS);
		}
		// A Luanti node id is 16 bits, so which sets an id is in is one word
		// per id and the test in the loop is one load
		sv_<uint32_t> in_sets(65536, 0);
		bool any = false;
		for(size_t si = 1; si <= n_sets; si++){
			lua_rawgeti(L, 7, (int)si);
			luaL_checktype(L, -1, LUA_TTABLE);
			size_t n_ids = lua_objlen(L, -1);
			for(size_t i = 1; i <= n_ids; i++){
				lua_rawgeti(L, -1, (int)i);
				lua_Integer id = lua_tointeger(L, -1);
				lua_pop(L, 1);
				if(id < 0 || id > 65535)
					continue;
				in_sets[id] |= 1u << (si - 1);
				any = true;
			}
			lua_pop(L, 1);
		}
		if(!any)
			return 1;
		sv_<uint32_t> words;
		self->read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		int n[32] = {0};
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			uint32_t sets = in_sets[f.id.get(words[i])];
			while(sets){
				int si = 0;
				while(!(sets & (1u << si)))
					si++;
				sets &= ~(1u << si);
				lua_rawgeti(L, -1, si + 1);
				lua_pushinteger(L, x);
				lua_rawseti(L, -2, ++n[si]);
				lua_pushinteger(L, y);
				lua_rawseti(L, -2, ++n[si]);
				lua_pushinteger(L, z);
				lua_rawseti(L, -2, ++n[si]);
				lua_pop(L, 1);
			}
		}
		return 1;
	}

	static int l_get_region(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		if(x1 < x0 || y1 < y0 || z1 < z0){
			lua_newtable(L);
			return 1;
		}
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "get_region(): %.0f voxels is more than the "
					"%d this reads at once", volume, (int)MAX_REGION_VOXELS);
		}
		sv_<uint32_t> words;
		self->read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		lua_createtable(L, (int)words.size(), 0);
		for(size_t i = 0; i < words.size(); i++){
			lua_pushinteger(L, (lua_Integer)f.id.get(words[i]));
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	// Interface

	// The id this run gave a Luanti node name, or the one "unknown" has.
	// Asked of Lua, because the aliases and the content ids are its tables.
	uint32_t import_content_id(const ss_ &name, bool &known)
	{
		auto it = m_import_ids.find(name);
		if(it != m_import_ids.end()){
			known = it->second.second;
			return it->second.first;
		}
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__content_id_or_unknown");
		lua_pushstring(L, name.c_str());
		uint32_t id = 0;
		known = false;
		if(lua_pcall(L, 1, 2, 0) != 0){
			log_w(MODULE, "__content_id_or_unknown(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		} else {
			id = (uint32_t)lua_tonumber(L, -2);
			known = lua_toboolean(L, -1) != 0;
		}
		lua_settop(L, base);
		m_import_ids[name] = {id, known};
		return id;
	}

	// The clock a Luanti world was left at: env_meta.txt, which is lines of
	// "key = value" and then EnvArgsEnd. Three of them are the clock and the
	// rest is the object and LBM bookkeeping that has no meaning here yet.
	void import_clock(const ss_ &luanti_world_path)
	{
		ss_ path = luanti_world_path+"/env_meta.txt";
		std::ifstream ifs(path.c_str(), std::ios::binary);
		if(!ifs.good()){
			log_v(MODULE, "import_world(): no env_meta.txt; the clock stays "
					"where it was");
			return;
		}
		double time_of_day = -1, game_time = -1, day_count = -1;
		ss_ line;
		while(std::getline(ifs, line)){
			if(!line.empty() && line[line.size() - 1] == '\r')
				line.resize(line.size() - 1);
			if(line == "EnvArgsEnd")
				break;
			size_t eq = line.find(" = ");
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			ss_ value = line.substr(eq + 3);
			if(key == "time_of_day")
				time_of_day = atof(value.c_str());
			else if(key == "game_time")
				game_time = atof(value.c_str());
			else if(key == "day_count")
				day_count = atof(value.c_str());
		}
		if(time_of_day < 0 && game_time < 0 && day_count < 0){
			log_w(MODULE, "import_world(): %s says nothing about the clock",
					cs(path));
			return;
		}
		// Luanti's day is 24000 units long and this module's is one
		double tod = time_of_day < 0 ? 0.5 : time_of_day / 24000.0;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__set_clock");
		lua_pushnumber(L, tod);
		lua_pushnumber(L, game_time < 0 ? 0 : game_time);
		lua_pushnumber(L, day_count < 0 ? 0 : day_count);
		if(lua_pcall(L, 3, 0, 0) != 0)
			log_w(MODULE, "import_world(): __set_clock(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		lua_settop(L, base);
		log_i(MODULE, "import_world(): the clock it was left at: day %i, "
				"time %.4f, %.0f seconds played", (int)day_count, tod,
				game_time);
	}

	// A Luanti world's mod_storage.sqlite: what its mods remember, per mod,
	// into the files this module keeps a mod's storage in.
	// A Luanti world's players.sqlite: where each player stood, which way
	// they looked, their health and breath, what a mod wrote on them and
	// what they carried. The save has somewhere to put one now -- step 5d of
	// doc/plan/world_persistence_plan.md -- and this is the other half.
	//
	// simplified: the sqlite database only. Luanti still reads a world whose
	// players are one text file each under players/, and writing that reader
	// is worth it when a world that has one turns up.
	void import_players(const ss_ &luanti_world_path)
	{
		ss_ db_path = luanti_world_path+"/players.sqlite";
		if(!interface::fs::path_exists(db_path))
			return;
		sqlite3 *db = nullptr;
		if(sqlite3_open_v2(db_path.c_str(), &db, SQLITE_OPEN_READONLY,
				nullptr) != SQLITE_OK){
			log_w(MODULE, "import_world(): %s: %s", cs(db_path),
					db ? sqlite3_errmsg(db) : "cannot open");
			sqlite3_close(db);
			return;
		}
		struct Player {
			double pitch = 0.0, yaw = 0.0;
			double x = 0.0, y = 0.0, z = 0.0;
			int hp = 20, breath = 10;
			sm_<ss_, ss_> fields;
			// The list's name, and the item string of each slot in it. The
			// slots are kept by index because a database row says which one
			// it is and an empty slot has no row at all.
			sm_<ss_, sm_<int, ss_>> lists;
			sm_<ss_, int> list_sizes;
		};
		sm_<ss_, Player> players;
		auto query = [&](const char *sql,
				const std::function<void(sqlite3_stmt*)> &row){
			sqlite3_stmt *st = nullptr;
			if(sqlite3_prepare_v2(db, sql, -1, &st, nullptr) != SQLITE_OK){
				log_w(MODULE, "import_world(): %s: %s", cs(db_path),
						sqlite3_errmsg(db));
				return;
			}
			while(sqlite3_step(st) == SQLITE_ROW)
				row(st);
			sqlite3_finalize(st);
		};
		auto text = [](sqlite3_stmt *st, int i){
			const char *p = (const char*)sqlite3_column_blob(st, i);
			int n = sqlite3_column_bytes(st, i);
			return ss_(p ? p : "", (size_t)(n > 0 ? n : 0));
		};
		// Luanti keeps a player's position in BS units, which is nodes times
		// ten, and their angles in degrees; a node and a radian is what
		// everything on this side of the import is in.
		query("SELECT name, pitch, yaw, posX, posY, posZ, hp, breath"
				" FROM player", [&](sqlite3_stmt *st){
			Player &p = players[text(st, 0)];
			const double DEG_TO_RAD = 3.14159265358979323846 / 180.0;
			p.pitch = sqlite3_column_double(st, 1) * DEG_TO_RAD;
			p.yaw = sqlite3_column_double(st, 2) * DEG_TO_RAD;
			p.x = sqlite3_column_double(st, 3) / 10.0;
			p.y = sqlite3_column_double(st, 4) / 10.0;
			p.z = sqlite3_column_double(st, 5) / 10.0;
			p.hp = sqlite3_column_int(st, 6);
			p.breath = sqlite3_column_int(st, 7);
		});
		if(players.empty()){
			sqlite3_close(db);
			return;
		}
		query("SELECT player, metadata, value FROM player_metadata",
				[&](sqlite3_stmt *st){
			auto it = players.find(text(st, 0));
			if(it != players.end())
				it->second.fields[text(st, 1)] = text(st, 2);
		});
		// inv_id is which list it is and inv_name what it is called; an
		// unnamed one is "main", which is what Luanti's own default is
		sm_<ss_, sm_<int, ss_>> list_names;
		query("SELECT player, inv_id, inv_name, inv_size"
				" FROM player_inventories", [&](sqlite3_stmt *st){
			ss_ who = text(st, 0);
			auto it = players.find(who);
			if(it == players.end())
				return;
			ss_ name = text(st, 2);
			if(name == "")
				name = "main";
			list_names[who][sqlite3_column_int(st, 1)] = name;
			it->second.list_sizes[name] = sqlite3_column_int(st, 3);
		});
		query("SELECT player, inv_id, slot_id, item"
				" FROM player_inventory_items", [&](sqlite3_stmt *st){
			ss_ who = text(st, 0);
			auto it = players.find(who);
			if(it == players.end())
				return;
			auto names = list_names.find(who);
			if(names == list_names.end())
				return;
			auto name = names->second.find(sqlite3_column_int(st, 1));
			if(name == names->second.end())
				return;
			// Luanti counts a slot from zero and everything Lua-side counts
			// from one
			it->second.lists[name->second][sqlite3_column_int(st, 2) + 1] =
					text(st, 3);
		});
		sqlite3_close(db);
		size_t imported = 0;
		for(const auto &pair : players){
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			const Player &p = pair.second;
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__import_player");
			lua_pushstring(L, pair.first.c_str());
			lua_newtable(L);
			auto set_number = [&](const char *key, double value){
				lua_pushnumber(L, value);
				lua_setfield(L, -2, key);
			};
			lua_newtable(L);
			set_number("x", p.x);
			set_number("y", p.y);
			set_number("z", p.z);
			lua_setfield(L, -2, "pos");
			lua_newtable(L);
			set_number("h", p.yaw);
			set_number("v", p.pitch);
			lua_setfield(L, -2, "look");
			set_number("hp", p.hp);
			set_number("breath", p.breath);
			lua_createtable(L, 0, (int)p.fields.size());
			for(const auto &f : p.fields){
				lua_pushlstring(L, f.second.c_str(), f.second.size());
				lua_setfield(L, -2, f.first.c_str());
			}
			lua_setfield(L, -2, "fields");
			lua_createtable(L, 0, (int)p.list_sizes.size());
			for(const auto &list : p.list_sizes){
				int size = list.second;
				lua_createtable(L, size, 0);
				auto items = p.lists.find(list.first);
				for(int i = 1; i <= size; i++){
					ss_ item;
					if(items != p.lists.end()){
						auto slot = items->second.find(i);
						if(slot != items->second.end())
							item = slot->second;
					}
					lua_pushlstring(L, item.c_str(), item.size());
					lua_rawseti(L, -2, i);
				}
				lua_setfield(L, -2, list.first.c_str());
			}
			lua_setfield(L, -2, "inventory");
			if(lua_pcall(L, 2, 1, 0) != 0){
				log_w(MODULE, "__import_player(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			} else if(lua_toboolean(L, -1)){
				imported++;
			}
			lua_settop(L, base);
		}
		log_i(MODULE, "import_world(): %zu of %zu players", imported,
				players.size());
	}

	void import_mod_storage(const ss_ &luanti_world_path)
	{
		ss_ db_path = luanti_world_path+"/mod_storage.sqlite";
		if(!interface::fs::path_exists(db_path))
			return;
		sqlite3 *db = nullptr;
		if(sqlite3_open_v2(db_path.c_str(), &db, SQLITE_OPEN_READONLY,
				nullptr) != SQLITE_OK){
			log_w(MODULE, "import_world(): %s: %s", cs(db_path),
					db ? sqlite3_errmsg(db) : "cannot open");
			sqlite3_close(db);
			return;
		}
		sqlite3_stmt *st = nullptr;
		if(sqlite3_prepare_v2(db,
				"SELECT modname, key, value FROM entries ORDER BY modname",
				-1, &st, nullptr) != SQLITE_OK){
			log_w(MODULE, "import_world(): %s: %s", cs(db_path),
					sqlite3_errmsg(db));
			sqlite3_close(db);
			return;
		}
		// Per mod, because that is the unit the storage is a file of
		sm_<ss_, sm_<ss_, ss_>> by_mod;
		while(sqlite3_step(st) == SQLITE_ROW){
			auto column = [&](int i){
				const char *p = (const char*)sqlite3_column_blob(st, i);
				int n = sqlite3_column_bytes(st, i);
				return ss_(p ? p : "", (size_t)(n > 0 ? n : 0));
			};
			by_mod[column(0)][column(1)] = column(2);
		}
		sqlite3_finalize(st);
		sqlite3_close(db);
		if(by_mod.empty())
			return;
		size_t written = 0;
		for(const auto &mod : by_mod){
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__import_mod_storage");
			lua_pushstring(L, mod.first.c_str());
			lua_createtable(L, 0, (int)mod.second.size());
			for(const auto &pair : mod.second){
				lua_pushlstring(L, pair.second.c_str(), pair.second.size());
				lua_setfield(L, -2, pair.first.c_str());
			}
			if(lua_pcall(L, 2, 1, 0) != 0){
				log_w(MODULE, "__import_mod_storage(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			} else {
				written += (size_t)lua_tonumber(L, -1);
			}
			lua_settop(L, base);
		}
		log_i(MODULE, "import_world(): %zu values of %zu mods' storage",
				written, by_mod.size());
	}

	// One node's metadata into the Lua table that holds it. The fields are
	// strings and an inventory is item strings, which is the same shape the
	// save keeps and the same function puts either back.
	void import_node_meta(int32_t x, int32_t y, int32_t z,
			const luanti_mapblock::NodeMeta &meta)
	{
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__set_node_meta");
		lua_createtable(L, 0, 3);
		lua_pushinteger(L, x);
		lua_setfield(L, -2, "x");
		lua_pushinteger(L, y);
		lua_setfield(L, -2, "y");
		lua_pushinteger(L, z);
		lua_setfield(L, -2, "z");
		lua_createtable(L, 0, (int)meta.fields.size());
		for(const auto &pair : meta.fields){
			lua_pushlstring(L, pair.second.c_str(), pair.second.size());
			lua_setfield(L, -2, pair.first.c_str());
		}
		lua_createtable(L, 0, (int)meta.lists.size());
		for(const auto &pair : meta.lists){
			lua_createtable(L, (int)pair.second.size(), 0);
			for(size_t i = 0; i < pair.second.size(); i++){
				lua_pushlstring(L, pair.second[i].c_str(),
						pair.second[i].size());
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, pair.first.c_str());
		}
		if(lua_pcall(L, 3, 0, 0) != 0)
			log_w(MODULE, "__set_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		lua_settop(L, base);
	}

	// Read a Luanti world into this one: the clock, and as much of the map
	// as this world has room for.
	//
	// One direction and read-only: the Luanti world is never written to. A
	// block that cannot be read is counted and skipped, because a world is
	// worth having with a hole in it, and a name this game does not register
	// becomes "unknown", which is a node you can see and dig rather than a
	// hole.
	//
	// simplified: the nodes and nothing else. Node metadata, the timers and
	// the static objects a block carries are walked past -- an imported
	// world starts without its chests' contents and without its entities.
	// Metadata wants the save that step 5c of the persistence plan is about,
	// and objects want a static_save that means something; both are named in
	// mapblock.h where they are skipped.
	void import_world(const ss_ &luanti_world_path)
	{
		if(!m_game_running)
			throw Exception("luanti: import_world() before run_game()");
		import_clock(luanti_world_path);
		import_mod_storage(luanti_world_path);
		import_players(luanti_world_path);
		ss_ db_path = luanti_world_path+"/map.sqlite";
		if(!interface::fs::path_exists(db_path))
			throw Exception("luanti: no map.sqlite in "+luanti_world_path);
		sqlite3 *db = nullptr;
		int rc = sqlite3_open_v2(db_path.c_str(), &db, SQLITE_OPEN_READONLY,
				nullptr);
		if(rc != SQLITE_OK){
			ss_ err = db ? sqlite3_errmsg(db) : "cannot open";
			sqlite3_close(db);
			throw Exception("luanti: "+db_path+": "+err);
		}
		// Two schemas exist: the older one keys a block by one integer, the
		// newer by three columns. Luanti reads both and so does this.
		sqlite3_stmt *st = nullptr;
		bool by_xyz = false;
		rc = sqlite3_prepare_v2(db, "SELECT pos, data FROM blocks", -1, &st,
				nullptr);
		if(rc != SQLITE_OK){
			by_xyz = true;
			rc = sqlite3_prepare_v2(db, "SELECT x, y, z, data FROM blocks",
					-1, &st, nullptr);
		}
		if(rc != SQLITE_OK){
			ss_ err = sqlite3_errmsg(db);
			sqlite3_close(db);
			throw Exception("luanti: "+db_path+": "+err);
		}
		// What this world has room for. A block that reaches outside is
		// clipped rather than dropped, so that the edge is where the world
		// ends and not where a block boundary is.
		const pv::Vector3DInt32 &s0 = m_section_region.getLowerCorner();
		const pv::Vector3DInt32 &s1 = m_section_region.getUpperCorner();
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t wx0 = s0.getX() * sx, wy0 = s0.getY() * sy,
				wz0 = s0.getZ() * sz;
		const int32_t wx1 = (s1.getX() + 1) * sx - 1,
				wy1 = (s1.getY() + 1) * sy - 1,
				wz1 = (s1.getZ() + 1) * sz - 1;
		size_t blocks_read = 0, blocks_outside = 0, blocks_failed = 0;
		size_t nodes_written = 0, meta_written = 0;
		set_<ss_> unknown_names;
		sm_<ss_, size_t> counts;
		ss_ first_error;
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		const int32_t BS = (int32_t)luanti_mapblock::BLOCK_SIDE;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			while(sqlite3_step(st) == SQLITE_ROW){
				pv::Vector3DInt16 bp;
				if(by_xyz){
					bp = pv::Vector3DInt16(
							(int16_t)sqlite3_column_int(st, 0),
							(int16_t)sqlite3_column_int(st, 1),
							(int16_t)sqlite3_column_int(st, 2));
				} else {
					bp = luanti_mapblock::block_pos_of_key(
							sqlite3_column_int64(st, 0));
				}
				const int data_column = by_xyz ? 3 : 1;
				int32_t bx = (int32_t)bp.getX() * BS;
				int32_t by = (int32_t)bp.getY() * BS;
				int32_t bz = (int32_t)bp.getZ() * BS;
				int32_t x0 = std::max(bx, wx0), x1 = std::min(bx + BS - 1, wx1);
				int32_t y0 = std::max(by, wy0), y1 = std::min(by + BS - 1, wy1);
				int32_t z0 = std::max(bz, wz0), z1 = std::min(bz + BS - 1, wz1);
				if(x1 < x0 || y1 < y0 || z1 < z0){
					blocks_outside++;
					continue;
				}
				const void *blob = sqlite3_column_blob(st, data_column);
				int blob_size = sqlite3_column_bytes(st, data_column);
				luanti_mapblock::Block block;
				try {
					ss_ data((const char*)blob, (size_t)blob_size);
					luanti_mapblock::deserialize_block(data, block);
				} catch(std::exception &e){
					blocks_failed++;
					if(first_error.empty())
						first_error = e.what();
					continue;
				}
				// The ids are the block's own; every block carries the
				// mapping it was written with
				sm_<uint16_t, uint32_t> ids;
				sm_<uint16_t, bool> is_ignore;
				for(const auto &pair : block.names){
					bool known = false;
					ids[pair.first] = import_content_id(pair.second, known);
					is_ignore[pair.first] = (pair.second == "ignore");
					if(!known)
						unknown_names.insert(pair.second);
				}
				sm_<uint16_t, const ss_*> names_by_id;
				for(const auto &pair : block.names)
					names_by_id[pair.first] = &pair.second;
				// The block as a volume and one write, rather than a
				// section and buffer lookup per voxel. A voxel this leaves
				// undefined -- an "ignore", which is Luanti for "nothing
				// has generated this" -- is a hole set_volume() skips.
				interface::VoxelVolume vol(pv::Region(
						pv::Vector3DInt32(x0, y0, z0),
						pv::Vector3DInt32(x1, y1, z1)));
				for(int32_t z = z0; z <= z1; z++)
				for(int32_t y = y0; y <= y1; y++)
				for(int32_t x = x0; x <= x1; x++){
					size_t i = (size_t)(x - bx) +
							(size_t)(y - by) * BS +
							(size_t)(z - bz) * BS * BS;
					uint16_t raw_id = block.param0[i];
					auto it = ids.find(raw_id);
					if(it == ids.end() || is_ignore[raw_id])
						continue; // Not generated there, so nothing to write
					uint32_t word = 0;
					f.id.set(word, it->second);
					f.light_sky.set(word, block.param1[i] & 0x0f);
					f.light_lamp.set(word, (block.param1[i] >> 4) & 0x0f);
					f.param.set(word, block.param2[i]);
					vol.setVoxelAt(x, y, z, interface::VoxelInstance(word));
					nodes_written++;
					counts[*names_by_id[raw_id]]++;
				}
				world->set_volume(vol, true);
				// What hangs off the nodes: a chest's contents, a sign's
				// text. Only for the part of the block that was written.
				for(const auto &pair : block.meta){
					int32_t mx = bx + (pair.first & 15);
					int32_t my = by + ((pair.first >> 4) & 15);
					int32_t mz = bz + ((pair.first >> 8) & 15);
					if(mx < x0 || mx > x1 || my < y0 || my > y1 ||
							mz < z0 || mz > z1)
						continue;
					import_node_meta(mx, my, mz, pair.second);
					meta_written++;
				}
				blocks_read++;
			}
		});
		sqlite3_finalize(st);
		sqlite3_close(db);
		log_i(MODULE, "import_world(): %zu blocks of %s read into the world, "
				"%zu nodes and %zu of them with metadata; %zu blocks outside "
				"it, %zu it could not read",
				blocks_read, cs(luanti_world_path), nodes_written,
				meta_written, blocks_outside, blocks_failed);
		if(!first_error.empty())
			log_w(MODULE, "import_world(): the first block it could not read: "
					"%s", cs(first_error));
		// What arrived, which is the cheapest thing to compare against what
		// Luanti says is in the same world
		sv_<std::pair<size_t, ss_>> by_count;
		for(const auto &pair : counts)
			by_count.push_back({pair.second, pair.first});
		std::sort(by_count.begin(), by_count.end(),
				[](const std::pair<size_t, ss_> &a,
						const std::pair<size_t, ss_> &b){
			return a.first > b.first;
		});
		ss_ top;
		for(size_t i = 0; i < by_count.size() && i < 5; i++)
			top += (i ? ", " : "") + by_count[i].second + " " +
					itos(by_count[i].first);
		if(!top.empty())
			log_i(MODULE, "import_world(): most of it is %s", cs(top));
		if(!unknown_names.empty()){
			ss_ names;
			size_t n = 0;
			for(const ss_ &name : unknown_names){
				if(n++ >= 8){
					names += ", ...";
					break;
				}
				names += (n > 1 ? ", " : "") + name;
			}
			log_w(MODULE, "import_world(): %zu node names this game does not "
					"register are drawn as unknown: %s",
					unknown_names.size(), cs(names));
		}
	}

	void run_game(const ss_ &game_path, storage::Save *save)
	{
		if(m_game_running)
			throw Exception("luanti: run_game() called twice");
		if(!save)
			throw Exception("luanti: run_game() without a save; the world is "
					"the save");
		m_save = save;
		m_store = save->store("luanti");
		// A directory of the save's rather than the save's own root, so that
		// a mod writing through core.get_worldpath() cannot land on
		// save.sqlite or on anything else of ours it does not expect to be
		// there. devtest's testnodes mod writes a PNG through it while it
		// loads, so this is not hypothetical.
		ss_ world_path = save->path()+"/luanti";
		interface::fs::create_directories(world_path);
		log_i(MODULE, "run_game(): game=%s world=%s",
				cs(game_path), cs(world_path));

		m_lua = luaL_newstate();
		if(!m_lua)
			throw Exception("luanti: cannot create a Lua state");
		luaL_openlibs(m_lua);

		set_global_cfunction("__luanti_log", l_log);
		set_global_cfunction("__luanti_get_us_time", l_get_us_time);
		set_global_cfunction("__luanti_list_dir", l_list_dir);
		set_global_cfunction("__luanti_create_directories", l_create_directories);
		set_global_cfunction("__luanti_encode_png", l_encode_png);
		set_global_cfunction("__luanti_sha1", l_sha1);
		set_global_cfunction("__luanti_sha256", l_sha256);
		set_global_cfunction("__luanti_compress", l_compress);
		set_global_cfunction("__luanti_decompress", l_decompress);
		set_global_cfunction("__luanti_set_node", l_set_node);
		set_global_cfunction("__luanti_get_node", l_get_node);
		set_global_cfunction("__luanti_get_region", l_get_region);
		set_global_cfunction("__luanti_active_boxes", l_active_boxes);
		set_global_cfunction("__luanti_find_ids", l_find_ids);
		set_global_cfunction("__luanti_show_objects", l_show_objects);
		set_global_cfunction("__luanti_show_object_props",
				l_show_object_props);
		set_global_cfunction("__luanti_send_inventory", l_send_inventory);
		set_global_cfunction("__luanti_show_formspec", l_show_formspec);
		set_global_cfunction("__luanti_player_formspec", l_player_formspec);
		set_global_cfunction("__luanti_send_node_inventory",
				l_send_node_inventory);
		lua_pushlightuserdata(m_lua, (void*)this);
		lua_setfield(m_lua, LUA_REGISTRYINDEX, "__luanti_module");
		set_global_string("__luanti_module_path", module_path());
		set_global_string("__luanti_cache_path", luanti_cache_path());
		set_global_string("__luanti_game_path", game_path);
		set_global_string("__luanti_world_path", world_path);

		// Ours first: it is what builds the core table the vendored builtin
		// then expects to be there
		run_chunk_file(module_path()+"/lua/bootstrap.lua");
		run_chunk_file(module_path()+"/vendor/builtin/init.lua");
		for(const auto &pair : m_pending_lua)
			run_chunk_string(pair.first, pair.second);
		m_pending_lua.clear();
		// Before the mods load, because a mod can ask the time while it
		// does, and after the builtin, because that is where the clock is
		load_clock();

		run_chunk_file(module_path()+"/lua/modloader.lua");

		// After the mods, because what the metadata holds is item strings
		// and a mod's items have to be registered for one to mean anything
		load_node_meta();
		load_players();
		run_chunk_string("core.__check_players() "
				"core.__check_inventory_move()", "check_players");

		check_shapes();
		check_mapblock();
		check_media_names();

		// The game's own media before the registry, because what a node's
		// tiles can be depends on which files were actually shipped
		serve_game_media(game_path);

		// The registry, the world and the light, in that order: the ids the
		// mods asked for while loading are the ids the definitions are built
		// under, and the definitions have to exist before anything is lit.
		create_world();
		check_map_round_trip();

		m_game_running = true;

		m_server->emit_event("luanti:game_loaded", new GameLoaded(m_scene));
	}

	void load_lua(const ss_ &chunk, const ss_ &chunkname)
	{
		if(m_game_running)
			throw Exception("luanti: load_lua() after run_game(); whatever "
					"extends the environment is registered before the game "
					"runs");
		m_pending_lua.push_back({chunk, chunkname});
	}

	// A string that is going into a chunk of Lua as a quoted one. What the
	// caller hands over is a name from the network, and a chunk is code.
	static ss_ lua_quoted(const ss_ &s)
	{
		ss_ out;
		for(char c : s){
			if(c == '"' || c == '\\')
				out += '\\';
			if(c == '\n' || c == '\r')
				continue;
			out += c;
		}
		return out;
	}

	// A chunk of Lua run for its answer, which is how core.dig_node()
	// reaches a game's own click handler from outside Lua
	bool node_action(const ss_ &chunk)
	{
		if(!m_game_running)
			return false;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_pushcfunction(L, l_traceback);
		if(luaL_loadbuffer(L, chunk.c_str(), chunk.size(), "node_action") != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		if(lua_pcall(L, 0, 1, base + 1) != 0){
			log_w(MODULE, "node_action(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return false;
		}
		bool ok = lua_toboolean(L, -1) != 0;
		lua_settop(L, base);
		return ok;
	}

	// A client arrives and leaves, and says where it is. A player is what
	// Luanti calls whoever is on the other end of one: the name is the
	// caller's to choose and is what everything about the player is keyed
	// by. The callbacks a mod registers for a join and a leave run here.
	void add_player(const ss_ &name, size_t peer)
	{
		m_player_peers[name] = peer;
		m_peer_players[peer] = name;
		// At the origin until the client says otherwise, which is where a
		// player is put anyway and what keeps the world around them loaded
		// from the moment they are one
		if(!m_player_pos.count(name))
			m_player_pos[name] = pv::Vector3DInt32(0, 0, 0);
		node_action("core.__add_player(\""+lua_quoted(name)+"\") return true");
	}

	void remove_player(const ss_ &name)
	{
		node_action("core.__remove_player(\""+lua_quoted(name)+
				"\") return true");
		auto it = m_player_peers.find(name);
		if(it != m_player_peers.end()){
			m_peer_players.erase(it->second);
			m_player_peers.erase(it);
		}
		// The world stops being kept loaded around where they were
		m_player_pos.erase(name);
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v)
	{
		// What the world streams around and what is active near; the step
		// reads it, so this only writes it down
		m_player_pos[name] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__set_player_pos(\"%s\", %f, %f, %f, %f, %f) "
				"return true",
				lua_quoted(name).c_str(), (double)x, (double)y, (double)z,
				(double)look_h, (double)look_v);
		node_action(buf);
	}

	bool dig_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		// The digger is who the drops go to: core.handle_node_drops() puts
		// them in a player's inventory and on the ground for anyone else.
		// An empty name is nobody, which is what it was before there were
		// players.
		ss_ digger = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		return node_action("return core.__dig_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+digger+")");
	}

	bool place_node(int32_t ux, int32_t uy, int32_t uz,
			int32_t ax, int32_t ay, int32_t az, const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		return node_action("return core.__use_node(\""+
				lua_quoted(player_name)+"\", "
				"{x = "+itos(ux)+", y = "+itos(uy)+", z = "+itos(uz)+"}, "
				"{x = "+itos(ax)+", y = "+itos(ay)+", z = "+itos(az)+"})");
	}

	SceneReference get_scene()
	{
		return m_scene;
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_luanti(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
