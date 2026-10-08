// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
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
#include "worldgen/api.h"
#include "luanti_mapgen/api.h"
#include "storage/api.h"
#include "main_context/api.h"
#include "client_file/api.h"
#include "network/api.h"
#include "accounts/api.h"
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
#include "interface/noise.h"
#include "luanti/mapblock.h"
#include <sqlite3.h>
#include <fstream>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <unordered_map>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cereal/archives/portable_binary.hpp>
#include <cereal/types/vector.hpp>
#include <cereal/types/string.hpp>
extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
#include <luajit.h>
}
// LuaJIT's bit library, which Luanti's mods use as if it were part of the
// language. Luanti loads this same file -- Mike Pall's Lua BitOp -- when it
// is not running on LuaJIT, and the Lua here is Urho3D's 5.1, so it always
// does. A module is one translation unit, so the implementation comes in
// with the header.
#include "vendor/bitop/bit.h"
#include "vendor/bitop/bit.cpp"
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
#include <Image.h>
#include <MemoryBuffer.h>
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

// Boxes, six numbers each, turned the same way and clamped to the voxel's
// own cube. simplified: what reaches outside the cube -- a fence's 1.5 --
// is cut off, because the client's physics asks each cell for its own
// boxes; a fence stays as tall as the cube it was.
static void turn_boxes(const sv_<float> &in, uint8_t d, sv_<float> &out)
{
	int m[3][3] = {};
	facedir_matrix(d, m);
	out.clear();
	for(size_t b = 0; b + 6 <= in.size(); b += 6){
		float t[2][3];
		for(size_t c = 0; c < 2; c++){
			for(size_t r = 0; r < 3; r++){
				float v = 0;
				for(size_t k = 0; k < 3; k++)
					v += m[r][k] * in[b + c * 3 + k];
				t[c][r] = std::min(0.5f, std::max(-0.5f, v));
			}
		}
		for(size_t c = 0; c < 2; c++)
			for(size_t r = 0; r < 3; r++)
				out.push_back(c == 0 ? std::min(t[0][r], t[1][r]) :
						std::max(t[0][r], t[1][r]));
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
	// A plantlike node's meshoptions: the shape in bits 0-2 and the 1.4x
	// size in bit 4 ([PLANT_SIZE]); the random offset and the random dip
	// (bits 3 and 5) want the position and are not a variant --
	// simplified: they are drawn as the plain shape
	if(facing == "meshoptions")
		return 16;
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
	if(facing == "meshoptions")
		return (uint8_t)((param & 0x07) | ((param & 0x10) ? 8 : 0));
	return 0;
}

// One picture placed into a "[combine:WxH:x,y=file:x,y=file" expression
struct CombinePlace
{
	int x = 0, y = 0;
	ss_ name;
};

// What that expression says, or false if it is not one: no nesting, and
// what is placed is a file name rather than a modifier of its own. See
// palette_image(), which is the only thing that needs a modifier composed
// on this side at all.
static bool parse_combine(const ss_ &expr, int &w_out, int &h_out,
		sv_<CombinePlace> &out)
{
	static const ss_ COMBINE = "[combine:";
	if(expr.compare(0, COMBINE.size(), COMBINE) != 0)
		return false;
	sv_<ss_> parts;
	for(size_t at = COMBINE.size(); at <= expr.size(); ){
		size_t end = expr.find(':', at);
		if(end == ss_::npos)
			end = expr.size();
		parts.push_back(expr.substr(at, end - at));
		at = end + 1;
	}
	int w = 0, h = 0;
	if(parts.empty() || sscanf(cs(parts[0]), "%dx%d", &w, &h) != 2 ||
			w <= 0 || h <= 0 || w > 1024 || h > 1024)
		return false;
	sv_<CombinePlace> places;
	for(size_t i = 1; i < parts.size(); i++){
		CombinePlace place;
		int file_at = 0;
		if(sscanf(cs(parts[i]), "%d,%d=%n", &place.x, &place.y,
				&file_at) < 2 || file_at <= 0 ||
				(size_t)file_at >= parts[i].size())
			return false;
		place.name = parts[i].substr(file_at);
		places.push_back(place);
	}
	if(places.empty())
		return false;
	out = places;
	w_out = w;
	h_out = h;
	return true;
}

// A sampling profiler for the module's Lua, behind BUILDAT_LUANTI_LUAPROF.
//
// What it answers is a porter's question -- which of my two hundred mods,
// and which function in it, is costing the startup or the step -- and it
// answers it on a build they already have: set the variable and read the
// report at shutdown. A tool that wants a rebuild is a tool nobody uses.
//
// Sampling rather than LUA_MASKCALL: an instrumenting hook distorts exactly
// the small hot functions this is looking for, and the count hook is one
// branch per N instructions. The default N is 10000, which is about a
// percent of the run's time on this machine; BUILDAT_LUANTI_LUAPROF=<n>
// sets it.
//
// One state, one thread, so a plain map and no locking. Attribution is to
// the function the sample landed in -- short_src:linedefined -- which is
// what a name means in Lua once a mod has built half its callbacks out of
// closures.
struct LuaProfiler
{
	bool enabled = false;
	int interval = 10000;
	sm_<ss_, size_t> samples;
	size_t total = 0;
};
static LuaProfiler g_lua_prof;

// A step that has not come back. The module's thread does one thing at a
// time, so a step that runs for minutes is a server that answers nothing --
// and the step's own timing line cannot say so, because it prints when the
// step ends. This says it while it is still going, once, with the Lua stack
// it is standing on.
//
// It rides the same count hook as the profiler and costs a comparison per N
// instructions. The interval is coarse when nothing is being profiled,
// because all this needs is to notice within a second or two of a deadline
// that is tens of seconds long.
struct StepWatchdog
{
	int64_t deadline_us = 0;
	bool warned = false;
	int64_t started_us = 0;
};
static StepWatchdog g_step_watch;

static void lua_step_watchdog(lua_State *L)
{
	if(g_step_watch.deadline_us == 0 || g_step_watch.warned)
		return;
	const int64_t now = interface::os::time_us();
	if(now < g_step_watch.deadline_us)
		return;
	g_step_watch.warned = true;
	log_w(MODULE, "a step has been running for %.0f s and has not come "
			"back; where its Lua is standing now:",
			(now - g_step_watch.started_us) / 1e6);
	lua_Debug d;
	for(int level = 0; level < 24; level++){
		if(!lua_getstack(L, level, &d))
			break;
		if(!lua_getinfo(L, "Sln", &d))
			break;
		log_w(MODULE, "  #%d %s:%d %s%s", level, d.short_src, d.currentline,
				d.name != nullptr ? d.name : "?",
				d.name != nullptr ? "()" : "");
	}
}

// __luanti_bounded_pcall(f, budget) -> ok, result: f run interpreted --
// LuaJIT's compiled loops do not reach a count hook -- with an error after
// `budget` instructions, and the hook that was on (the watchdog, the
// profiler) put back as it was. Lua's own debug.sethook cannot do the last
// part: a C hook comes back from debug.gethook as a string. What
// core.deserialize runs saved data through ([SECURITY_RUN_1]).
static void bounded_hook(lua_State *L, lua_Debug *ar)
{
	luaL_error(L, "the data runs too long");
}

static int l_bounded_pcall(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TFUNCTION);
	const int budget = luaL_checkint(L, 2);
	lua_Hook old = lua_gethook(L);
	const int old_mask = lua_gethookmask(L);
	const int old_count = lua_gethookcount(L);
	luaJIT_setmode(L, 1, LUAJIT_MODE_ALLFUNC | LUAJIT_MODE_OFF);
	lua_sethook(L, bounded_hook, LUA_MASKCOUNT, budget > 0 ? budget : 1);
	lua_pushvalue(L, 1);
	const int r = lua_pcall(L, 0, 1, 0);
	lua_sethook(L, old, old_mask, old_count);
	lua_pushboolean(L, r == 0);
	lua_insert(L, -2);
	return 2;
}

static void lua_prof_hook(lua_State *L, lua_Debug *ar)
{
	lua_step_watchdog(L);
	if(!g_lua_prof.enabled)
		return;
	if(!lua_getinfo(L, "Sn", ar))
		return;
	ss_ key = ss_(ar->short_src) + ":" + itos(ar->linedefined);
	if(ar->name != nullptr)
		key += ss_(" ") + ar->name + "()";
	g_lua_prof.samples[key]++;
	g_lua_prof.total++;
}

// Every function the samples landed in, most first. Called at shutdown, and
// cheap enough to call whenever else somebody wants one -- which is what
// core.__lua_profile() is for: a run's startup, its world generation and
// its first minute with a player in it are three different questions, and
// one report over all of them answers none of them.
static void lua_prof_report(const ss_ &label = "")
{
	if(!g_lua_prof.enabled || g_lua_prof.total == 0)
		return;
	const ss_ tag = label.empty() ? ss_("Lua profile") :
			ss_("Lua profile [")+label+"]";
	sv_<std::pair<ss_, size_t>> sorted(
			g_lua_prof.samples.begin(), g_lua_prof.samples.end());
	std::sort(sorted.begin(), sorted.end(),
			[](const std::pair<ss_, size_t> &a,
					const std::pair<ss_, size_t> &b){
		return a.second > b.second;
	});
	log_i(MODULE, "%s: %zu samples, every %i instructions", cs(tag),
			g_lua_prof.total, g_lua_prof.interval);
	for(size_t i = 0; i < sorted.size() && i < 40; i++){
		const double share = 100.0 * sorted[i].second / g_lua_prof.total;
		if(share < 0.1)
			break;
		log_i(MODULE, "%s: %5.1f%% %6zu  %s", cs(tag), share,
				sorted[i].second, cs(sorted[i].first));
	}
}

// __luanti_copy_ints(dst, src) -> dst: src's array part into dst's, in C.
//
// A mod that hands VoxelManip:get_data() a buffer to fill is doing the
// thing Luanti's own documentation tells it to -- reusing one table
// instead of making half a million entries a chunk -- and Luanti fills it
// in C. Filled in Lua it was **a third of all the Lua time** a VoxeLibre
// world spent in its first fifteen seconds with a player in it, because a
// mapgen chunk is 512000 elements and the loop pays the interpreter for
// every one of them.
static int l_copy_ints(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	luaL_checktype(L, 2, LUA_TTABLE);
	const size_t n = lua_objlen(L, 2);
	for(size_t i = 1; i <= n; i++){
		lua_rawgeti(L, 2, (int)i);
		lua_rawseti(L, 1, (int)i);
	}
	lua_pushvalue(L, 1);
	return 1;
}

// The nested tables Luanti's NoiseMap:get_2d_map() and get_3d_map() answer
// with, built from the flat array in C.
//
// Luanti builds them in C too. Built with Lua loops they were 7.7% of the
// time VoxeLibre's two hundred mods took to load, because a mod that asks
// for a big map asks for a very big one -- mcl_end_island's is 401 x 30 x
// 401, which is four and a half million entries and as many table writes.
//
// __luanti_nest_2d(flat, sx, sy) -> out[y][x], and
// __luanti_nest_3d(flat, sx, sy, sz) -> out[x][y][z], which are the two
// orders Luanti's own API builds them in.
static int l_nest_2d(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const int sx = (int)luaL_checkinteger(L, 2);
	const int sy = (int)luaL_checkinteger(L, 3);
	lua_createtable(L, sy, 0);
	for(int y = 1; y <= sy; y++){
		lua_createtable(L, sx, 0);
		for(int x = 1; x <= sx; x++){
			lua_rawgeti(L, 1, (y - 1) * sx + x);
			lua_rawseti(L, -2, x);
		}
		lua_rawseti(L, -2, y);
	}
	return 1;
}

static int l_nest_3d(lua_State *L)
{
	luaL_checktype(L, 1, LUA_TTABLE);
	const int sx = (int)luaL_checkinteger(L, 2);
	const int sy = (int)luaL_checkinteger(L, 3);
	const int sz = (int)luaL_checkinteger(L, 4);
	lua_createtable(L, sx, 0);
	for(int x = 1; x <= sx; x++){
		lua_createtable(L, sy, 0);
		for(int y = 1; y <= sy; y++){
			lua_createtable(L, sz, 0);
			for(int z = 1; z <= sz; z++){
				lua_rawgeti(L, 1, ((z - 1) * sy + (y - 1)) * sx + x);
				lua_rawseti(L, -2, z);
			}
			lua_rawseti(L, -2, y);
		}
		lua_rawseti(L, -2, x);
	}
	return 1;
}

// core.__lua_profile(label): what has been sampled since the last call,
// under a name, and then the counters start again. A probe calls it at the
// edges of whatever it wants measured.
static int l_lua_profile(lua_State *L)
{
	const char *label = lua_tostring(L, 1);
	lua_prof_report(label ? label : "");
	g_lua_prof.samples.clear();
	g_lua_prof.total = 0;
	return 0;
}

// Which colour a param2 picks out of a palette of this many colours.
// Luanti stretches a palette over the 256 param2 values -- each pixel fills
// 256/pixels of them -- so the colour changes only every step, and the bits
// below it are the direction. A sane game ships exactly as many colours as
// the bits above the direction can count, and then this is those bits.
static size_t palette_slot_of_param(size_t slots, uint8_t param)
{
	if(slots <= 1)
		return 0;
	size_t slot = (size_t)param / (256 / slots);
	return slot < slots ? slot : slots - 1;
}

// The facedir a variant of this kind stands for
static uint8_t facing_facedir(const ss_ &facing, size_t variant)
{
	if(facing == "wallmounted")
		return WALLMOUNTED_FACEDIR[variant & 7];
	// A plant's shape is not a turn of its tiles
	if(facing == "meshoptions")
		return 0;
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
	else if(level == "trace")
		log_t(MODULE, "%s", cs(text));
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

// Whether anything is at a path, file or directory. Luanti has
// core.path_exists() and a game uses it to decide whether its own data is
// there -- capturetheflag asks before reading each of its maps.
static int l_path_exists(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	bool exists = false;
	try {
		exists = interface::fs::path_exists(path);
	} catch(...){
		exists = false;
	}
	lua_pushboolean(L, exists);
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
	// What the server is doing while a game loads; see set_progress_handler()
	std::function<void(const ss_ &)> m_progress;
	// What the importer resolved a Luanti node name to, so that a world of
	// three hundred thousand blocks asks Lua once per name and not once per
	// node
	sm_<ss_, std::pair<uint32_t, bool>> m_import_ids;
	// The voxel a generated section is filled with; see
	// on_generation_request(). Zero until the first section is generated,
	// which is after the mods have loaded and named it.
	uint32_t m_singlenode_word = 0;
	// What the world's generator was built from, kept for the questions a
	// mapgen can answer without generating: where the ground is
	luanti_mapgen::Params m_mapgen_params;
	// The texture modifier expressions the game's nodes are drawn with, by
	// the resource name each is composed under. The client is what composes
	// them; this is what it is sent when it asks.
	sm_<ss_, ss_> m_texmods;
	// Seconds until the startup tables are served as files a second time;
	// see the tick
	float m_startup_files_wait = 5.0f;
	// Peers that asked for the texture modifiers while the game's media
	// was still on its way to them: the launcher's own client is
	// connected before the game is chosen, so the media is announced
	// after the join and composing over it fails until it has arrived
	// ([FIRST_RUN]). Answered on client_file:files_transmitted.
	std::set<network::PeerInfo::Id> m_texmods_waiting;
	std::set<network::PeerInfo::Id> m_files_transmitted;
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
	// **How far out is the server's to decide, not the client's**
	// (user, 2026-09-26): a player who asks for a view range of four
	// hundred is asking this machine to keep and to make that much world,
	// and a public server has to be able to say no. So the two radii are
	// Luanti's own settings -- `max_block_send_distance` (12 blocks of
	// sixteen nodes, which is the 3 sections this used to hard-code) and
	// `max_block_generate_distance` (10 blocks, the old 2) -- read once
	// when the mods have loaded. A client's request is capped by the load
	// radius in voxelworld, which sends the smaller of the two.
	int16_t m_load_radius_xz = 3;
	int16_t m_generate_radius_xz = 2;
	// **Y does not grow with XZ.** Terrain worth generating at three
	// hundred nodes out is the band the player's eye is in; a mapgen asked
	// for a sphere spends most of it on sky and on stone a hundred and
	// fifty nodes down that nobody at that distance will look at. Which
	// band is right is the mapgen's business and this is a heuristic, not
	// a truth (user, 2026-09-26), so the vertical radii stay where they
	// are while the horizontal ones follow the setting.
	static const int16_t LOAD_RADIUS_Y = 2;
	static const int16_t GENERATE_RADIUS_Y = 1;
	static const int32_t ACTIVE_RADIUS = 1;
	// The world around the origin, which is where a mod puts things while
	// the game loads and where a player with nowhere else to be spawns. It
	// is what the world was in its entirety before it streamed.
	static const int16_t SPAWN_RADIUS = 1;
	// Taller than it is wide, because what the spawn needs is the ground
	// under the origin and a mapgen can put that a long way down -- an ocean
	// trench, a deep valley. A column too short is a player left in the air
	// at the origin with nothing under them to stand on.
	static const int16_t SPAWN_RADIUS_Y = 2;
	// How many sections a streaming pass may take on, which goes down while
	// a mod's mapgen is slow; see run_on_generated(), and is nothing at all
	// while a world is being imported into this one
	size_t m_stream_budget = 2;
	// The Luanti world this one is being made out of, if any: set before
	// run_game() and read into the world from inside it, once the game's
	// nodes exist and before anything has asked for a section. See
	// read_luanti_world().
	ss_ m_import_path;
	// Where each player is, in voxels. Written by set_player_pos() a few
	// times a second and read once a step; it is what the world streams
	// around, and what says which sections are active.
	sm_<ss_, pv::Vector3DInt32> m_player_pos;
	pv::Vector3DInt16 m_section_size{0, 0, 0};
	// While a mapgen mod's on_generated runs: what it wrote, as a box, so
	// that the one relight it gets afterwards covers it ([STEP_SLICE])
	bool m_gen_writing = false;
	bool m_gen_wrote = false;
	pv::Region m_gen_bbox;
	void note_gen_write(const pv::Region &r)
	{
		if(!m_gen_writing)
			return;
		if(!m_gen_wrote){
			m_gen_bbox = r;
			m_gen_wrote = true;
			return;
		}
		const pv::Vector3DInt32 a = m_gen_bbox.getLowerCorner(),
				b = m_gen_bbox.getUpperCorner(),
				c = r.getLowerCorner(), d = r.getUpperCorner();
		m_gen_bbox = pv::Region(
				pv::Vector3DInt32(std::min(a.getX(), c.getX()),
					std::min(a.getY(), c.getY()), std::min(a.getZ(), c.getZ())),
				pv::Vector3DInt32(std::max(b.getX(), d.getX()),
					std::max(b.getY(), d.getY()), std::max(b.getZ(), d.getZ())));
	}
	// The media the game shipped, name -> path: a tile naming one can be
	// handed to the client as it is, and a palette has to be read here
	sm_<ss_, ss_> m_served_media;
	// The colours of each palette that has been read, by file name
	sm_<ss_, sv_<uint32_t>> m_palettes;
	// How many frames each animated tile's strip holds, by tile name
	sm_<ss_, size_t> m_frame_counts;
	// See glass_edge_material()
	sm_<ss_, interface::EdgeMaterialId> m_glass_edge_materials;
	uint32_t m_next_glass_edge_material = 10;
	bool m_glass_edge_materials_exhausted = false;
	// See rail_connect_group()
	sm_<int, uint8_t> m_rail_connect_groups;
	// The same ids for a "connected" node box's groups, by the group's
	// name ("fence", "pane"); rails and these share the 31
	sm_<ss_, uint8_t> m_named_connect_groups;
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
	// How often the clients are told what time it is
	static constexpr float TIME_INTERVAL_S = 5.0f;
	float m_time_accum = 0.0f;
	// The map check, which waits for the sections it uses; see
	// start_check_map()
	bool m_check_map_pending = false;
	float m_check_map_waited = 0.0f;
	sv_<pv::Vector3DInt16> m_check_sections;
	sv_<uint64_t> m_check_pinned;
	// Sections a generator has been over and whose voxels have arrived;
	// kept only while the check is waiting for its own
	std::set<uint64_t> m_generated_sections;
	float m_step_accum = 0.0f;
	// The longest step a game is told about. Luanti's own dedicated server
	// caps its dtime the same way: time nobody can make up is time to let
	// go of, and a mod that is handed ten seconds at once does something
	// silly with them.
	static constexpr float MAX_STEP_S = 0.5f;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		// The generator is luanti_mapgen's code and worldgen's to run.
		// Taken out while luanti_mapgen is still loaded -- it unloads
		// after this, and worldgen after both -- and set_generator()
		// waits for a generate() in progress to return.
		if(m_scene){
			worldgen::access(m_server, [&](worldgen::Interface *iw){
				worldgen::Instance *instance = iw->get_instance(m_scene);
				if(instance)
					instance->set_generator(nullptr);
			});
		}
		lua_prof_report();
		if(m_lua)
			lua_close(m_lua);
	}

	// The Lua the two Luanti clients share, from the extension's res,
	// served under the module's own client namespace so a game's client
	// half runs it by name ([VIEW_BOB]: camera_motion.lua; [EXT_SETTINGS]:
	// key_editor.lua; [EXT_HUD_PARITY]: minimap.lua; [EXT_HOTBAR]:
	// hotbar.lua; [LUANTI_SHARED]: texmod.lua, formspec.lua). At start rather
	// than with a game's media: a menu-only connection (the settings
	// screen, [MENU_CONTEXT]) runs no game and draws the key editor.
	void serve_shared_lua()
	{
		const ss_ shared = m_server->get_config().get<ss_>("share_path")+
				"/extensions/luanti_client/res";
		for(const char *name : {"camera_motion.lua", "key_editor.lua",
				"minimap.lua", "hotbar.lua", "texmod.lua",
				"formspec.lua"}){
			const ss_ path = shared+"/"+name;
			if(interface::fs::path_exists(path)){
				client_file::access(m_server, [&](client_file::Interface *i){
					i->add_file_path(ss_("luanti/")+name, path);
				});
			} else
				log_w(MODULE, "shared client Lua not found: %s", cs(path));
		}
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:module_unloaded"));
		m_server->sub_event(this, Event::t("core:unload"));
		m_server->sub_event(this, Event::t("core:shutdown"));
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("worldgen:section_generated"));
		m_server->sub_event(this, Event::t("voxelworld:section_loaded"));
		m_server->sub_event(this, Event::t("voxelworld:section_unloaded"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_texmods"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_images"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_item_palettes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_wield_meshes"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_object_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_dig_props"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_world_info"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:refshot_shot"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_translations"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:get_model"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:fields"));
		m_server->sub_event(this, Event::t(
				"network:packet_received/luanti:inv_action"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("core:module_unloaded", on_module_unloaded,
				interface::ModuleUnloadedEvent)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:shutdown", on_shutdown)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("worldgen:section_generated", on_section_generated,
				worldgen::SectionGenerated)
		EVENT_TYPEN("voxelworld:section_loaded", on_section_loaded,
				voxelworld::SectionLoaded)
		EVENT_TYPEN("voxelworld:section_unloaded", on_section_unloaded,
				voxelworld::SectionUnloaded)
		EVENT_TYPEN("network:packet_received/luanti:get_texmods",
				on_get_texmods, network::Packet)
		EVENT_TYPEN("client_file:files_transmitted", on_files_transmitted,
				client_file::FilesTransmitted)
		EVENT_TYPEN("network:packet_received/luanti:get_item_images",
				on_get_item_images, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_item_palettes",
				on_get_item_palettes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_wield_meshes",
				on_get_wield_meshes, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_object_props",
				on_get_object_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_dig_props",
				on_get_dig_props, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_world_info",
				on_get_world_info, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_translations",
				on_get_translations, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:get_model",
				on_get_model, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:refshot_shot",
				on_refshot_shot, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:fields",
				on_fields, network::Packet)
		EVENT_TYPEN("network:packet_received/luanti:inv_action",
				on_inv_action, network::Packet)
	}

	void on_start()
	{
		serve_shared_lua();
		// What may go ahead of the queue and replace its own stale copy
		// ([NET_CHANNELS]): the player's own position, the clock, and the
		// objects -- whose packet is the whole list every time (the
		// client removes what is not in it), so the newest replaces an
		// older one whole and no key by id is needed.
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->declare("luanti:player_pos",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:time",
					network::Interface::Channel::LatestOnly);
			inetwork->declare("luanti:objects",
					network::Interface::Channel::LatestOnly);
		});
	}
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
		save_loaded_sections_meta();
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
	// The world's seed, which a mapgen is a function of. Luanti keeps it in
	// map_meta.txt and makes one up when a world is created; here it is in
	// the save beside the clock, and the importer takes the imported world's
	// if it has one. What reads it is core.get_mapgen_setting("seed") and
	// the block seed every on_generated is given.
	int64_t m_seed = 0;
	// Whether this save is one nobody has opened before; see load_seed()
	bool m_world_is_new = false;

	void load_seed()
	{
		ss_ data;
		if(m_store && m_store->get("seed", data) && !data.empty()){
			// Unsigned, because Luanti's is: a world's seed is a u64 there
			// and half of them do not fit in the signed one this keeps. The
			// bits are what a mapgen is a function of, so they are what is
			// kept.
			m_seed = (int64_t)strtoull(data.c_str(), nullptr, 10);
		} else {
			// The first thing a world is asked for is its seed, so a save
			// with none is a save nobody has played yet. What that decides
			// is what mapgen it gets; see mapgen_name().
			m_world_is_new = true;
			// Luanti's own fixed_map_seed, which is what makes one world the
			// same world twice: a benchmark that generates terrain has to
			// generate the same terrain, and a bug report about a place has
			// to be able to name it. Read the way Luanti reads it -- only
			// when a world is being made, never over one that has a seed.
			const ss_ fixed = setting_string("fixed_map_seed");
			if(!fixed.empty()){
				m_seed = (int64_t)strtoull(fixed.c_str(), nullptr, 10);
				log_i(MODULE, "The world's seed is fixed_map_seed, %s",
						cs(itos(m_seed)));
			} else {
				// Somewhere nobody has been before: the clock is what there
				// is to be random with here, and a world is seeded once
				m_seed = (int64_t)interface::os::time_us();
				m_seed ^= (int64_t)(size_t)this;
			}
			if(m_store)
				m_store->set("seed", itos(m_seed));
		}
		set_global_string("__luanti_world_seed", itos(m_seed));
		log_v(MODULE, "The world's seed is %s", cs(itos(m_seed)));
	}

	void set_seed(int64_t seed)
	{
		m_seed = seed;
		if(m_store)
			m_store->set("seed", itos(m_seed));
		set_global_string("__luanti_world_seed", itos(m_seed));
	}

	// A scripted run cannot wait for morning, and two pictures taken at
	// different hours are not comparable -- which is what the reference
	// comparison in doc/plan/luanti_module_plan.md is. Spelled the way
	// extensions/luanti_client spells them, because it is the other half of
	// that comparison: BUILDAT_LUANTI_FORCE_TIME is a Luanti time of day
	// (0..24000, so 9000 is mid-morning) and BUILDAT_LUANTI_FORCE_DAY is
	// noon without having to remember 12000.
	//
	// The clock stops as well as moves: a screenshot taken a minute into a
	// run should be the same picture as one taken at the start, and
	// time_speed is Luanti's own way of saying so.
	void force_clock()
	{
		const char *t = getenv("BUILDAT_LUANTI_FORCE_TIME");
		const char *d = getenv("BUILDAT_LUANTI_FORCE_DAY");
		double tod = -1.0;
		if(t != nullptr && t[0] != '\0')
			tod = atof(t) / 24000.0;
		else if(d != nullptr && d[0] != '\0')
			tod = 0.5;
		if(tod < 0.0)
			return;
		char buf[200];
		snprintf(buf, sizeof buf,
				"core.set_timeofday(%f) "
				"core.settings:set('time_speed', '0') "
				"core.__send_time()", tod);
		run_chunk_string(buf, "force_clock");
		log_i(MODULE, "The clock is pinned at %.0f of Luanti's 24000 and "
				"does not run", tod * 24000.0);
	}

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

	// What hangs off the voxels of one section, in the save under a key of
	// its own: a section that unloads takes its metadata with it and brings
	// it back when it returns, which is how Luanti keeps a block's metadata
	// with the block. See step 5c of doc/plan/world_persistence_plan.md.
	ss_ section_meta_key(const pv::Vector3DInt16 &p)
	{
		return ss_()+"node_meta/"+itos(p.getX())+","+itos(p.getY())+","+
				itos(p.getZ());
	}

	void save_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__take_node_meta");
		lua_pushinteger(L, x0);
		lua_pushinteger(L, y0);
		lua_pushinteger(L, z0);
		lua_pushinteger(L, x0 + sx - 1);
		lua_pushinteger(L, y0 + sy - 1);
		lua_pushinteger(L, z0 + sz - 1);
		if(lua_pcall(L, 6, 2, 0) != 0){
			log_w(MODULE, "__take_node_meta(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		size_t len = 0;
		const char *p = lua_tolstring(L, -2, &len);
		const ss_ data(p ? p : "", p ? len : 0);
		const int n = (int)lua_tonumber(L, -1);
		lua_settop(L, base);
		const ss_ key = section_meta_key(section_p);
		if(n == 0){
			// Nothing there, and what the save holds is older than that
			ss_ old;
			if(m_store->get(key, old))
				m_store->set(key, "");
			return;
		}
		m_store->set(key, data);
		log_v(MODULE, "%i node metadata written with section (%i, %i, %i)", n,
				(int)section_p.getX(), (int)section_p.getY(),
				(int)section_p.getZ());
	}

	void load_section_meta(const pv::Vector3DInt16 &section_p)
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get(section_meta_key(section_p), data) || data.empty())
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
		}
		lua_settop(L, base);
	}

	void on_section_loaded(const voxelworld::SectionLoaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		load_section_meta(event.section_p);
	}

	void on_section_unloaded(const voxelworld::SectionUnloaded &event)
	{
		if(!m_game_running || event.scene != m_scene)
			return;
		save_section_meta(event.section_p);
	}

	// Every section that is loaded, which is what a shutdown owes the save:
	// the ones that have already gone wrote themselves out as they went.
	void save_loaded_sections_meta()
	{
		if(!m_store || !m_scene)
			return;
		sv_<pv::Vector3DInt16> sections;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			sections = world->get_loaded_sections();
		});
		for(const pv::Vector3DInt16 &section_p : sections)
			save_section_meta(section_p);
		log_v(MODULE, "Node metadata written for %zu sections",
				sections.size());
	}

	// Everything the Lua half holds, grouped by the section each position
	// is in and written; what is in memory is left there. What wants this
	// is the importer -- a world it read metadata for is mostly sections
	// nothing has loaded -- and the migration below.
	size_t write_all_node_meta()
	{
		if(!m_store || !m_lua || m_section_size.getX() <= 0)
			return 0;
		sv_<ss_> flat;
		int n = 0;
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__regroup_node_meta");
			lua_pushinteger(L, m_section_size.getX());
			if(lua_pcall(L, 1, 2, 0) != 0){
				log_w(MODULE, "__regroup_node_meta(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return 0;
			}
			n = (int)lua_tonumber(L, -1);
			if(lua_istable(L, -2)){
				const size_t count = lua_objlen(L, -2);
				for(size_t i = 1; i <= count; i++){
					lua_rawgeti(L, -2, (int)i);
					size_t len = 0;
					const char *p = lua_tolstring(L, -1, &len);
					flat.push_back(ss_(p ? p : "", p ? len : 0));
					lua_pop(L, 1);
				}
			}
			lua_settop(L, base);
		}
		for(size_t i = 0; i + 1 < flat.size(); i += 2)
			m_store->set("node_meta/"+flat[i], flat[i + 1]);
		log_v(MODULE, "%i node metadata over %zu sections", n,
				flat.size() / 2);
		return flat.size() / 2;
	}

	// A save written when the metadata was one blob for the whole world:
	// read it, write it out per section, and only then drop the blob, so
	// that a crash in the middle leaves the blob to be read again.
	void migrate_node_meta()
	{
		if(!m_store || !m_lua)
			return;
		ss_ data;
		if(!m_store->get("node_meta", data) || data.empty())
			return;
		log_i(MODULE, "The save's node metadata is one blob; writing it out "
				"per section");
		load_node_meta();
		write_all_node_meta();
		m_store->set("node_meta", "");
		m_had_node_meta = false;
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

	// The server ticks at 30 Hz and Luanti steps at 0.09 s, so a tick's
	// dtime is accumulated into a step. A tick the server could not deliver
	// on time arrives with the time it was late by added to it -- see
	// push_event() in src/server/state.cpp -- so a game whose step costs
	// more than a tick interval, which VoxeLibre's 220 mods do, runs slow
	// rather than falling further behind on every tick.
	void on_tick(const interface::TickEvent &event)
	{
		if(!m_game_running)
			return;
		m_step_accum += event.dtime;
		if(m_step_accum < STEP_S)
			return;
		float dtime = m_step_accum;
		if(dtime > MAX_STEP_S)
			dtime = MAX_STEP_S;
		m_step_accum = 0.0f;
		// The startup tables once more, a few seconds in: a game's entity
		// looks are not all registered when the voxel registry is built
		// (VoxeLibre had ten of them after and none at it), and a file
		// that is there before the next client connects is the point
		// ([BLOCKED_MODULE])
		if(m_startup_files_wait > 0.0f){
			m_startup_files_wait -= dtime;
			if(m_startup_files_wait <= 0.0f)
				serve_startup_tables();
		}
		// Other players' digs and the loader's unloads land between steps
		drop_read_cache();
		// The relights the mapgen mods' writes asked for, one or two a tick
		// rather than in the step that wrote them ([STEP_SLICE])
		if(m_scene){
			const int64_t t0 = interface::os::time_us();
			size_t left = 0;
			int64_t t_in = 0;
			voxelworld::access(m_server, m_scene,
					[&](voxelworld::Instance *world){
				t_in = interface::os::time_us();
				left = world->relight_stale(RELIGHT_BUDGET_US,
						RELIGHT_NEAR_BUDGET_US);
			});
			const int64_t took = interface::os::time_us() - t0;
			// What of it was waiting for voxelworld rather than lighting:
			// the relight's own budget is 20 ms (100 near) and a step of a
			// second in "relight" is another module holding the world --
			// the physics variant's does. A phase of its own says so
			// rather than reading as this one's cost ([MAPGEN_STEP]).
			const int64_t waited = t_in > t0 ? t_in - t0 : 0;
			if(took > 1000){
				drop_read_cache();
				char buf[96];
				snprintf(buf, sizeof buf,
						"core.__note_phase(\"%s\", %f)",
						waited * 2 > took ? "relight_wait" : "relight",
						(double)took / 1000000.0);
				run_chunk_string(buf, "relight");
				if(left > 0 || waited > 100000)
					log_v(MODULE, "relight: %i ms (%i waiting for "
							"voxelworld), %zu sections still stale",
							(int)(took / 1000), (int)(waited / 1000), left);
			}
		}
		update_load_points();
		if(m_game_running)
			run_completed_chunks();
		check_map_when_ready(dtime);
		step_environment(dtime);
		flush_node_writes();
		// The clock, now and then: a client carries it on by itself between
		// these, so this is a correction rather than a tick
		m_time_accum += dtime;
		if(m_time_accum >= TIME_INTERVAL_S){
			m_time_accum = 0.0f;
			run_chunk_string("core.__send_time()", "send_time");
		}
	}

	// One Luanti step: the clock now, the globalsteps and core.after later
	// How long a step may run before the watchdog says where it is. Long
	// enough that a world generating around a player -- which is seconds of
	// honest work -- says nothing, and short enough that a step that will
	// never come back is caught while somebody is still watching.
	static const int64_t STEP_WATCHDOG_US = 30000000;
	// How much of a tick the deferred relights may take; a section is
	// about 160 ms on VoxeLibre, so this is one a tick
	static const int64_t RELIGHT_BUDGET_US = 20000;
	// And while a stale section is within two of a player: the player's
	// own canopy black for twenty seconds was the small budget on
	// 250k-blocker sections ([SEED5_SETTLE])
	static const int64_t RELIGHT_NEAR_BUDGET_US = 100000;

	void step_environment(float dtime)
	{
		char buf[64];
		snprintf(buf, sizeof buf, "core.__step(%f)", (double)dtime);
		g_step_watch.started_us = interface::os::time_us();
		g_step_watch.deadline_us =
				g_step_watch.started_us + STEP_WATCHDOG_US;
		g_step_watch.warned = false;
		try {
			run_chunk_string(buf, "step");
		} catch(Exception &e){
			log_w(MODULE, "step: %s", e.what());
		}
		g_step_watch.deadline_us = 0;
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
				SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS, SPAWN_RADIUS_Y));
		for(const auto &pair : m_player_pos){
			size_t peer = 0;
			auto it = m_player_peers.find(pair.first);
			if(it != m_player_peers.end())
				peer = it->second;
			points.push_back(voxelworld::LoadPoint(pair.second,
					m_load_radius_xz, LOAD_RADIUS_Y,
					m_generate_radius_xz, GENERATE_RADIUS_Y, peer));
		}
		// A forceloaded section is a point with no radius at all
		for(const auto &pair : m_forceloaded){
			const pv::Vector3DInt16 sp = section_from_key(pair.first);
			points.push_back(voxelworld::LoadPoint(pv::Vector3DInt32(
					(int32_t)sp.getX() * m_section_size.getX(),
					(int32_t)sp.getY() * m_section_size.getY(),
					(int32_t)sp.getZ() * m_section_size.getZ()),
					0, 0, 0, 0));
		}
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_load_points(points);
			world->set_stream_budget(m_stream_budget);
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

	// Luanti's forceload: a block a mod wants kept whatever nobody is near
	// it, which is a load point with no radius at all. Kept by section,
	// because that is what loads and unloads here; a mod asking for a
	// block gets the section it is in.
	//
	// Nothing here is written down, and nothing needs to be: the vendored
	// builtin's forceloading.lua keeps the ones that are not transient in
	// force_loaded.txt beside the world and asks for them again when it
	// loads, which is where Luanti keeps them too.
	// Section key -> how many holds: a game's forceload_block() per
	// mapblock (VoxeLibre makes and frees thousands) and the map check's
	// pin share this, and one owner's free took the other's hold with it
	// (the check read its room out of an unloaded section, 2026-09-21)
	sm_<uint64_t, int> m_forceloaded;

	static uint64_t section_key(const pv::Vector3DInt16 &p)
	{
		return (uint64_t)(uint16_t)p.getX() |
				((uint64_t)(uint16_t)p.getY() << 16) |
				((uint64_t)(uint16_t)p.getZ() << 32);
	}

	static pv::Vector3DInt16 section_from_key(uint64_t k)
	{
		return pv::Vector3DInt16((int16_t)k, (int16_t)(k >> 16),
				(int16_t)(k >> 32));
	}

	// __luanti_accounts(cmd, a, b): Luanti's kicks and bans, which are
	// builtin/accounts' ([VANILLA_PUBLIC] 4). A player's name is their
	// account's.
	//   "kick", name, reason -> "" when done, else why not
	//   "ban", name          -> the same
	//   "unban", name or address -> the same
	//   "ban_list"           -> "name|address, ..."
	//   "ip", name           -> the address, or ""
	static int l_accounts(lua_State *L)
	{
		Module *self = module_of(L);
		const ss_ cmd = luaL_checkstring(L, 1);
		const ss_ a = luaL_optstring(L, 2, "");
		const ss_ b = luaL_optstring(L, 3, "");
		ss_ out;
		accounts::access(self->m_server, [&](accounts::Interface *i){
			const accounts::PeerId peer = a.empty() ? 0 : i->find_peer(a);
			// A world's privileges reach this server's accounts: kick and
			// ban leave an admin alone, and unban lifts what a world banned,
			// not an admin's ban ([SECURITY_RUN_1])
			if(cmd == "kick"){
				if(!peer)
					out = a+" is not here";
				else if(i->is_admin(a))
					out = "An admin is not kicked";
				else
					i->kick(peer, b.empty() ? "Kicked" : b);
			} else if(cmd == "ban"){
				out = i->ban(a, "the game");
			} else if(cmd == "unban"){
				out = i->unban(a, "the game");
			} else if(cmd == "ban_list"){
				for(const ss_ &ban : i->ban_list())
					out += (out.empty() ? "" : ", ")+ban;
			} else if(cmd == "ip"){
				out = peer ? i->address_of(peer) : "";
			}
		});
		lua_pushstring(L, out.c_str());
		return 1;
	}

	// __luanti_forceload(x, y, z, wanted) -> whether it is kept now
	static int l_forceload(lua_State *L)
	{
		Module *self = module_of(L);
		const int32_t x = (int32_t)luaL_checkinteger(L, 1);
		const int32_t y = (int32_t)luaL_checkinteger(L, 2);
		const int32_t z = (int32_t)luaL_checkinteger(L, 3);
		const bool wanted = lua_toboolean(L, 4) != 0;
		if(self->m_section_size.getX() <= 0){
			lua_pushboolean(L, 0);
			return 1;
		}
		const uint64_t key = section_key(
				self->section_of(pv::Vector3DInt32(x, y, z)));
		if(wanted){
			self->m_forceloaded[key]++;
		} else {
			auto it = self->m_forceloaded.find(key);
			if(it != self->m_forceloaded.end() && --it->second <= 0)
				self->m_forceloaded.erase(it);
		}
		log_v(MODULE, "forceload: %zu sections kept",
				self->m_forceloaded.size());
		// The points are pushed once a step; this only says what they are
		lua_pushboolean(L, wanted ? 1 : 0);
		return 1;
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
		drop_read_cache();
		size_t n = m_node_writes.size();
		const int64_t t0 = interface::os::time_us();
		int64_t t_set = 0;
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
				// Loaded, not generated: a set_node past the generated
				// world -- a mapgen mod's structure into the next section
				// -- waits there for the generator, which keeps what stands
				if(!world->is_section_loaded(section_p))
					world->load_section_no_generate(section_p);
			}
			for(const auto &pair : m_node_writes){
				const PendingNode &node = pair.second;
				world->set_voxel(pv::Vector3DInt32(node.x, node.y, node.z),
						interface::VoxelInstance(node.word), true);
			}
			t_set = interface::os::time_us();
		});
		m_node_writes.clear();
		// Split into the writes and the commit that follows them on the
		// way out of access(), since a step's flush is what is left of
		// its stall once the reads stopped flushing ([STEP_PEAK])
		const int64_t took = interface::os::time_us() - t0;
		if(took > 50000)
			log_v(MODULE, "Flushed %zu node writes in %.2f s: the writes "
					"%.2f, the commit %.2f", n, took / 1e6, (t_set - t0) / 1e6,
					(interface::os::time_us() - t_set) / 1e6);
		else
			log_d(MODULE, "Flushed %zu node writes", n);
	}

	RegionMap *m_region_map = nullptr;
	void set_region_map(RegionMap *map)
	{
		m_region_map = map;
	}

	void buffer_node_write(int32_t x, int32_t y, int32_t z, uint32_t word)
	{
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return;
		// A body's voxel ([BODY_INTERACT]): written straight to its owner,
		// which is not the map and has no buffer to land in
		if(y >= REGION_Y){
			// **And a write with no body under it says so** (2026-09-25):
			// a body's volume carries four voxels of air around it and a
			// place past that has nowhere to land, so it was dropped in
			// silence -- the node simply never appeared, and nothing in
			// any log said why. Growing the volume is the fix and it is
			// [BODY_INTERACT]'s own leftover; until then this is the
			// line that names it. Rate limited: a VoxelManip over a body
			// is a write per voxel and a mod that misses by one misses
			// by thousands.
			if(!m_region_map || !m_region_map->set(x, y, z, word)){
				// Counted rather than timed: this module has no clock of
				// its own in scope, and what a reader needs is the first
				// one and a sense of how many followed
				static uint64_t dropped = 0;
				dropped++;
				if(dropped == 1 || dropped % 1000 == 0){
					log_w(MODULE, "a write at %i,%i,%i is past every "
							"body's margin and is dropped (%llu so far)",
							(int)x, (int)y, (int)z,
							(unsigned long long)dropped);
				}
			}
			return;
		}
		PendingNode node;
		node.x = x;
		node.y = y;
		node.z = z;
		node.word = word;
		m_node_writes[pos_key(x, y, z)] = node;
		note_gen_write(pv::Region(pv::Vector3DInt32(x, y, z),
				pv::Vector3DInt32(x, y, z)));
	}

	// A read takes one voxelworld access(), which commits on the way out.
	// commit() is cheap with nothing dirty, but it is not free; what reads a
	// box reads it with read_region() below.
	uint32_t read_node(int32_t x, int32_t y, int32_t z)
	{
		// Ignore, past anything that can be there
		if(!coord_ok(x) || !coord_ok(y) || !coord_ok(z))
			return 0;
		// A buffered write answers with the word that went in. The read
		// used to flush the buffer first so that a mod placing a lamp and
		// asking what the room is lit by saw the flood -- but every flush
		// is a voxelworld commit with the skylight, and a mod that reads
		// and writes node by node (VoxeLibre's fix_foliage_missed over a
		// forest, its structure placers, any set_node, which reads first)
		// paid one per node: 31 s for one section's on_generated, 1.9
		// million skylight updates for a bench. So a read answers out of
		// the buffer for what is buffered and out of the world for the
		// rest, and the buffer lands at the end of the step or before a
		// region read.
		// simplified: the light of a voxel *next to* a buffered write is
		// the light before it, until the flush. A mod that needs the flood
		// in the same step reads a region (VoxelManip), which flushes.
		auto it = m_node_writes.find(pos_key(x, y, z));
		if(it != m_node_writes.end())
			return it->second.word;
		// A body's voxel ([BODY_INTERACT]), or ignore where no body is
		if(y >= REGION_Y){
			uint32_t word = 0;
			if(m_region_map && m_region_map->get(x, y, z, word))
				return word;
			return 0;
		}
		// Before the world exists -- the mods are loading -- everything
		// else is ignore; the buffer above still answers, which is what
		// a mod's own load-time check of set_node and place_node reads
		// (the minimal game's floor mod; [WIN_MAPGEN_BUILD] found it
		// failing since the guard stood ahead of the buffer)
		if(!m_scene)
			return 0;
		// And out of a cache of 16^3 blocks for the rest: an access() is
		// a handoff to voxelworld's thread and back, a quarter of a
		// millisecond whatever it reads, and what reads node by node is a
		// mod sweeping a box -- fix_foliage_missed read 171 thousand of
		// them in two minutes. One region read per block instead. The
		// cache is dropped whenever the world can have moved under it:
		// a flush, a region write, a step, a section generated.
		const int32_t bx = floordiv(x, 16), by = floordiv(y, 16),
				bz = floordiv(z, 16);
		const int64_t key = pos_key(bx, by, bz);
		auto c = m_read_cache.find(key);
		if(c == m_read_cache.end()){
			// The first read of a block is a single voxel; the block is
			// read whole on the second. A world generating drops the
			// cache every section, and a mod reading one node here and
			// one there paid a 4096-voxel region per read for nothing --
			// a second on devtest's world generation.
			if(m_read_seen.insert(key).second){
				uint32_t word = 0;
				voxelworld::access(m_server, m_scene,
						[&](voxelworld::Instance *world){
					word = world->get_voxel(pv::Vector3DInt32(x, y, z),
							true).data;
				});
				return word;
			}
			sv_<uint32_t> words;
			read_region_uncached(bx * 16, by * 16, bz * 16,
					bx * 16 + 15, by * 16 + 15, bz * 16 + 15, words);
			c = m_read_cache.emplace(key, std::move(words)).first;
		}
		return c->second[(size_t)((z - bz * 16) * 256 + (y - by * 16) * 16 +
				(x - bx * 16))];
	}

	// See read_node()
	std::unordered_map<int64_t, sv_<uint32_t>> m_read_cache;
	set_<int64_t> m_read_seen;
	void drop_read_cache()
	{
		m_read_cache.clear();
		m_read_seen.clear();
	}

	// Luanti's own cap on how much map a call may look at in one go
	// (MAX_WORKING_VOLUME). A mod asking for more than this has made a
	// mistake, and quietly building a table of that many numbers is not the
	// way to tell it so.
	static const size_t MAX_REGION_VOXELS = 4096000;
	// How far from the origin a node can be, the bodies' band at REGION_Y
	// included. Past it nothing is read or written: a coordinate from a
	// mod's arithmetic on what a client sent reached 2^30, where a box's
	// "y <= y1" loop never ended and wrote past its buffer, and past 2^21
	// a section's 16-bit index wraps ([SECURITY_RUN_1], util/fuzz).
	static const int32_t COORD_LIMIT = 2000000;
	static bool coord_ok(int32_t v)
	{
		return v >= -COORD_LIMIT && v <= COORD_LIMIT;
	}
	// A box: a node's 16^3 block or a mod's area round one, so a little
	// past COORD_LIMIT
	static bool box_ok(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1)
	{
		const int32_t L = COORD_LIMIT + 64;
		for(int32_t v : {x0, y0, z0, x1, y1, z1})
			if(v < -L || v > L)
				return false;
		return true;
	}

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
		// See box_ok(): every caller bounds its box first
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
		// What core.set_node has written and not yet flushed is part of the
		// map as far as a mod is concerned -- Luanti's semantics are that a
		// write is visible immediately. A small box has the buffer laid
		// over it, a lookup per voxel: a mod that alternates a
		// find_nodes_in_area of a few voxels with set_nodes (VoxeLibre's
		// geodes, per calcite node) paid a commit with the skylight per
		// read when every read flushed. A big box -- a section's
		// VoxelManip, a find over a chunk -- flushes first as before:
		// walking a buffer of tens of thousands per read, a hundred reads
		// a section, cost VoxeLibre's world generation a third.
		const size_t volume = (size_t)(x1 - x0 + 1) * (size_t)(y1 - y0 + 1) *
				(size_t)(z1 - z0 + 1);
		// A box in a body's region ([BODY_INTERACT]) is read voxel by
		// voxel off the body's owner; the map has nothing there. A box
		// across the line reads as ignore above it.
		if(y0 >= REGION_Y){
			out.assign(volume, 0);
			if(!m_region_map)
				return;
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++)
			for(int32_t y = y0; y <= y1; y++)
			for(int32_t x = x0; x <= x1; x++, i++){
				uint32_t word = 0;
				if(m_region_map->get(x, y, z, word))
					out[i] = word;
			}
			return;
		}
		if(volume > 4096)
			flush_node_writes();
		read_region_uncached(x0, y0, z0, x1, y1, z1, out);
		if(m_node_writes.empty())
			return;
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			auto it = m_node_writes.find(pos_key(x, y, z));
			if(it != m_node_writes.end())
				out[i] = it->second.word;
		}
	}

	void read_region_uncached(int32_t x0, int32_t y0, int32_t z0,
			int32_t x1, int32_t y1, int32_t z1, sv_<uint32_t> &out)
	{
		// The callers bound it (box_ok() at the Lua entries, read_node()
		// for its block); a box past it here is a caller's bug, and an
		// empty answer is what a short read gets
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 < x0 || y1 < y0 || z1 < z0){
			out.clear();
			return;
		}
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
			// A row at a time: the answer is an array of words and a row
			// of the volume is a run of them, so the only per-voxel work
			// left is the assembly out of the bytes. A sampler per voxel
			// was the top of a devtest profile with this underneath it.
			interface::VoxelVolume::Sampler src(&vol);
			size_t i = 0;
			for(int32_t z = z0; z <= z1; z++){
				for(int32_t y = y0; y <= y1; y++){
					if(vol.read_words(x0, y, z, w, &out[i])){
						i += w;
						continue;
					}
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
	// apps/vanilla.
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

	// Luanti's own two settings, read once the mods have loaded and
	// turned from its blocks of sixteen nodes into this world's sections
	// of sixty-four. The defaults are Luanti's: 12 blocks sent, 10
	// generated, which are the 3 and 2 sections this carried before.
	void read_range_settings()
	{
		run_chunk_string(
				"__buildat_send_blocks = tonumber(core.settings:get("
				"'max_block_send_distance')) or 12 "
				"__buildat_generate_blocks = tonumber(core.settings:get("
				"'max_block_generate_distance')) or 10",
				"read_range_settings");
		auto sections_of = [&](const char *global, int fallback) -> int16_t {
			lua_getglobal(m_lua, global);
			const int blocks = lua_isnumber(m_lua, -1) ?
					(int)lua_tonumber(m_lua, -1) : fallback;
			lua_pop(m_lua, 1);
			// Sixteen nodes to a block, sixty-four to a section; never
			// nothing, and never so much that one player's setting can ask
			// the machine for a world of thousands of sections
			const int sections = blocks * 16 / 64;
			return (int16_t)(sections < 1 ? 1 : (sections > 16 ? 16 :
					sections));
		};
		m_load_radius_xz = sections_of("__buildat_send_blocks", 12);
		m_generate_radius_xz = sections_of("__buildat_generate_blocks", 10);
		log_i(MODULE, "world kept %i sections out and generated %i "
				"(max_block_send_distance, max_block_generate_distance)",
				(int)m_load_radius_xz, (int)m_generate_radius_xz);
	}

	void create_world()
	{
		read_range_settings();
		// Nothing streams while a world is being imported into this one:
		// see run_game(). The budget goes back to what it was once the
		// import is done.
		if(!m_import_path.empty())
			m_stream_budget = 0;
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});

		// Singlenode: nothing generates anything, so the world is void and
		// the only nodes in it are the ones a mod places. The region is the
		// map's limits; what is loaded of it is what the load points keep.
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			iv->create_instance(m_scene, m_section_region, m_server_physics);
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
		// The startup tables are known once the registry is built, and they
		// go out as files as well as on request ([BLOCKED_MODULE])
		serve_startup_tables();
		// A section is what this world generates at a time, which is what
		// core.get_mapgen_chunksize() answers with
		set_global_string("__luanti_section_size",
				itos(m_section_size.getX()));

		// The generator runs in worldgen's thread rather than here: what
		// fills a section is a mod's Lua today and Luanti's own mapgen
		// when it is vendored, and neither belongs on the thread the
		// server steps on. It is created before the first section is
		// asked for, which is the next line but one.
		// What fills a section is builtin/luanti_mapgen's, which is where
		// Luanti's own mapgens are vendored: this module hands over what a
		// generator is a function of and gets one back.
		luanti_mapgen::Params params;
		params.mgname = mapgen_name();
		params.seed = m_seed;
		params.singlenode_word = singlenode_word();
		params.content_ids = content_ids_by_name();
		params.node_props = mapgen_node_props();
		params.biomes = mapgen_biomes();
		params.ores = mapgen_ores();
		params.decorations = mapgen_decorations();
		params.section_size = m_section_size.getX();
		params.water_level = mapgen_water_level();
		params.mg_flags = mapgen_flags();
		// What a mod asks for as get_mapgen_setting("water_level"): the
		// world's own, which is not always what the settings say
		set_global_string("__luanti_water_level", itos(params.water_level));
		mapgen_gen_notify(params.gen_notify_flags, params.gen_notify_deco_ids);
		if(!params.gen_notify_flags.empty())
			log_v(MODULE, "gennotify: \"%s\", %zu decoration ids",
					cs(params.gen_notify_flags),
					params.gen_notify_deco_ids.size());
		// Kept, because the spawn search asks the same mapgen where the
		// ground is without generating anything; see l_spawn_level()
		m_mapgen_params = params;
		m_biome_query = nullptr;
		worldgen::GeneratorInterface *generator = nullptr;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			generator = im->create_generator(params);
		});
		worldgen::access(m_server, [&](worldgen::Interface *iw){
			iw->create_instance(m_scene);
			worldgen::Instance *instance = iw->get_instance(m_scene);
			if(generator)
				instance->set_generator(generator);
			instance->enable();
		});

		// Singlenode is a node everywhere, and this is where it is put.
		// Before the skylight is on: what the fill writes is a world of lit
		// air, and every voxel of it changing from nothing to air with the
		// light running would be a skylight seed -- seven million of them,
		// and eight seconds of startup to settle what the fill already
		// knows.
		//
		// A world being imported waits: what this asks for is the sections
		// around the origin, and a section a generator has been over is one
		// the import can no longer write into. run_game() calls it once the
		// map has been read, and the sections the import filled are marked
		// generated by then.
		if(m_import_path.empty())
			generate_world();

		// The light is voxelworld's to maintain and the generator's to
		// start. voxelworld floods from the top of the world region, which
		// for a Luanti-sized map is thirty thousand voxels up and never
		// loaded -- so nothing would ever be lit if that were the only
		// source. What lights a generated world is the mapgen, which fills
		// the light as it builds (the MG_LIGHT flag), and voxelworld keeps
		// that light and spreads it from there: a write that carries light
		// means it. So a hole dug into a mountain fills from the daylight
		// around its mouth, the way it does in Luanti.
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_SKY, true);
			// And the light a node makes of its own, which a Luanti game's
			// mechanics are written against: what spawns where, what grows
			// underground, what a mod reads out of core.get_node_light().
			// A game whose lamps are lights in the scene would leave this
			// off; a Luanti game cannot.
			world->set_light_maintained(
					voxelworld::Instance::LIGHT_LAMP, true);
		});

		check_active_range();

		// After the world, because a section is what the metadata is now
		// written per and the section size comes from voxelworld
		migrate_node_meta();
	}

	// The client half asks for these once it has loaded, rather than being
	// sent them when it connects: a packet that arrives before the script
	// that subscribes to it has nowhere to go.
	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		m_files_transmitted.insert(event.recipient);
		if(m_texmods_waiting.erase(event.recipient))
			send_texmods(event.recipient);
	}

	void on_get_texmods(const network::Packet &packet)
	{
		// A batch of media announced since this peer's last
		// files_transmitted is still on its way: the answer waits for it
		if(!m_files_transmitted.count(packet.sender)){
			m_texmods_waiting.insert(packet.sender);
			return;
		}
		send_texmods(packet.sender);
	}

	// The same flat array the packet carries: a resource name and the
	// expression it is for, in pairs
	ss_ texmods_blob()
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
		return os.str();
	}

	// And as a file, served by client_file ([BLOCKED_MODULE]): this module
	// answers nothing while a slow mapgen holds it -- realtest's sections
	// were 29.6 s each and the client drew 840 missing textures -- and
	// client_file is a module of its own with a queue of its own, so a file
	// reaches the client whatever this one is doing. The client reads it
	// before it asks, and the packet stays for what is added later.
	void serve_texmods_file()
	{
		if(m_texmods.empty())
			return;
		const ss_ blob = texmods_blob();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content("luanti_data/texmods.bin", blob);
		});
		log_v(MODULE, "%zu texture modifiers served as a file",
				m_texmods.size());
	}

	// The same for the tables the client's other startup requests read:
	// each is built at mod load and the request only reads it, so none of
	// them has any business waiting behind a mapgen ([BLOCKED_MODULE]).
	// The requests stay -- a game may add to a table while it runs.
	void serve_lua_table_file(const char *lua_fn, const ss_ &file_name,
			const char *what)
	{
		sv_<ss_> flat = string_list_from_lua(lua_fn);
		if(flat.empty())
			return;
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		const ss_ blob = os.str();
		client_file::access(m_server, [&](client_file::Interface *ifile){
			ifile->add_file_content(file_name, blob);
		});
		log_v(MODULE, "%zu %s served as a file", flat.size(), what);
	}

	void serve_startup_tables()
	{
		serve_texmods_file();
		serve_lua_table_file("__object_appearances",
				"luanti_data/object_props.bin", "object look fields");
		serve_lua_table_file("__dig_props", "luanti_data/dig_props.bin",
				"dig prop records");
		serve_lua_table_file("__translations",
				"luanti_data/translations.bin", "translated strings");
		serve_lua_table_file("__item_images", "luanti_data/item_images.bin",
				"item image fields");
		serve_lua_table_file("__item_palettes",
				"luanti_data/item_palettes.bin", "item palettes");
		serve_lua_table_file("__wield_meshes",
				"luanti_data/wield_meshes.bin", "wield meshes");
	}

	void send_texmods(network::PeerInfo::Id peer)
	{
		std::ostringstream os(std::ios::binary);
		os << texmods_blob();
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "luanti:texmods", os.str());
		});
		log_v(MODULE, "C%zu: %zu texture modifiers", (size_t)peer,
				m_texmods.size());
	}

	// Every node name the game registered and the id it got, which is what
	// a vendored mapgen is told to build with: it asks for "mapgen_stone"
	// and the game's own aliases say what that is here.
	//
	// simplified: all of them, because the whole table is a few hundred
	// short strings and which ones a mapgen wants depends on the mapgen.
	// What a mapgen asks about a node, nine values each: the id, then
	// walkable, is_ground_content, floodable, light_propagates,
	// sunlight_propagates, the liquid type, the drawtype as the game's own
	// word for it, and whether the node stores light. The same order
	// core.__mapgen_node_props() writes them in.
	sm_<uint32_t, luanti_mapgen::Params::NodeProps> mapgen_node_props()
	{
		sm_<uint32_t, luanti_mapgen::Params::NodeProps> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_node_props");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_node_props(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i + 8 <= n; i += 9){
			lua_Integer v[9];
			ss_ drawtype = "normal";
			for(int k = 0; k < 9; k++){
				lua_rawgeti(L, -1, (int)(i + k));
				if(k == 7){
					const char *word = lua_tostring(L, -1);
					if(word)
						drawtype = word;
					v[k] = 0;
				} else {
					v[k] = lua_tointeger(L, -1);
				}
				lua_pop(L, 1);
			}
			luanti_mapgen::Params::NodeProps p;
			p.walkable = v[1] != 0;
			p.is_ground_content = v[2] != 0;
			p.floodable = v[3] != 0;
			p.light_propagates = v[4] != 0;
			p.sunlight_propagates = v[5] != 0;
			p.liquid_type = (int)v[6];
			p.drawtype = drawtype;
			p.param_type_light = v[8] != 0;
			out[(uint32_t)v[0]] = p;
		}
		lua_settop(L, base);
		return out;
	}

	// The biomes a game registered, as core.__mapgen_biomes() builds them:
	// one table each, with the node names already the ids they mean
	sv_<luanti_mapgen::Params::Biome> mapgen_biomes()
	{
		sv_<luanti_mapgen::Params::Biome> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_biomes");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_biomes(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Biome b;
			b.name = table_string(L, "name");
			b.c_top = (uint32_t)table_number(L, "c_top", 0);
			b.c_filler = (uint32_t)table_number(L, "c_filler", 0);
			b.c_stone = (uint32_t)table_number(L, "c_stone", 0);
			b.c_water_top = (uint32_t)table_number(L, "c_water_top", 0);
			b.c_water = (uint32_t)table_number(L, "c_water", 0);
			b.c_river_water = (uint32_t)table_number(L, "c_river_water", 0);
			b.c_riverbed = (uint32_t)table_number(L, "c_riverbed", 0);
			b.c_dust = (uint32_t)table_number(L, "c_dust", 0);
			b.c_dungeon = (uint32_t)table_number(L, "c_dungeon", 0);
			b.c_dungeon_alt = (uint32_t)table_number(L, "c_dungeon_alt", 0);
			b.c_dungeon_stair =
					(uint32_t)table_number(L, "c_dungeon_stair", 0);
			b.depth_top = (int32_t)table_number(L, "depth_top", 0);
			b.depth_filler = (int32_t)table_number(L, "depth_filler", 0);
			b.depth_water_top =
					(int32_t)table_number(L, "depth_water_top", 0);
			b.depth_riverbed = (int32_t)table_number(L, "depth_riverbed", 0);
			b.y_min = (int32_t)table_number(L, "y_min", -31000);
			b.y_max = (int32_t)table_number(L, "y_max", 31000);
			b.x_min = (int32_t)table_number(L, "x_min", -31000);
			b.x_max = (int32_t)table_number(L, "x_max", 31000);
			b.z_min = (int32_t)table_number(L, "z_min", -31000);
			b.z_max = (int32_t)table_number(L, "z_max", 31000);
			b.heat_point = (float)table_number(L, "heat_point", 0);
			b.humidity_point = (float)table_number(L, "humidity_point", 0);
			b.vertical_blend = (int32_t)table_number(L, "vertical_blend", 0);
			b.weight = (float)table_number(L, "weight", 1);
			out.push_back(b);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu biomes for the mapgen", out.size());
		return out;
	}

	// A noise as a mod wrote it, off the table the Lua side built
	luanti_mapgen::Params::NoiseParams read_np(lua_State *L,
			const char *field)
	{
		luanti_mapgen::Params::NoiseParams np;
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			np.given = table_boolean(L, "given");
			np.offset = (float)table_number(L, "offset", 0);
			np.scale = (float)table_number(L, "scale", 1);
			np.spread_x = (float)table_number(L, "spread_x", 250);
			np.spread_y = (float)table_number(L, "spread_y", 250);
			np.spread_z = (float)table_number(L, "spread_z", 250);
			np.seed = (int32_t)table_number(L, "seed", 0);
			np.octaves = (int32_t)table_number(L, "octaves", 3);
			np.persist = (float)table_number(L, "persist", 0.6);
			np.lacunarity = (float)table_number(L, "lacunarity", 2);
			np.flags = table_string(L, "flags");
		}
		lua_pop(L, 1);
		return np;
	}

	// What the game asked the mapgen to report, which is what
	// core.set_gen_notify() has been told. Read once, when the world's
	// generator is made.
	//
	// simplified: a mod that calls core.set_gen_notify() after the world
	// has started is not heard -- the generator holds a copy and runs in
	// another thread. Every mod that asks does it while it loads, which is
	// before this is read. Telling the generator later would be a message
	// to luanti_mapgen and a lock around the flags in every mapgen.
	void mapgen_gen_notify(ss_ &flags_out, sv_<uint32_t> &deco_ids_out)
	{
		if(!m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "get_gen_notify");
		if(lua_pcall(L, 0, 2, 0) != 0){
			log_w(MODULE, "get_gen_notify(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return;
		}
		if(lua_isstring(L, -2))
			flags_out = lua_tostring(L, -2);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				deco_ids_out.push_back((uint32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
	}

	// The ores the game registered, in the shape luanti_mapgen builds its
	// OreManager out of. The same crossing as the biomes, one layer down.
	sv_<luanti_mapgen::Params::Ore> mapgen_ores()
	{
		sv_<luanti_mapgen::Params::Ore> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_ores");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_ores(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Ore o;
			o.name = table_string(L, "name");
			o.type = table_string(L, "type");
			o.c_ore = (uint32_t)table_number(L, "c_ore", 0);
			o.clust_scarcity = (int32_t)table_number(L, "clust_scarcity", 1);
			o.clust_num_ores = (int32_t)table_number(L, "clust_num_ores", 1);
			o.clust_size = (int32_t)table_number(L, "clust_size", 0);
			o.y_min = (int32_t)table_number(L, "y_min", -31000);
			o.y_max = (int32_t)table_number(L, "y_max", 31000);
			o.ore_param2 = (int32_t)table_number(L, "ore_param2", 0);
			o.flags = table_string(L, "flags");
			o.nthresh = (float)table_number(L, "nthresh", 0);
			o.column_height_min =
					(int32_t)table_number(L, "column_height_min", 1);
			o.column_height_max =
					(int32_t)table_number(L, "column_height_max", 0);
			o.column_midpoint_factor =
					(float)table_number(L, "column_midpoint_factor", 0.5);
			o.random_factor = (float)table_number(L, "random_factor", 1);
			o.stratum_thickness =
					(int32_t)table_number(L, "stratum_thickness", 8);
			o.np = read_np(L, "np");
			o.np_puff_top = read_np(L, "np_puff_top");
			o.np_puff_bottom = read_np(L, "np_puff_bottom");
			o.np_stratum_thickness = read_np(L, "np_stratum_thickness");
			lua_getfield(L, -1, "c_wherein");
			if(lua_istable(L, -1)){
				const size_t m = lua_objlen(L, -1);
				for(size_t j = 1; j <= m; j++){
					lua_rawgeti(L, -1, (int)j);
					o.c_wherein.push_back((uint32_t)lua_tonumber(L, -1));
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
			lua_getfield(L, -1, "biomes");
			if(lua_istable(L, -1)){
				const size_t m = lua_objlen(L, -1);
				for(size_t j = 1; j <= m; j++){
					lua_rawgeti(L, -1, (int)j);
					const char *p = lua_tostring(L, -1);
					if(p)
						o.biomes.push_back(ss_(p));
					lua_pop(L, 1);
				}
			}
			lua_pop(L, 1);
			out.push_back(o);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu ores for the mapgen", out.size());
		return out;
	}

	// A list of numbers off a table field, for the id lists a decoration and
	// an ore cross with
	static void read_id_list(lua_State *L, const char *field,
			sv_<uint32_t> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				out.push_back((uint32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	static void read_int_list(lua_State *L, const char *field,
			sv_<int32_t> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				out.push_back((int32_t)lua_tonumber(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	static void read_string_list(lua_State *L, const char *field,
			sv_<ss_> &out)
	{
		lua_getfield(L, -1, field);
		if(lua_istable(L, -1)){
			const size_t n = lua_objlen(L, -1);
			for(size_t i = 1; i <= n; i++){
				lua_rawgeti(L, -1, (int)i);
				const char *p = lua_tostring(L, -1);
				if(p)
					out.push_back(ss_(p));
				lua_pop(L, 1);
			}
		}
		lua_pop(L, 1);
	}

	// The decorations the game registered, in the shape luanti_mapgen builds
	// its DecorationManager out of
	sv_<luanti_mapgen::Params::Decoration> mapgen_decorations()
	{
		sv_<luanti_mapgen::Params::Decoration> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_decorations");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__mapgen_decorations(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const size_t n = lua_istable(L, -1) ? lua_objlen(L, -1) : 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			luanti_mapgen::Params::Decoration d;
			d.name = table_string(L, "name");
			d.type = table_string(L, "type");
			d.sidelen = (int32_t)table_number(L, "sidelen", 8);
			d.fill_ratio = (float)table_number(L, "fill_ratio", 0.02);
			d.y_min = (int32_t)table_number(L, "y_min", -31000);
			d.y_max = (int32_t)table_number(L, "y_max", 31000);
			d.flags = table_string(L, "flags");
			d.nspawnby = (int32_t)table_number(L, "nspawnby", -1);
			d.place_offset_y = (int32_t)table_number(L, "place_offset_y", 0);
			d.check_offset = (int32_t)table_number(L, "check_offset", -1);
			d.deco_height = (int32_t)table_number(L, "deco_height", 1);
			d.deco_height_max =
					(int32_t)table_number(L, "deco_height_max", 0);
			d.deco_param2 = (int32_t)table_number(L, "deco_param2", 0);
			d.deco_param2_max =
					(int32_t)table_number(L, "deco_param2_max", 0);
			d.rotation = table_string(L, "rotation");
			d.np = read_np(L, "np");
			read_id_list(L, "c_place_on", d.c_place_on);
			read_id_list(L, "c_spawnby", d.c_spawnby);
			read_id_list(L, "c_decos", d.c_decos);
			read_string_list(L, "biomes", d.biomes);
			lua_getfield(L, -1, "ltree");
			if(lua_istable(L, -1)){
				luanti_mapgen::Params::Decoration::LTree &t = d.ltree;
				t.given = table_boolean(L, "given");
				t.axiom = table_string(L, "axiom");
				t.rules_a = table_string(L, "rules_a");
				t.rules_b = table_string(L, "rules_b");
				t.rules_c = table_string(L, "rules_c");
				t.rules_d = table_string(L, "rules_d");
				t.c_trunk = (uint32_t)table_number(L, "c_trunk", 0);
				t.c_leaves = (uint32_t)table_number(L, "c_leaves", 0);
				t.c_leaves2 = (uint32_t)table_number(L, "c_leaves2", 0);
				t.c_fruit = (uint32_t)table_number(L, "c_fruit", 0);
				t.leaves2_chance =
						(int32_t)table_number(L, "leaves2_chance", 0);
				t.angle = (int32_t)table_number(L, "angle", 0);
				t.iterations = (int32_t)table_number(L, "iterations", 2);
				t.random_level = (int32_t)table_number(L, "random_level", 0);
				t.trunk_type = table_string(L, "trunk_type");
				t.thin_branches = table_boolean(L, "thin_branches");
				t.fruit_chance = (int32_t)table_number(L, "fruit_chance", 0);
				t.seed = (int32_t)table_number(L, "seed", 0);
				t.explicit_seed = table_boolean(L, "explicit_seed");
			}
			lua_pop(L, 1);
			lua_getfield(L, -1, "schematic");
			if(lua_istable(L, -1)){
				luanti_mapgen::Params::Schematic &sch = d.schematic;
				sch.given = table_boolean(L, "given");
				sch.file = table_string(L, "file");
				sch.size_x = (int32_t)table_number(L, "size_x", 0);
				sch.size_y = (int32_t)table_number(L, "size_y", 0);
				sch.size_z = (int32_t)table_number(L, "size_z", 0);
				read_string_list(L, "node_names", sch.node_names);
				read_id_list(L, "ids", sch.ids);
				read_int_list(L, "param1", sch.param1);
				read_int_list(L, "param2", sch.param2);
				read_int_list(L, "yslice_prob", sch.yslice_prob);
				lua_getfield(L, -1, "replacements");
				if(lua_istable(L, -1)){
					lua_pushnil(L);
					while(lua_next(L, -2) != 0){
						const char *k = lua_tostring(L, -2);
						const char *v = lua_tostring(L, -1);
						if(k && v)
							sch.replacements[ss_(k)] = ss_(v);
						lua_pop(L, 1);
					}
				}
				lua_pop(L, 1);
			}
			lua_pop(L, 1);
			out.push_back(d);
			lua_pop(L, 1);
		}
		lua_settop(L, base);
		log_i(MODULE, "%zu decorations for the mapgen", out.size());
		return out;
	}

	sm_<ss_, uint32_t> content_ids_by_name()
	{
		sm_<ss_, uint32_t> out;
		if(!m_lua)
			return out;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__content_ids_by_name");
		if(lua_pcall(L, 0, 1, 0) != 0){
			log_w(MODULE, "__content_ids_by_name(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		if(lua_istable(L, -1)){
			lua_pushnil(L);
			while(lua_next(L, -2) != 0){
				size_t len = 0;
				const char *name = lua_tolstring(L, -2, &len);
				const lua_Integer id = lua_tointeger(L, -1);
				if(name && id >= 0)
					out[ss_(name, len)] = (uint32_t)id;
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return out;
	}

	// What the world's own settings call the mapgen. This is Luanti's
	// map_meta.txt: the mapgen a world was made with belongs to the world
	// and not to the configuration, so it is written into the save the
	// first time and read from there afterwards -- otherwise a world grows
	// a second kind of terrain the day the default changes.
	//
	// A save nobody has opened gets what the settings say and, failing
	// that, what Luanti gives a new world: v7. A save that was played
	// before any of this was written down gets what it was played with,
	// which was singlenode.
	void publish_lbm_introduced()
	{
		ss_ names;
		if(m_store)
			m_store->get("lbm_introduced", names);
		set_global_string("__luanti_lbm_introduced", names);
	}

	ss_ mapgen_name()
	{
		ss_ stored;
		if(m_store && m_store->get("mg_name", stored) && !stored.empty())
			return stored;
		ss_ out = mapgen_name_from_settings();
		if(out.empty())
			out = m_world_is_new ? "v7" : "singlenode";
		if(m_store)
			m_store->set("mg_name", out);
		return out;
	}

	// Where the water line is, which every mapgen builds around. Luanti
	// keeps it in map_meta.txt beside the mapgen's name, so it is the
	// world's and not the configuration's: the save's own if it has one,
	// then what the game's settings say, and then Luanti's default.
	int mapgen_water_level()
	{
		ss_ stored;
		if(m_store && m_store->get("water_level", stored) && !stored.empty())
			return atoi(stored.c_str());
		ss_ from_settings = setting_string("water_level");
		const int out = from_settings.empty() ? 1 :
				atoi(from_settings.c_str());
		if(m_store)
			m_store->set("water_level", itos(out));
		return out;
	}

	// And which of the things a mapgen makes it is told to make: caves,
	// dungeons, the light, the decorations, the biomes, the ores. Luanti's
	// own words, and the same place as the water level.
	ss_ mapgen_flags()
	{
		ss_ stored;
		if(m_store && m_store->get("mg_flags", stored) && !stored.empty())
			return stored;
		ss_ out = setting_string("mg_flags");
		if(out.empty())
			out = "caves,dungeons,light,decorations,biomes,ores";
		if(m_store)
			m_store->set("mg_flags", out);
		return out;
	}

	// One of the world's settings as Lua has it, which is world.mt over the
	// defaults the vendored settingtypes.txt carries
	ss_ setting_string(const ss_ &name)
	{
		if(!m_lua)
			return "";
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "settings");
		lua_getfield(L, -1, "get");
		lua_pushvalue(L, -2);
		lua_pushlstring(L, name.c_str(), name.size());
		ss_ out;
		if(lua_pcall(L, 2, 1, 0) == 0){
			size_t len = 0;
			const char *str = lua_tolstring(L, -1, &len);
			if(str && len)
				out = ss_(str, len);
		}
		lua_settop(L, base);
		return out;
	}

	ss_ mapgen_name_from_settings()
	{
		if(!m_lua)
			return "";
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mapgen_name");
		lua_pushboolean(L, m_world_is_new);
		ss_ out;
		if(lua_pcall(L, 1, 1, 0) == 0){
			size_t len = 0;
			const char *s = lua_tolstring(L, -1, &len);
			if(s && len)
				out = ss_(s, len);
		}
		lua_settop(L, base);
		return out;
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

	// worldgen has filled a section and merged it into the world. The
	// callbacks a mod registered run here, on the main thread, over terrain
	// that is already in the map -- which is the same order Luanti gives
	// them: its mapgen has written the chunk by the time they see it.
	void on_section_generated(const worldgen::SectionGenerated &event)
	{
		drop_read_cache();
		if(m_check_map_pending)
			m_generated_sections.insert(section_key(event.section_p));
		if(!m_game_running || event.scene != m_scene)
			return;
		for(const pv::Vector3DInt16 &c : chunks_completed(event.section_p))
			run_on_generated_chunk(c);
	}

	// The chunks run_on_generated_chunk() has been over in this run. Not
	// saved: a chunk is complete when its last section is generated, and
	// that happens once.
	std::set<int64_t> m_chunks_run;
	// The chunks a generated section is in that are still missing one,
	// so their on_generated has not run: emerge_area() does not call a
	// block of one there yet, as Luanti calls it after on_generated.
	// simplified: a section between its merge and its event here reads
	// as there already; the window is one event dispatch.
	std::set<int64_t> m_chunks_pending;
	// Sections asked for only to complete a chunk. One of them arriving
	// completes what it can and asks for nothing more: asking again would
	// complete the next chunk out, and the next, without end.
	std::set<uint64_t> m_completion_sections;
	// A pending chunk's sections, pinned the way a forceload pins one
	// until its on_generated has run: the streamer unloads what no point
	// holds, and the game's writes into an unloaded section are dropped --
	// VoxeLibre's bedrock and void were, under the box a test asked for.
	sm_<int64_t, sv_<uint64_t>> m_chunk_pins;

	static int64_t chunk_key(int x, int y, int z)
	{
		return ((int64_t)(int16_t)x << 32) | ((int64_t)(uint16_t)y << 16) |
				(int64_t)(uint16_t)z;
	}

	// Luanti runs a game's on_generated once per mapchunk, over all of
	// it, and a game's chances and boxes are written against that. A
	// chunk is in up to eight sections; this returns the ones this section
	// completed. Near a player or the spawn, the sections a chunk is still
	// missing are asked for too, so the ground there is finished; anywhere
	// else a chunk waits until something wants a block of it (see
	// ask_chunk() in l_loaded_at). Completing every chunk a section touches
	// is what Luanti does not do -- an emerge there generates one chunk --
	// and with VoxeLibre's dungeons, which emerge their own surroundings,
	// it never stopped spreading.
	sv_<pv::Vector3DInt16> chunks_completed(const pv::Vector3DInt16 &section_p)
	{
		using luanti_mapgen::chunk_index;
		sv_<pv::Vector3DInt16> out;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		if(sx <= 0)
			return out;
		const int x0 = section_p.getX() * sx, y0 = section_p.getY() * sy,
				z0 = section_p.getZ() * sz;
		const bool asked = m_completion_sections.erase(section_key(section_p));
		const bool may_ask = !asked && near_a_point(section_p);
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(int cz = chunk_index(z0); cz <= chunk_index(z0 + sz - 1); cz++)
			for(int cy = chunk_index(y0); cy <= chunk_index(y0 + sy - 1); cy++)
			for(int cx = chunk_index(x0); cx <= chunk_index(x0 + sx - 1); cx++){
				if(m_chunks_run.count(chunk_key(cx, cy, cz)))
					continue;
				if(ask_chunk(world, cx, cy, cz, may_ask))
					out.push_back(pv::Vector3DInt16(cx, cy, cz));
			}
		});
		if(m_load_points_changed){
			m_load_points_changed = false;
			update_load_points();
		}
		return out;
	}

	// Whether a chunk not yet run has all its sections generated; true
	// marks it run, and the caller runs it. With ask, the missing ones are
	// asked for -- from the save, which is synchronous, or from the
	// generator, whose answer comes back through on_section_generated().
	bool ask_chunk(voxelworld::Instance *world, int cx, int cy, int cz,
			bool ask)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		const int sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int nx = cx * CHUNK_NODES + CHUNK_OFFSET;
		const int ny = cy * CHUNK_NODES + CHUNK_OFFSET;
		const int nz = cz * CHUNK_NODES + CHUNK_OFFSET;
		const int64_t key = chunk_key(cx, cy, cz);
		bool complete = true;
		const bool pin = ask && !m_chunk_pins.count(key);
		for(int z = floordiv(nz, sz); z <= floordiv(nz + CHUNK_NODES - 1, sz); z++)
		for(int y = floordiv(ny, sy); y <= floordiv(ny + CHUNK_NODES - 1, sy); y++)
		for(int x = floordiv(nx, sx); x <= floordiv(nx + CHUNK_NODES - 1, sx); x++){
			const pv::Vector3DInt16 sp(x, y, z);
			if(pin){
				m_forceloaded[section_key(sp)]++;
				m_chunk_pins[key].push_back(section_key(sp));
				m_load_points_changed = true;
			}
			if(world->is_section_generated(sp))
				continue;
			if(ask){
				world->load_or_generate_section(sp);
				if(world->is_section_generated(sp))
					continue;
				m_completion_sections.insert(section_key(sp));
			}
			complete = false;
		}
		if(complete){
			m_chunks_run.insert(key);
			m_chunks_pending.erase(key);
		} else {
			m_chunks_pending.insert(key);
		}
		return complete;
	}

	// Inside the generate radius of the spawn's point or a player's
	bool near_a_point(const pv::Vector3DInt16 &sp)
	{
		auto in_reach = [&](const pv::Vector3DInt16 &c, int rxz, int ry){
			return std::abs(sp.getX() - c.getX()) <= rxz &&
					std::abs(sp.getZ() - c.getZ()) <= rxz &&
					std::abs(sp.getY() - c.getY()) <= ry;
		};
		if(in_reach(pv::Vector3DInt16(0, 0, 0), SPAWN_RADIUS, SPAWN_RADIUS_Y))
			return true;
		for(const auto &pair : m_player_pos){
			if(in_reach(section_of(pair.second), m_generate_radius_xz,
					GENERATE_RADIUS_Y))
				return true;
		}
		return false;
	}

	// Chunks an emerge completed, run on the next tick: l_loaded_at is
	// called from Lua, and a mod's on_generated is not run inside it
	sv_<pv::Vector3DInt16> m_chunks_to_run;
	// Pins changed inside a voxelworld access, where the points cannot be
	// pushed: whoever made the access pushes them after it
	bool m_load_points_changed = false;

	void run_completed_chunks()
	{
		sv_<pv::Vector3DInt16> list;
		list.swap(m_chunks_to_run);
		for(const pv::Vector3DInt16 &c : list)
			run_on_generated_chunk(c);
	}

	// A mod's on_generated over one mapchunk, as Luanti calls it: the
	// chunk's corners, the blockseed its mapgen used, and what the mapgen
	// reported and mapped there
	void run_on_generated_chunk(const pv::Vector3DInt16 &c)
	{
		using luanti_mapgen::CHUNK_NODES;
		using luanti_mapgen::CHUNK_OFFSET;
		sv_<luanti_mapgen::GennotifyEvent> events;
		luanti_mapgen::SectionMaps maps;
		luanti_mapgen::access(m_server, [&](luanti_mapgen::Interface *im){
			im->take_gennotify(c.getX(), c.getY(), c.getZ(), events);
			im->take_maps(c.getX(), c.getY(), c.getZ(), maps);
		});
		const int x0 = c.getX() * CHUNK_NODES + CHUNK_OFFSET;
		const int y0 = c.getY() * CHUNK_NODES + CHUNK_OFFSET;
		const int z0 = c.getZ() * CHUNK_NODES + CHUNK_OFFSET;
		run_on_generated_box(x0, y0, z0, x0 + CHUNK_NODES - 1,
				y0 + CHUNK_NODES - 1, z0 + CHUNK_NODES - 1,
				luanti_mapgen::chunk_blockseed(c.getX(), c.getY(), c.getZ(),
						m_seed),
				gennotify_string(events), maps);
		auto pins = m_chunk_pins.find(chunk_key(c.getX(), c.getY(), c.getZ()));
		if(pins != m_chunk_pins.end()){
			for(uint64_t k : pins->second){
				auto it = m_forceloaded.find(k);
				if(it != m_forceloaded.end() && --it->second <= 0)
					m_forceloaded.erase(it);
			}
			m_chunk_pins.erase(pins);
		}
	}

	// The world create_instance() just made, asked for before anything reads
	// it, and -- in a singlenode world only -- filled here as well.
	//
	// The fill is what makes a singlenode world a world: nobody answers a
	// generation request there, so without it the map is void rather than
	// air. A world with a mapgen must not have it. Its air would be written
	// into sections the generator has not reached yet, and air that is
	// already in the map is terrain as far as anything else is concerned --
	// which is how a v7 world came to have a room the size of this loop
	// under its surface (2026-09-13, and see "What the first playtest of a
	// generated world found" in doc/plan/luanti_module_plan.md).
	//
	// The sections are still asked for either way: worldgen answers in its
	// own thread and the answers arrive after run_game() has returned, but
	// asking early is what gets the ground near the origin on its way
	// before a player is standing on it.
	void generate_world()
	{
		const bool fill = (mapgen_name() == "singlenode");
		const pv::Vector3DInt32 p0(-SPAWN_RADIUS, -SPAWN_RADIUS_Y,
				-SPAWN_RADIUS);
		const pv::Vector3DInt32 p1(SPAWN_RADIUS, SPAWN_RADIUS_Y,
				SPAWN_RADIUS);
		size_t n = 0, already = 0;
		sv_<pv::Vector3DInt16> generated;
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
				if(!fill)
					continue;
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
				generated.push_back(section_p);
				n++;
			}
		});
		if(fill){
			log_v(MODULE, "The world: %zu sections filled with one node in "
					"%i ms, %zu already there", n,
					(int)((interface::os::time_us() - t0) / 1000), already);
		} else {
			log_v(MODULE, "The world: the sections around the origin asked "
					"for in %i ms; the mapgen fills them",
					(int)((interface::os::time_us() - t0) / 1000));
		}
		// Outside the access: a mod's on_generated reads and writes the map
		// through a VoxelManip, which is voxelworld again
		for(const pv::Vector3DInt16 &section_p : generated)
			run_on_generated(section_p);
	}

	// A mod's core.register_on_generated, over the section that has just
	// been filled. Luanti runs these after its mapgen has written a chunk
	// and before the block is put in the map; here the fill is already in
	// the map and a mod writes over it, which is the same order from a
	// mod's point of view -- what it reads is the generated terrain and
	// what it writes lands on top.
	//
	// Not inside a voxelworld access: what a mod does here is a VoxelManip,
	// which reaches into voxelworld itself.
	//
	// simplified: per section, with a section's own blockseed. What calls
	// this is a singlenode world's fill, where there is no mapgen chunk;
	// a generated world runs run_on_generated_chunk() instead.
	void run_on_generated(const pv::Vector3DInt16 &section_p)
	{
		if(!m_scene || m_section_size.getX() <= 0)
			return;
		const int32_t sx = m_section_size.getX(), sy = m_section_size.getY(),
				sz = m_section_size.getZ();
		const int32_t x0 = (int32_t)section_p.getX() * sx;
		const int32_t y0 = (int32_t)section_p.getY() * sy;
		const int32_t z0 = (int32_t)section_p.getZ() * sz;
		run_on_generated_box(x0, y0, z0, x0 + sx - 1, y0 + sy - 1,
				z0 + sz - 1, (uint32_t)block_seed(section_p), "",
				luanti_mapgen::SectionMaps());
	}

	void run_on_generated_box(int x0, int y0, int z0, int x1, int y1, int z1,
			uint32_t blockseed, const ss_ &gennotify,
			const luanti_mapgen::SectionMaps &maps)
	{
		if(!m_scene)
			return;
		{
			interface::MutexScope ms(m_lua_mutex);
			set_global_string("__luanti_gennotify", gennotify);
			set_global_maps(maps);
		}
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__run_on_generated(%i, %i, %i, %i, %i, %i, %u)",
				x0, y0, z0, x1, y1, z1, (unsigned)blockseed);
		// Timed because it is a mod's code over a quarter of a million
		// voxels on the server's own thread: Luanti generates on an emerge
		// thread of its own, and this module has one Lua state and no
		// thread to put it on. A mapgen that takes longer than a step is
		// what makes that a problem rather than a note.
		const int64_t t0 = interface::os::time_us();
		// No light flood for what the mods write here: the box they
		// touched is relit once, later, under the tick's budget, and the
		// flood from a cave-carving section was 550 ms of the same work
		// ([STEP_SLICE])
		m_gen_writing = true;
		m_gen_wrote = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(true);
		});
		node_action(buf);
		flush_node_writes();
		m_gen_writing = false;
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			world->set_light_deferred(false);
			if(m_gen_wrote)
				world->relight_region_later(m_gen_bbox);
		});
		const int64_t took = interface::os::time_us() - t0;
		if(took > 1000){
			log_v(MODULE, "on_generated (%i, %i, %i): %i ms",
					x0, y0, z0, (int)(took / 1000));
		}
		// A generator that takes longer than a step is one the streamer
		// should ask less of: one section a pass instead of two, until it
		// is quick again. This is what set_stream_budget() is for, and only
		// this module can see how long its own mods took.
		m_stream_budget = (took > (int64_t)(STEP_S * 1000000.0)) ? 1 : 2;
	}

	// What the mapgen made in a chunk and was asked to report, as a
	// line per event: the name, and where it is. A string because that is
	// the boundary the rest of this crossing uses, and because a section
	// with three hundred decorations in it is ten kilobytes of it.
	static ss_ gennotify_string(
			const sv_<luanti_mapgen::GennotifyEvent> &events)
	{
		ss_ out;
		for(const luanti_mapgen::GennotifyEvent &e : events){
			out += e.name;
			out += " "+itos(e.x)+" "+itos(e.y)+" "+itos(e.z)+"\n";
		}
		return out;
	}

	// __luanti_mapgen_maps = {size_x, size_z, heightmap = {...}, biomemap,
	// heatmap, humiditymap}: the section's maps as Lua arrays, x fastest
	// then z, 1-based; a map the mapgen did not make is absent, and the
	// whole table nil when there are none
	void set_global_maps(const luanti_mapgen::SectionMaps &maps)
	{
		lua_State *L = m_lua;
		if(maps.heightmap.empty() && maps.biomemap.empty()){
			lua_pushnil(L);
			lua_setglobal(L, "__luanti_mapgen_maps");
			return;
		}
		lua_newtable(L);
		lua_pushinteger(L, maps.size_x);
		lua_setfield(L, -2, "size_x");
		lua_pushinteger(L, maps.size_z);
		lua_setfield(L, -2, "size_z");
		auto push_ints = [&](const char *name, const int16_t *p16,
				const uint16_t *pu16, size_t n){
			if(n == 0)
				return;
			lua_createtable(L, (int)n, 0);
			for(size_t i = 0; i < n; i++){
				lua_pushinteger(L, p16 ? (int)p16[i] : (int)pu16[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		auto push_floats = [&](const char *name, const sv_<float> &v){
			if(v.empty())
				return;
			lua_createtable(L, (int)v.size(), 0);
			for(size_t i = 0; i < v.size(); i++){
				lua_pushnumber(L, v[i]);
				lua_rawseti(L, -2, (int)i + 1);
			}
			lua_setfield(L, -2, name);
		};
		push_ints("heightmap", maps.heightmap.data(), nullptr,
				maps.heightmap.size());
		push_ints("biomemap", nullptr, maps.biomemap.data(),
				maps.biomemap.size());
		push_floats("heatmap", maps.heatmap);
		push_floats("humiditymap", maps.humidmap);
		lua_setglobal(L, "__luanti_mapgen_maps");
	}

	// Luanti's get_blockseed2, which is what a mapgen's randomness starts
	// from: the world's seed and where the block is
	int32_t block_seed(const pv::Vector3DInt16 &p)
	{
		return (int32_t)(uint32_t)((uint64_t)m_seed % 0x100000000ULL) +
				(int32_t)p.getZ() * 38134234 +
				(int32_t)p.getY() * 42123 +
				(int32_t)p.getX() * 23;
	}

	// lua/check_map.lua, with the flush this module does between its two
	// halves: a round trip that never leaves the write-behind buffer would
	// prove nothing about voxelworld.
	// The check works above where any mapgen builds, in sections that
	// nothing else keeps: a player's point is elsewhere, the streamer
	// unloads what no point holds, and a generator that arrives after the
	// check has written its room owns that section and writes over it. So
	// the sections are pinned the way a forceload pins one, asked for, and
	// the round trip waits until a generator has been over every one of
	// them -- which is what anything writing terrain of its own has to do.
	void start_check_map()
	{
		m_check_sections = check_map_sections();
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			const uint64_t k = section_key(sp);
			m_forceloaded[k]++;
			m_check_pinned.push_back(k);
		}
		update_load_points();
		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &sp : m_check_sections){
				if(!world->is_section_loaded(sp))
					world->load_or_generate_section(sp);
			}
		});
		m_check_map_pending = true;
		m_check_map_waited = 0.0f;
	}

	// Once a generator has been over all of them; see start_check_map()
	void check_map_when_ready(float dtime)
	{
		if(!m_check_map_pending)
			return;
		m_check_map_waited += dtime;
		// Every section a generator has actually been over, which is what
		// on_section_generated() records. voxelworld calls a section
		// generated as soon as it has asked for one, and the volume arrives
		// later -- so waiting on that would have the check writing its room
		// just before the generator wrote over it.
		bool ready = true;
		for(const pv::Vector3DInt16 &sp : m_check_sections){
			if(m_generated_sections.count(section_key(sp)) == 0){
				ready = false;
				break;
			}
		}
		if(!ready){
			// A world whose generator never answers is a world this cannot
			// check; it is said once and the check is dropped rather than
			// waited for forever
			if(m_check_map_waited < 20.0f)
				return;
			log_w(MODULE, "check_map: the sections it uses were not "
					"generated in %.0f seconds; skipping the check",
					(double)m_check_map_waited);
			m_check_map_pending = false;
			unpin_check_map();
			return;
		}
		m_check_map_pending = false;
		m_generated_sections.clear();
		check_map_round_trip();
		unpin_check_map();
	}

	void unpin_check_map()
	{
		for(uint64_t k : m_check_pinned){
			auto it = m_forceloaded.find(k);
			if(it != m_forceloaded.end() && --it->second <= 0)
				m_forceloaded.erase(it);
		}
		m_check_pinned.clear();
		update_load_points();
	}

	void check_map_round_trip()
	{
		run_chunk_string("if not core.__check_map_write() then\n"
				"    core.log('verbose', 'check_map: no node to write')\n"
				"    core.__check_map_read = function() end\n"
				"end\n", "check_map_write");
		flush_node_writes();
		// A self-check that fails is a warning, not the end of a running
		// game: it has read `ignore` back once under a 6.8 s emerge step
		// with a player in the world, and took the server with it. What
		// it found is logged and stays open -- [CHECK_MAP_FLAKE] in
		// doc/plan/luanti_module_plan.md.
		try {
			run_chunk_string("core.__check_map_read()", "check_map_read");
		} catch(std::exception &e){
			log_w(MODULE, "check_map: the round trip failed and the game "
					"goes on: %s", e.what());
		}
		// The check puts air back where it wrote; that has to land too, or
		// the world starts with a block of cobble nobody asked for
		flush_node_writes();
	}

	// The sections core.__check_map_box() reaches into
	sv_<pv::Vector3DInt16> check_map_sections()
	{
		sv_<pv::Vector3DInt16> out;
		if(!m_lua || m_section_size.getX() <= 0)
			return out;
		int32_t b[6] = {};
		{
			interface::MutexScope ms(m_lua_mutex);
			lua_State *L = m_lua;
			int base = lua_gettop(L);
			lua_getglobal(L, "core");
			lua_getfield(L, -1, "__check_map_box");
			if(lua_pcall(L, 0, 6, 0) != 0){
				log_w(MODULE, "__check_map_box(): %s",
						lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
				lua_settop(L, base);
				return out;
			}
			for(int i = 0; i < 6; i++)
				b[i] = (int32_t)lua_tonumber(L, -6 + i);
			lua_settop(L, base);
		}
		const pv::Vector3DInt16 p0 = section_of(
				pv::Vector3DInt32(b[0], b[1], b[2]));
		const pv::Vector3DInt16 p1 = section_of(
				pv::Vector3DInt32(b[3], b[4], b[5]));
		for(int16_t z = p0.getZ(); z <= p1.getZ(); z++)
		for(int16_t y = p0.getY(); y <= p1.getY(); y++)
		for(int16_t x = p0.getX(); x <= p1.getX(); x++)
			out.push_back(pv::Vector3DInt16(x, y, z));
		return out;
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

	// Luanti's own: -0.5 + (level - (8 - range) + 0.5) / range, so a level-7
	// node at VoxeLibre's range of 7 sits at 0.43, a fourteenth down --
	// the dip beside every source that is the shoreline and the river.
	// The early return to 0.5 for level 7 that stood here flattened it
	// ([LIQUID_SURFACE]); the corner rule in the mesher is where a
	// source's full height wins, not here.
	static float liquid_level_top(int level, int range)
	{
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
	// shape: meshoptions' bits 0-2 -- 0 the "x" (two quads on the
	// diagonals), 1 the "+" (two quads on the axes), 2 the "*" (three
	// quads 60 degrees apart), 3 the "#" (four quads, two along each axis
	// a quarter in from the middle), 4 the "#" leaning outwards. Each
	// quad is visual_scale wide, as official's drawPlantlike has it
	// (vertices at +-BS/2 * scale, then the turn), so a diagonal quad's
	// reach along an axis is that over sqrt(2): a cross from corner to
	// corner was 41 % too wide at every scale ([PLANT_SIZE]).
	static void add_plant_quads(sv_<interface::VoxelQuad> &out, float scale,
			float base = -0.5f, uint8_t tile = 0, unsigned shape = 0)
	{
		const float half = 0.5f * scale;
		const float r = half * 0.70710678f;
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
		switch(shape){
		case 1: // +
			quad(-half, 0, half, 0);
			quad(0, half, 0, -half);
			break;
		case 2: // *, three at 60 degrees, the first along x
			for(int i = 0; i < 3; i++){
				const float a = (float)i * 3.14159265f / 3.0f;
				const float dx = half * cosf(a), dz = half * sinf(a);
				quad(-dx, -dz, dx, dz);
			}
			break;
		case 3: // #, two along each axis, a quarter in from the middle
		case 4: // the same leaning outwards; simplified: drawn upright
			quad(-half, -0.25f * scale, half, -0.25f * scale);
			quad(-half, 0.25f * scale, half, 0.25f * scale);
			quad(-0.25f * scale, half, -0.25f * scale, -half);
			quad(0.25f * scale, half, 0.25f * scale, -half);
			break;
		default: // x
			quad(-r, -r, r, r);
			quad(-r, r, r, -r);
			break;
		}
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
		// One entity, at one node and two up and three across, and one
		// timer on the node the metadata is on
		auto static_objects = [&](ss_ &os){
			u8s(os, 0);                 // version
			u16s(os, 1);                // one object
			u8s(os, 7);                 // a LuaEntity, which is a mod's own
			u32s(os, 1 * 10 * 1000);    // the position, in BS thousandths
			u32s(os, 2 * 10 * 1000);
			u32s(os, 3 * 10 * 1000);
			string16(os, "an object");
		};
		auto node_timers = [&](ss_ &os){
			u8s(os, 2 + 4 + 4);         // how long one of them is
			u16s(os, 1);                // one node has one
			u16s(os, 258);              // the same node the metadata is on
			u32s(os, 5000);             // five seconds long
			u32s(os, 2500);             // and half way through
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
			if(b.objects.size() != 1 || b.objects[0].type != 7 ||
					b.objects[0].data != "an object" ||
					b.objects[0].x != 1.0f || b.objects[0].y != 2.0f ||
					b.objects[0].z != 3.0f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"entity it was holding");
			if(b.timers.size() != 1 || b.timers.count(258) == 0 ||
					b.timers.at(258).timeout != 5.0f ||
					b.timers.at(258).elapsed != 2.5f)
				throw Exception(ss_("check_mapblock: ")+what+" lost the "
						"timer on a node");
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
			static_objects(inside);
			node_timers(inside);
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
			static_objects(data);
			u32s(data, 12345);          // timestamp
			nimap(data);
			node_timers(data);
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

		// The LBM list a Luanti world carries, which decides what this
		// module leaves alone in an imported world
		assert(lbm_names_of("a:one~0;b:two~1234;") == "a:one;b:two;");
		assert(lbm_names_of("a:one~0") == "a:one;");
		assert(lbm_names_of("") == "");
		// A name with no time is not a record and is dropped rather than
		// taken as a name, and a record with no name is dropped too
		assert(lbm_names_of("nope;a:one~0;") == "a:one;");
		assert(lbm_names_of("~5;") == "");

		// A palette is stretched over the 256 param2 values, so a colour
		// covers as many of them as the directions under it: devtest's
		// facedir palette is eight colours and its facedir is five bits.
		assert(palette_slot_of_param(8, 0) == 0);
		assert(palette_slot_of_param(8, 31) == 0);
		assert(palette_slot_of_param(8, 32) == 1);
		assert(palette_slot_of_param(8, 255) == 7);
		assert(palette_slot_of_param(64, 4) == 1);   // color4dir
		assert(palette_slot_of_param(32, 8) == 1);   // colorwallmounted
		assert(palette_slot_of_param(256, 137) == 137); // color
		assert(palette_slot_of_param(1, 255) == 0);
		// And a variant index stays inside the byte that indexes them: a
		// colour times a direction is never more than the param itself
		assert(palette_slot_of_param(8, 255) * 24 +
				facing_variant_of_param("facedir", 255) < 256);
		assert(palette_slot_of_param(64, 255) * 4 +
				facing_variant_of_param("4dir", 255) < 256);
		assert(palette_slot_of_param(32, 255) * 8 +
				facing_variant_of_param("wallmounted", 255) < 256);

		// A palette named as a "[combine" expression is the picture it
		// places, cut to the size it names
		{
			int w = 0, h = 0;
			sv_<CombinePlace> places;
			assert(parse_combine(
					"[combine:16x2:0,0=mcl_core_palette_foliage.png",
					w, h, places));
			assert(w == 16 && h == 2);
			assert(places.size() == 1);
			assert(places[0].x == 0 && places[0].y == 0);
			assert(places[0].name == "mcl_core_palette_foliage.png");
			places.clear();
			assert(parse_combine("[combine:4x4:0,0=a.png:1,2=b.png",
					w, h, places));
			assert(places.size() == 2);
			assert(places[1].x == 1 && places[1].y == 2 &&
					places[1].name == "b.png");
			places.clear();
			assert(!parse_combine("mcl_core_palette_grass.png", w, h, places));
			assert(!parse_combine("[multiply:#ff0000", w, h, places));
			assert(!parse_combine("[combine:16x2", w, h, places));
			assert(!parse_combine("[combine:16x2:0,0=", w, h, places));
			assert(!parse_combine("[combine:0x0:0,0=a.png", w, h, places));
		}

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
	uint8_t named_connect_group(const ss_ &name)
	{
		auto it = m_named_connect_groups.find(name);
		if(it != m_named_connect_groups.end())
			return it->second;
		uint8_t id = 32;
		if(m_next_rail_connect_group <= 32){
			id = (uint8_t)m_next_rail_connect_group++;
		} else if(!m_rail_connect_groups_exhausted){
			m_rail_connect_groups_exhausted = true;
			log_w(MODULE, "More than 31 connect groups; the rest share one "
					"and connect to each other");
		}
		m_named_connect_groups[name] = id;
		return id;
	}

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
	// One texture of a definition, with the surface numbers the shared
	// guess gave the node (extensions/luanti_client/surface.lua, through
	// bootstrap.lua's __voxel_defs(); see [VOXEL_MATERIALS]).
	// `frames` is how many animation frames the texture is a vertical strip
	// of: the segment is then the first of them, which is what the atlas's
	// own total_segments is for. One is a still texture.
	static interface::AtlasSegmentDefinition make_segment(const ss_ &texture,
			const interface::AtlasSegmentDefinition &surface,
			size_t frames = 1)
	{
		interface::AtlasSegmentDefinition seg = surface;
		seg.resource_name = texture;
		seg.total_segments = magic::IntVector2(
				texture.empty() ? 0 : 1,
				texture.empty() ? 0 : (int)(frames < 1 ? 1 : frames));
		seg.select_segment = magic::IntVector2(0, 0);
		return seg;
	}

	// The six surface numbers of the definition on top of the stack, as a
	// segment with no texture; what the guess did not say keeps the
	// numbers the module used to give every tile
	interface::AtlasSegmentDefinition table_surface(lua_State *L)
	{
		interface::AtlasSegmentDefinition s;
		s.roughness = 0.95f;
		s.spec_strength = 0.15f;
		s.bumpiness = 0.0f;
		lua_getfield(L, -1, "surface");
		if(lua_istable(L, -1)){
			s.roughness = (float)table_number(L, "roughness", s.roughness);
			s.spec_strength = (float)table_number(L, "spec_strength",
					s.spec_strength);
			s.bumpiness = (float)table_number(L, "bumpiness", s.bumpiness);
			s.translucency = (float)table_number(L, "translucency", 0);
			s.spots = (float)table_number(L, "spots", 0);
			s.static_spots = (float)table_number(L, "static_spots", 0);
		}
		lua_pop(L, 1);
		return s;
	}

	// The colours in a palette image, row by row and at most 256 of them,
	// which is the order Luanti reads one in. A node with a palette wears
	// the colour its param2 picks; Luanti stretches the palette over the
	// 256 param values, so an eight-colour palette changes every
	// thirty-two, and that stretching is done where the variants are built.
	//
	// Read here and not on the client because what the client is sent is a
	// texture name, and the name is the tile through a modifier that
	// multiplies it by one of these.
	// One shipped image, loaded. False and a warning if the game never sent
	// it or it is not a picture.
	bool load_media_image(const ss_ &name, magic::Image &img)
	{
		auto it = m_served_media.find(name);
		if(it == m_served_media.end()){
			log_w(MODULE, "image \"%s\" was not shipped", cs(name));
			return false;
		}
		std::ifstream ifs(it->second, std::ios::binary);
		std::ostringstream os;
		os<<ifs.rdbuf();
		const ss_ data = os.str();
		if(data.empty()){
			log_w(MODULE, "image \"%s\" is empty", cs(name));
			return false;
		}
		magic::MemoryBuffer buf(data.c_str(), (unsigned)data.size());
		if(!img.Load(buf)){
			log_w(MODULE, "image \"%s\" did not load", cs(name));
			return false;
		}
		return true;
	}

	// A palette is usually a file, but a game may name it as a texture
	// modifier instead, which Luanti composes through the same pipeline as
	// any other texture: VoxeLibre's vines ask for
	// "[combine:16x2:0,0=mcl_core_palette_foliage.png", which is that
	// palette's first two rows and nothing else.
	//
	// simplified: [combine and no other modifier, and what it places has to
	// be a file rather than a modifier of its own. Anything further warns
	// and the node goes without its palette; the upgrade is the client's own
	// texmod.lua evaluated over an Image rather than over a texture.
	// How many frames a strip of animation frames holds. Luanti works it out
	// of the image's own proportions and the aspect the definition gives --
	// TileDef::animation against the texture's width and height -- so this
	// reads the size out of the file's PNG header rather than decoding it.
	// A tile whose name is not a plain file, or is not a PNG, answers one
	// and is left as it is.
	size_t tile_frame_count(const ss_ &name, float aspect)
	{
		auto cached = m_frame_counts.find(name);
		if(cached != m_frame_counts.end())
			return cached->second;
		size_t frames = 1;
		auto media = m_served_media.find(name);
		if(media != m_served_media.end()){
			std::ifstream ifs(media->second, std::ios::binary);
			uint8_t hdr[24] = {};
			ifs.read((char*)hdr, sizeof hdr);
			static const uint8_t SIG[8] = {
				0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'};
			if(ifs.gcount() == (std::streamsize)sizeof hdr &&
					memcmp(hdr, SIG, 8) == 0 &&
					memcmp(hdr + 12, "IHDR", 4) == 0){
				const uint32_t w = ((uint32_t)hdr[16] << 24) |
						((uint32_t)hdr[17] << 16) |
						((uint32_t)hdr[18] << 8) | (uint32_t)hdr[19];
				const uint32_t h = ((uint32_t)hdr[20] << 24) |
						((uint32_t)hdr[21] << 16) |
						((uint32_t)hdr[22] << 8) | (uint32_t)hdr[23];
				if(w > 0 && h > 0 && aspect > 0.0f){
					const float n = (float)h / (float)w * aspect;
					if(n >= 1.5f && n < 1024.0f)
						frames = (size_t)(n + 0.5f);
				}
			}
		}
		m_frame_counts[name] = frames;
		return frames;
	}

	bool palette_image(const ss_ &name, magic::Image &img)
	{
		if(name.empty() || name[0] != '[')
			return load_media_image(name, img);
		int w = 0, h = 0;
		sv_<CombinePlace> places;
		if(!parse_combine(name, w, h, places)){
			log_w(MODULE, "palette \"%s\" is not a modifier this composes",
					cs(name));
			return false;
		}
		img.SetSize(w, h, 4);
		img.Clear(magic::Color(0, 0, 0, 0));
		for(const CombinePlace &place : places){
			magic::Image piece(img.GetContext());
			if(!load_media_image(place.name, piece))
				return false;
			for(int y = 0; y < piece.GetHeight(); y++){
				for(int x = 0; x < piece.GetWidth(); x++){
					if(place.x + x >= w || place.y + y >= h ||
							place.x + x < 0 || place.y + y < 0)
						continue;
					img.SetPixel(place.x + x, place.y + y,
							piece.GetPixel(x, y));
				}
			}
		}
		return true;
	}

	const sv_<uint32_t>& palette_colours(const ss_ &name)
	{
		auto cached = m_palettes.find(name);
		if(cached != m_palettes.end())
			return cached->second;
		sv_<uint32_t> &out = m_palettes[name];
		main_context::access(m_server, [&](main_context::Interface *imc){
			magic::Image img(imc->get_context());
			if(!palette_image(name, img))
				return;
			const int w = img.GetWidth(), h = img.GetHeight();
			for(int y = 0; y < h && (int)out.size() < 256; y++){
				for(int x = 0; x < w && (int)out.size() < 256; x++){
					magic::Color c = img.GetPixel(x, y);
					out.push_back(
							((uint32_t)(c.r_ * 255.0f + 0.5f) << 16) |
							((uint32_t)(c.g_ * 255.0f + 0.5f) << 8) |
							(uint32_t)(c.b_ * 255.0f + 0.5f));
				}
			}
		});
		log_v(MODULE, "palette \"%s\": %zu colours", cs(name), out.size());
		return out;
	}

	// The quads a "mesh" node is made of, read out of the model file the
	// game shipped. lua/mesh.lua picks the reader by extension; a format
	// nothing reads comes back empty and the node keeps its cube.
	//
	// Read here rather than on the client because a node's shape belongs in
	// its definition, where every other drawtype's shape is: the client is
	// sent quads and does not care where they came from.
	// frame < 0: the bind pose; otherwise the model posed at that frame of
	// its animation (b3d only; see lua/b3dmesh.lua)
	sv_<interface::VoxelQuad> mesh_quads(const ss_ &name, float scale,
			float frame = -1.0f)
	{
		sv_<interface::VoxelQuad> out;
		auto it = m_served_media.find(name);
		if(it == m_served_media.end()){
			log_v(MODULE, "mesh \"%s\" was not shipped", cs(name));
			return out;
		}
		std::ifstream ifs(it->second, std::ios::binary);
		std::ostringstream os;
		os<<ifs.rdbuf();
		const ss_ data = os.str();
		if(data.empty())
			return out;
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mesh_quads");
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, data.c_str(), data.size());
		lua_pushnumber(L, scale);
		lua_pushnumber(L, frame);
		if(lua_pcall(L, 4, 2, 0) != 0){
			log_w(MODULE, "__mesh_quads(\"%s\"): %s", cs(name),
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
			lua_settop(L, base);
			return out;
		}
		const int skipped = (int)lua_tonumber(L, -1);
		if(!lua_istable(L, -2)){
			lua_settop(L, base);
			return out;
		}
		// Twenty-one numbers a quad: the tile, four corners and four
		// texture coordinates
		const size_t n = lua_objlen(L, -2);
		out.reserve(n / 21);
		for(size_t i = 0; i + 20 < n; i += 21){
			interface::VoxelQuad quad;
			double v[21];
			for(size_t j = 0; j < 21; j++){
				lua_rawgeti(L, -2, (int)(i + j + 1));
				v[j] = lua_tonumber(L, -1);
				lua_pop(L, 1);
			}
			quad.tile = (uint8_t)v[0];
			for(size_t c = 0; c < 4; c++){
				for(size_t k = 0; k < 3; k++)
					quad.p[c][k] = (float)v[1 + c * 3 + k];
				for(size_t k = 0; k < 2; k++)
					quad.uv[c][k] = (float)v[13 + c * 2 + k];
			}
			out.push_back(quad);
		}
		lua_settop(L, base);
		log_v(MODULE, "mesh \"%s\": %zu quads%s", cs(name), out.size(),
				skipped > 0 ? cs(ss_()+", "+itos(skipped)+
				" faces are neither triangles nor quads") : "");
		return out;
	}

	// "#rrggbb", which is what a texture modifier takes
	static ss_ hex_colour(uint32_t rgb)
	{
		char buf[8];
		snprintf(buf, sizeof buf, "#%02x%02x%02x",
				(rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff);
		return ss_(buf);
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
	// Where a paletted node's colour goes in a tile's expression. The Lua
	// side marks the place per layer -- see PALETTE_MARK in
	// lua/bootstrap.lua -- because **Luanti applies the node's colour to a
	// layer only when that layer has no colour of its own**, and the layers
	// are composed there while the palette is resolved here. A node with no
	// palette passes an empty mul and the marks come out.
	static ss_ with_palette(const ss_ &expr, const ss_ &mul)
	{
		static const ss_ mark = ss_("\1pal\1");
		ss_ out;
		out.reserve(expr.size());
		size_t at = 0;
		for(;;){
			const size_t found = expr.find(mark, at);
			if(found == ss_::npos){
				out += expr.substr(at);
				break;
			}
			out += expr.substr(at, found - at);
			out += mul;
			at = found + mark.size();
		}
		return out;
	}

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
		size_t n_palette_nodes = 0;
		size_t n_palette_variants = 0;
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			ss_ name = table_string(L, "name");
			bool sunlight = table_boolean(L, "sunlight");
			// What the node's own colour multiplies its tiles by, where a
			// paletted node's slot colour would go ([WATER_LIGHT] 2)
			const ss_ node_mul = table_string(L, "node_mul");
			bool alpha_blend = table_boolean(L, "alpha_blend");
			bool alpha_clip = table_boolean(L, "alpha_clip");
			bool empty = table_boolean(L, "empty");
			bool walkable = table_boolean(L, "walkable");
			bool climbable = table_boolean(L, "climbable");
			double move_resistance = table_number(L, "move_resistance", 0);
			double bouncy = table_number(L, "bouncy", 0);
			double slippery = table_number(L, "slippery", 0);
			bool disable_jump = table_boolean(L, "disable_jump");
			bool disable_descend = table_boolean(L, "disable_descend");
			bool swimmable = table_boolean(L, "swimmable");
			double pointable = table_number(L, "pointable", 1);
			ss_ drawtype = table_string(L, "drawtype");
			const interface::AtlasSegmentDefinition surface = table_surface(L);
			float visual_scale = (float)table_number(L, "visual_scale", 1.0);
			ss_ tiles[6];
			bool has_tiles = table_six_strings(L, "tiles", tiles);
			// Which of them are a strip of animation frames, as the aspect
			// the frame count is worked out with; 0 is a still tile
			float tile_aspect[6] = {};
			table_six_numbers(L, "tile_frames", tile_aspect);
			sv_<float> boxes;
			table_numbers(L, "node_box", boxes);
			sv_<float> collision_boxes;
			table_numbers(L, "collision_box", collision_boxes);
			sv_<float> connected_boxes;
			table_numbers(L, "node_box_connected", connected_boxes);
			const ss_ connects = table_string(L, "node_box_connects");
			const ss_ own_groups = table_string(L, "node_box_groups");
			ss_ facing = table_string(L, "facing");
			ss_ overlay_tile = table_string(L, "overlay_tile");
			ss_ liquid_group = table_string(L, "liquid_group");
			ss_ palette = table_string(L, "palette");
			ss_ mesh = table_string(L, "mesh");
			int raillike_group = (int)table_number(L, "raillike_group", 0);
			int liquid_range = (int)table_number(L, "liquid_range",
					LIQUID_LEVELS);
			// What the node glows with, which is what lamp light floods
			// from; a Luanti game's mechanics read that light
			const uint8_t light_source = (uint8_t)std::min(15.0,
					std::max(0.0, table_number(L, "light_source", 0)));
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
			if(drawtype == "mesh" && !mesh.empty()){
				// The model's own quads, in the node's own cube -- and the
				// parts of it that reach outside, which is how a model two
				// nodes tall is one node with an airlike one over it. A
				// format nothing here reads leaves the node the cube it had.
				shape = mesh_quads(mesh,
						visual_scale > 0.0f ? visual_scale : 1.0f);
				// A mesh node's tiles are two-sided unless one says
				// otherwise: Luanti's read_tiledef() sets default_culling
				// false for NDT_MESH the way it does for plantlike. Models
				// are authored for that -- VoxeLibre's sunflower gives the
				// front and the back of its flower head as two quads with
				// the same winding, so culling loses both of them and the
				// stem is left standing on its own.
				//
				// The extension has drawn them this way from the start --
				// see shapes.lua, NDT_MESH -- which is why its picture of
				// the same world has flowers on its sunflowers.
				//
				// simplified: a tile that sets backface_culling itself is
				// not heard, here or anywhere else; what that would take is
				// a flag per quad rather than per shape.
				double_sided = true;
			} else if(drawtype == "nodebox" && boxes.size() >= 6){
				for(size_t b = 0; b + 5 < boxes.size(); b += 6){
					add_box_quads(shape, boxes[b], boxes[b + 1], boxes[b + 2],
							boxes[b + 3], boxes[b + 4], boxes[b + 5]);
				}
			} else if(drawtype == "nodebox" && connected_boxes.size() >= 7){
				// A "connected" box: the fixed part, and a set per side
				// drawn when the neighbour there is one of its connects_to
				// groups or solid -- the fence's own rule with the game's
				// boxes. Its own group is the first of its connects_to it
				// belongs to, so a fence reaches fences and a pane panes.
				// simplified: a target group whose nodes are not solid and
				// were not registered as connected boxes themselves (a
				// fence gate) is not reached; connects_to is read as
				// "any solid" for the rest.
				for(size_t b = 0; b + 6 < connected_boxes.size(); b += 7){
					const size_t first = shape.size();
					add_box_quads(shape, connected_boxes[b + 1],
							connected_boxes[b + 2], connected_boxes[b + 3],
							connected_boxes[b + 4], connected_boxes[b + 5],
							connected_boxes[b + 6]);
					const uint8_t tag = (uint8_t)connected_boxes[b];
					if(tag != 0)
						for(size_t i = first; i < shape.size(); i++)
							shape[i].connect_dir = tag;
				}
				sv_<ss_> targets;
				{
					std::istringstream is(connects);
					ss_ g;
					while(std::getline(is, g, ';'))
						if(!g.empty())
							targets.push_back(g);
				}
				for(const ss_ &g : targets){
					const uint8_t id = named_connect_group(g);
					connect_mask |= 1u << (id - 1);
					if(connect_group == 0 && (";" + own_groups + ";").find(
							";" + g + ";") != ss_::npos)
						connect_group = id;
				}
				if(connect_group == 0 && !targets.empty())
					connect_group = named_connect_group(targets[0]);
				connect_to_solid = true;
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
				} else if(facing == "meshoptions" && drawtype == "plantlike"){
					// The shape the param2 names, 1.4x with bit 4
					const float vs = visual_scale > 0.0f ? visual_scale : 1.0f;
					add_plant_quads(var.shape, (i & 8) ? vs * 1.4f : vs,
							-0.5f, 0, (unsigned)(i & 7));
				} else if(!shape.empty() && !shape_over_cube && d != 0){
					// A node that has a shape turns the shape too: a stair
					// facing the other way is the same quads rotated, and
					// the tile each quad names travels with it. Only for a
					// shape that is the node's own cube -- a rooted plant's
					// shape stands in the voxel above and turning it would
					// take it sideways out of that voxel.
					turn_quads(shape, d, var.shape);
				}
				// And what stops the player, turned the same way; empty for
				// the definition's own
				if(walkable && !empty && d != 0)
					turn_boxes(collision_boxes, d, var.collision_boxes);
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
			// How many animation frames each face's texture is a strip of;
			// the segment takes the first of them, so water is water and
			// not sixteen waters squeezed onto one face
			size_t face_frames[6] = {1, 1, 1, 1, 1, 1};
			bool any_fallback = false;
			for(size_t f = 0; f < 6; f++){
				if(empty)
					continue;
				ss_ texture = has_tiles ?
						texture_of_tile(with_palette(tiles[f], node_mul)) : "";
				if(!texture.empty()){
					face_textures[f] = texture;
					if(tile_aspect[f] > 0.0f)
						face_frames[f] = tile_frame_count(
								with_palette(tiles[f], node_mul),
								tile_aspect[f]);
				} else {
					face_textures[f] = fallback;
					any_fallback = true;
				}
			}
			// The plant of a rooted plant: a texture the cube it stands in
			// does not have, and the first of the definition's extra ones
			ss_ overlay_texture;
			if(!overlay_tile.empty() && !fallback.empty()){
				overlay_texture = texture_of_tile(
						with_palette(overlay_tile, node_mul));
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
				vdef.textures[f] = make_segment(face_textures[f], surface,
						face_frames[f]);
			// The textures a shape's quads can wear beyond the six faces: a
			// rooted plant's plant, which is nothing the cube it stands in
			// has. Quad tile 6 is the first of these.
			if(!overlay_texture.empty())
				vdef.extra_textures.push_back(make_segment(overlay_texture,
						surface));
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
			vdef.light_source = light_source;
			vdef.physically_solid = walkable && !empty;
			// Nothing here draws differently for it; the client's own
			// physics is what reads it. See "the interaction gaps".
			vdef.climbable = climbable;
			if(walkable && !empty)
				turn_boxes(collision_boxes, 0, vdef.collision_boxes);
			vdef.move_resistance = (uint8_t)(move_resistance < 0 ? 0 :
					(move_resistance > 255 ? 255 : move_resistance));
			vdef.bouncy = (uint8_t)(bouncy < 0 ? 0 : (bouncy > 255 ? 255 : bouncy));
			vdef.slippery = (uint8_t)(slippery < 0 ? 0 :
					(slippery > 255 ? 255 : slippery));
			vdef.disable_jump = disable_jump;
			vdef.disable_descend = disable_descend;
			vdef.swimmable = swimmable;
			vdef.pointable = (uint8_t)(pointable < 0 ? 0 :
					(pointable > 2 ? 2 : pointable));
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
			// A palette: the node wears the colour its param2 picks, as its
			// own tiles through a modifier that multiplies them. Colours
			// multiply the directions rather than permuting with them, so
			// this is the facing variants once per colour -- eight colours
			// of a facedir node are 192 variants but 48 textures.
			//
			// A node whose tiles were not shipped wears a generated flat
			// colour and is left alone: there is no image for a modifier to
			// be applied to.
			if(!palette.empty() && !any_fallback){
				const sv_<uint32_t> &colours = palette_colours(palette);
				sv_<interface::VoxelVariant> base = vdef.variants;
				if(base.empty())
					base.push_back(interface::VoxelVariant());
				const size_t n_dirs = base.size();
				// Luanti stretches a palette over the 256 param2 values, so
				// what a param picks is the pixel at param * pixels / 256 --
				// which is also what leaves the direction bits alone,
				// because a sane palette has exactly as many colours as the
				// bits above the direction can count
				size_t slots = colours.size();
				if(slots > 256 / n_dirs)
					slots = 256 / n_dirs;
				if(slots > 0){
					sv_<interface::VoxelVariant> coloured;
					coloured.reserve(slots * n_dirs);
					for(size_t c = 0; c < slots; c++){
						// The tile through a modifier that multiplies it,
						// which is an expression like any other: the client
						// composes it and what the definition carries is the
						// name it composes it under
						const ss_ mul = "^[multiply:" + hex_colour(
								colours[c * colours.size() / slots]);
						ss_ tinted[7];
						for(size_t f = 0; f < 6; f++){
							if(has_tiles && !tiles[f].empty())
								tinted[f] = texture_of_tile(
										with_palette(tiles[f], mul));
						}
						if(!overlay_tile.empty())
							tinted[6] = texture_of_tile(
									with_palette(overlay_tile, mul));
						for(size_t i = 0; i < n_dirs; i++){
							interface::VoxelVariant var = base[i];
							for(size_t f = 0; f < 6; f++){
								var.textures.push_back(tinted[f].empty() ?
										interface::AtlasSegmentDefinition() :
										make_segment(tinted[f], surface,
										face_frames[f]));
							}
							if(!tinted[6].empty()){
								var.textures.push_back(
										make_segment(tinted[6], surface));
							}
							coloured.push_back(var);
						}
					}
					vdef.variants = coloured;
					for(size_t p = 0; p < 256; p++){
						const size_t c = palette_slot_of_param(slots,
								(uint8_t)p);
						vdef.variant_of_param[p] = (uint8_t)(c * n_dirs +
								(n_dirs > 1 ? facing_variant_of_param(
								facing, (uint8_t)p) : 0));
					}
					n_palette_nodes++;
					n_palette_variants += coloured.size();
				}
			}
			if(!liquid_group.empty()){
				vdef.is_liquid = true;
				vdef.liquid_is_source = (drawtype == "liquid");
				vdef.shape_group = liquid_shape_group(liquid_group);
				vdef.liquid_top = 0.5f;
				// param2's low three bits are the level; the rest of it is
				// flags this does not draw. Only a flowing liquid has them:
				// a source's param2 is whatever its own paramtype2 says,
				// which for VoxeLibre's water is the palette index its
				// colour comes from -- so assigning the levels over the
				// variants unconditionally took the sea's blue away.
				if(!liquid_variants.empty()){
					vdef.variants = liquid_variants;
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
			// And the cut-out ones, which are drawn with the solid world
			// with the holes in their pictures left out: a leaf, a plant, a
			// rail, a ladder. Luanti's default for every drawtype but the
			// five solid ones, so most of a game's nodes end up here.
			vdef.alpha_masked = alpha_clip && !vdef.translucent;
			reg->add_voxel(vdef);
		}
		lua_settop(L, base);

		serve_node_textures(textures);
		log_i(MODULE, "%zu node types in the voxel registry: %zu have a shape "
				"of their own, %zu of those are liquids, %zu turn with their "
				"param2, %zu wear a colour out of a palette (%zu variants), "
				"%zu wear a generated colour because a tile is a "
				"texture modifier or was not shipped",
				n, n_shaped, n_liquid, n_facing_nodes, n_palette_nodes,
				n_palette_variants, n_fallback);
		// What the registry actually holds, which is what the client is
		// sent and what its own line of detail counts. A definition that
		// went in under a name another one already had is one voxel type
		// rather than two, and the two ends disagreeing about the count is
		// the first thing a comparison notices; see
		// doc/plan/luanti_module_plan.md, "The numbers before the pixels".
		const size_t in_registry = reg->get_count();
		if(in_registry != n){
			log_w(MODULE, "%zu of those %zu are in the registry: the rest "
					"went in under a name one of them already had",
					in_registry, n);
		}
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
	// Luanti's own textures -- the heart, the bubble, the blank tile a HUD
	// draws on, the crack over a node being dug. They are the engine's
	// rather than a game's, so Luanti's client has them built in and never
	// sends them; here the client is buildat's and gets everything from the
	// server, so they are served like any other media if the user has put
	// them where this looks.
	//
	// Not vendored: Luanti's textures are CC BY-SA with their authors listed
	// in its LICENSE.txt, and nothing here copies them into the tree. What
	// the user does is put the pack in buildat's own directory, which is the
	// same rule the games follow -- see apps/vanilla.
	// The render mode the launcher game's settings screen wrote
	// (apps/vanilla's settings.json in the user path), "" when
	// there is none. Read here with no JSON parser: the file is the
	// game's own, one line, and the key's value is a bare word.
	ss_ settings_render_mode()
	{
		std::ifstream f(m_server->get_config().get<ss_>("user_path")+
				"/shared/vanilla/settings.json");
		if(!f.good())
			return "";
		std::stringstream ss;
		ss << f.rdbuf();
		const ss_ text = ss.str();
		const size_t k = text.find("\"render_mode\"");
		if(k == ss_::npos)
			return "";
		const size_t q1 = text.find('"', k + 13);
		const size_t q2 = q1 == ss_::npos ? ss_::npos : text.find('"', q1 + 1);
		if(q2 == ss_::npos)
			return "";
		return text.substr(q1 + 1, q2 - q1 - 1);
	}

	// Luanti's own base textures -- blank.png, heart.png, bubble.png,
	// what a game's HUD asks the engine for: the copy under the module
	// (textures/base, with its licence), or the user's own if they put
	// one at user/shared/vanilla/textures/base/pack, which wins
	ss_ base_textures_path()
	{
		const ss_ user = m_server->get_config().get<ss_>("user_path")+
				"/shared/vanilla/textures/base/pack";
		if(interface::fs::path_exists(user))
			return user;
		return module_path()+"/textures/base/pack";
	}

	// The player's own texture packs: every directory under
	// user/shared/vanilla/texture_packs, by name. They go in front of everything
	// else, because first-one-wins is the rule below and a pack's whole
	// point is to override what the game ships -- including the LabPBR
	// sidecars the atlas reads ([VOXEL_MATERIALS] layer 2, whose upgrade
	// path this is: a pack put its maps among a game's mods until now).
	void collect_texture_packs(sv_<ss_> &dirs)
	{
		const ss_ root = m_server->get_config().get<ss_>("user_path")+
				"/shared/vanilla/texture_packs";
		if(!interface::fs::path_exists(root))
			return;
		sv_<ss_> names;
		for(const interface::fs::Node &n :
				interface::fs::list_directory(root)){
			if(n.name == "." || n.name == ".." || !n.is_directory)
				continue;
			names.push_back(n.name);
		}
		std::sort(names.begin(), names.end());
		for(const ss_ &name : names){
			recursive_dirs(root+"/"+name, dirs, 0);
			log_i(MODULE, "texture pack: %s", cs(name));
		}
	}

	void serve_game_media(const ss_ &game_path)
	{
		// Luanti's directories, in Luanti's order (src/server/mods.cpp)
		static const sv_<ss_> wanted = {"textures", "sounds", "media",
				"models", "locale", "fonts"};
		sv_<ss_> dirs;
		// The player's packs first: what they hold wins
		collect_texture_packs(dirs);
		// The game's own textures/, beside its mods' (src/server.cpp)
		recursive_dirs(game_path+"/textures", dirs, 0);
		// [MEDIA_OVERRIDE_ORDER] The mods in reverse load order, as
		// Luanti's getModsMediaPaths: a mod loaded later overrides a
		// dependency's media of the same name
		const sv_<ss_> mods = mod_paths_in_load_order();
		for(auto it = mods.rbegin(); it != mods.rend(); ++it)
			for(const ss_ &w : wanted)
				recursive_dirs(*it+"/"+w, dirs, 0);
		// Last, so that the first-one-wins rule below leaves a game's own
		// version of a name in front of the engine's
		const ss_ base_path = base_textures_path();
		if(interface::fs::path_exists(base_path)){
			recursive_dirs(base_path, dirs, 0);
		} else {
			log_w(MODULE, "No Luanti base textures at %s: a game's HUD asks "
					"for the engine's own textures -- blank.png, heart.png, "
					"bubble.png -- and they are not served. Copy Luanti's "
					"textures/base/pack there to have them.",
					cs(base_path));
		}
		sm_<ss_, ss_> files;
		for(const ss_ &dir : dirs)
			collect_files(dir, files);
		// One announce for the lot: a client already connected (the
		// launcher's own, [FIRST_RUN]) fetches them as one batch
		sv_<std::pair<ss_, ss_>> name_paths;
		name_paths.reserve(files.size());
		for(const auto &pair : files)
			name_paths.push_back(std::make_pair(
					media_resource_name(pair.first), pair.second));
		// Every connected peer has this batch on its way now, and its
		// texture modifiers wait for the batch's files_transmitted
		m_files_transmitted.clear();
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_paths(name_paths);
		});
		for(const auto &pair : files)
			m_served_media[pair.first] = pair.second;
		log_i(MODULE, "%zu media files from %zu directories under %s",
				files.size(), dirs.size(), cs(game_path));
	}

	// The mods' directories in the order lua/modloader.lua loaded them
	sv_<ss_> mod_paths_in_load_order()
	{
		sv_<ss_> paths;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__mod_names");
		lua_getfield(L, -2, "__mod_paths");
		if(lua_istable(L, -2) && lua_istable(L, -1)){
			for(int i = 1; ; i++){
				lua_rawgeti(L, -2, i);
				if(!lua_isstring(L, -1))
					break;
				lua_gettable(L, -2);
				if(lua_isstring(L, -1))
					paths.push_back(lua_tostring(L, -1));
				lua_pop(L, 1);
			}
		}
		lua_settop(L, base);
		return paths;
	}

	// Luanti's fs::GetRecursiveDirs: a directory before its subfolders,
	// and a subfolder whose name starts with '_' or '.' left out
	void recursive_dirs(const ss_ &dir, sv_<ss_> &out, int depth)
	{
		if(depth > 4 || !interface::fs::path_exists(dir))
			return;
		out.push_back(dir);
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.is_directory && !n.name.empty() && n.name[0] != '.' &&
					n.name[0] != '_')
				recursive_dirs(dir+"/"+n.name, out, depth + 1);
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
	// clash as well; a directory's own files only, its subfolders being
	// in the list after it (recursive_dirs)
	void collect_files(const ss_ &dir, sm_<ss_, ss_> &files)
	{
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.is_directory)
				continue;
			if(!is_media_name(n.name))
				continue;
			auto it = files.find(n.name);
			if(it != files.end()){
				log_v(MODULE, "media %s: %s, not %s/%s", cs(n.name),
						cs(it->second), cs(dir), cs(n.name));
				continue;
			}
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

	void table_six_numbers(lua_State *L, const char *key, float out[6])
	{
		lua_getfield(L, -1, key);
		if(!lua_istable(L, -1)){
			lua_pop(L, 1);
			return;
		}
		for(size_t i = 0; i < 6; i++){
			lua_rawgeti(L, -1, (int)i + 1);
			out[i] = (float)lua_tonumber(L, -1);
			lua_pop(L, 1);
		}
		lua_pop(L, 1);
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
	// The mapgen's noise, which is Luanti's own value noise: buildat
	// vendored it for its own generators and this is the same code the Lua
	// API is documented against. A mod's NoiseParams table, as the engine
	// wants it.
	static bool read_noise_params(lua_State *L, int idx,
			interface::NoiseParams &np)
	{
		if(!lua_istable(L, idx))
			return false;
		auto number = [&](const char *name, float def){
			lua_getfield(L, idx, name);
			float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : def;
			lua_pop(L, 1);
			return v;
		};
		np.offset = number("offset", 0.0f);
		np.scale = number("scale", 1.0f);
		np.seed = (int)number("seed", 0.0f);
		np.octaves = (int)number("octaves", 3.0f);
		// Luanti calls it persistence and took "persist" before that
		np.persist = number("persistence", number("persist", 0.6f));
		np.spread = interface::v3f(100.0f, 100.0f, 100.0f);
		lua_getfield(L, idx, "spread");
		if(lua_istable(L, -1)){
			const int t = lua_gettop(L);
			auto axis = [&](const char *name, float def){
				lua_getfield(L, t, name);
				float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) :
						def;
				lua_pop(L, 1);
				return v;
			};
			np.spread.X = axis("x", 100.0f);
			np.spread.Y = axis("y", np.spread.X);
			np.spread.Z = axis("z", np.spread.X);
		}
		lua_pop(L, 1);
		if(np.octaves < 1)
			np.octaves = 1;
		if(np.octaves > 16)
			np.octaves = 16;
		if(np.spread.X == 0.0f) np.spread.X = 1.0f;
		if(np.spread.Y == 0.0f) np.spread.Y = 1.0f;
		if(np.spread.Z == 0.0f) np.spread.Z = 1.0f;
		return true;
	}

	// __luanti_noise_value(np, seed, x, y [, z]) -> one value of it
	static int l_noise_value(lua_State *L)
	{
		interface::NoiseParams np;
		if(!read_noise_params(L, 1, np))
			return luaL_error(L, "noise: a NoiseParams table is wanted");
		const int seed = (int)luaL_checkinteger(L, 2) + np.seed;
		const float x = (float)luaL_checknumber(L, 3) / np.spread.X;
		const float y = (float)luaL_checknumber(L, 4) / np.spread.Y;
		float v;
		if(lua_isnoneornil(L, 5)){
			v = interface::noise2d_fbm(x, y, seed, np.octaves, np.persist);
		} else {
			const float z = (float)luaL_checknumber(L, 5) / np.spread.Z;
			v = interface::noise3d_fbm(x, y, z, seed, np.octaves, np.persist);
		}
		lua_pushnumber(L, np.offset + v * np.scale);
		return 1;
	}

	// __luanti_noise_map(np, seed, x, y, z, sx, sy, sz[, buffer]) -> a flat
	// array, x fastest and then y and then z. sz of 0 is the
	// two-dimensional map, where y is the second axis -- which is the
	// world's z, the way Luanti's own 2D maps are laid out. A buffer is
	// filled and returned, as Luanti fills the one a mod passes: a mod
	// that reads its buffer and not the return value got nothing from an
	// array made fresh (extra_ordinance's mapgen, 2026-10-03).
	static int l_noise_map(lua_State *L)
	{
		interface::NoiseParams np;
		if(!read_noise_params(L, 1, np))
			return luaL_error(L, "noise: a NoiseParams table is wanted");
		const int seed = (int)luaL_checkinteger(L, 2);
		const float x = (float)luaL_checknumber(L, 3);
		const float y = (float)luaL_checknumber(L, 4);
		const float z = (float)luaL_checknumber(L, 5);
		const int sx = (int)luaL_checkinteger(L, 6);
		const int sy = (int)luaL_checkinteger(L, 7);
		const int sz = (int)luaL_optinteger(L, 8, 0);
		if(sx < 1 || sy < 1 || sz < 0)
			return luaL_error(L, "noise: a map of %ix%ix%i", sx, sy, sz);
		const double n = (double)sx * sy * (sz > 0 ? sz : 1);
		// A cap so that a mod asking for a billion values says so rather
		// than taking the server with it. VoxeLibre's mcl_end_island asks
		// for 401 x 30 x 401 -- 4.8 million -- while it loads, which is what
		// this has to be bigger than; Luanti caps it nowhere and pays the
		// same memory. Lua's own formatter has no %.0f, so the number is
		// made into a string here.
		if(n > 16.0 * 1024 * 1024)
			return luaL_error(L, "noise: %s values is more than this makes "
					"at once", cs(itos((int64_t)n)));
		interface::Noise noise(&np, seed, sx, sy, sz > 0 ? sz : 1);
		float *result;
		if(sz > 0)
			result = noise.fbmMap3D(x, y, z);
		else
			result = noise.fbmMap2D(x, y);
		noise.transformNoiseMap();
		if(lua_istable(L, 9))
			lua_pushvalue(L, 9);
		else
			lua_createtable(L, (int)n, 0);
		for(int i = 0; i < (int)n; i++){
			lua_pushnumber(L, result[i]);
			lua_rawseti(L, -2, i + 1);
		}
		return 1;
	}

	// __luanti_get_region_data(x0, y0, z0, x1, y1, z1) -> ids, param1,
	// param2: three flat arrays, x fastest and then y and then z, which is
	// what VoxelArea indexes and what a VoxelManip holds.
	static int l_get_region_data(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = luaL_checkinteger(L, i + 1);
		if(p[3] < p[0] || p[4] < p[1] || p[5] < p[2] ||
				!box_ok(p[0], p[1], p[2], p[3], p[4], p[5])){
			for(int i = 0; i < 3; i++)
				lua_newtable(L);
			return 3;
		}
		double volume = (double)(p[3] - p[0] + 1) * (double)(p[4] - p[1] + 1) *
				(double)(p[5] - p[2] + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "get_region_data(): %.0f voxels is more "
					"than the %d this reads at once", volume,
					(int)MAX_REGION_VOXELS);
		}
		sv_<uint32_t> words;
		self->read_region(p[0], p[1], p[2], p[3], p[4], p[5], words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		const int n = (int)words.size();
		lua_createtable(L, n, 0);
		lua_createtable(L, n, 0);
		lua_createtable(L, n, 0);
		for(int i = 0; i < n; i++){
			const uint32_t word = words[i];
			lua_pushinteger(L, (lua_Integer)f.id.get(word));
			lua_rawseti(L, -4, i + 1);
			lua_pushinteger(L, (lua_Integer)(f.light_sky.get(word) |
					(f.light_lamp.get(word) << 4)));
			lua_rawseti(L, -3, i + 1);
			lua_pushinteger(L, (lua_Integer)f.param.get(word));
			lua_rawseti(L, -2, i + 1);
		}
		return 3;
	}

	// __luanti_set_region_data(x0, y0, z0, x1, y1, z1, ids, param1, param2):
	// the other direction, and one write rather than a quarter of a million.
	// param1 and param2 may be nil, and then what is there is kept.
	//
	// A section the box reaches into that does not exist is created, because
	// a VoxelManip writing where nobody has been is a mapgen doing its job.
	static int l_set_region_data(lua_State *L)
	{
		Module *self = module_of(L);
		self->drop_read_cache();
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = luaL_checkinteger(L, i + 1);
		luaL_checktype(L, 7, LUA_TTABLE);
		const bool has_p1 = !lua_isnoneornil(L, 8);
		const bool has_p2 = !lua_isnoneornil(L, 9);
		if(p[3] < p[0] || p[4] < p[1] || p[5] < p[2] ||
				!box_ok(p[0], p[1], p[2], p[3], p[4], p[5]))
			return 0;
		const double volume = (double)(p[3] - p[0] + 1) *
				(double)(p[4] - p[1] + 1) * (double)(p[5] - p[2] + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			return luaL_error(L, "set_region_data(): %.0f voxels is more "
					"than the %d this writes at once", volume,
					(int)MAX_REGION_VOXELS);
		}
		if(!self->m_scene)
			return 0;
		// What is already buffered is part of the map; a region write that
		// went in before it would be overwritten by the older value
		self->flush_node_writes();
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		// Read what is there first when the caller is only replacing some of
		// the planes, so that the light and the param2 it left out survive
		sv_<uint32_t> words;
		if(!has_p1 || !has_p2)
			self->read_region(p[0], p[1], p[2], p[3], p[4], p[5], words);
		else
			words.assign((size_t)volume, 0);
		size_t i = 0;
		for(size_t n = words.size(); i < n; i++){
			lua_rawgeti(L, 7, (int)i + 1);
			const lua_Integer id = lua_tointeger(L, -1);
			lua_pop(L, 1);
			uint32_t word = words[i];
			f.id.set(word, (uint32_t)id & 0xffff);
			if(has_p1){
				lua_rawgeti(L, 8, (int)i + 1);
				const uint32_t param1 = (uint32_t)lua_tointeger(L, -1);
				lua_pop(L, 1);
				f.light_sky.set(word, param1 & 0x0f);
				f.light_lamp.set(word, (param1 >> 4) & 0x0f);
			}
			if(has_p2){
				lua_rawgeti(L, 9, (int)i + 1);
				const uint32_t param2 = (uint32_t)lua_tointeger(L, -1);
				lua_pop(L, 1);
				f.param.set(word, param2 & 0xff);
			}
			words[i] = word;
		}
		// A box in a body's region ([BODY_INTERACT]): the body's owner
		// takes the words voxel by voxel; the map has nothing there
		if(p[1] >= REGION_Y){
			if(self->m_region_map){
				i = 0;
				for(int32_t z = p[2]; z <= p[5]; z++)
				for(int32_t y = p[1]; y <= p[4]; y++)
				for(int32_t x = p[0]; x <= p[3]; x++, i++)
					self->m_region_map->set(x, y, z, words[i]);
			}
			return 0;
		}
		interface::VoxelVolume vol(pv::Region(
				pv::Vector3DInt32(p[0], p[1], p[2]),
				pv::Vector3DInt32(p[3], p[4], p[5])));
		self->note_gen_write(vol.getEnclosingRegion());
		i = 0;
		for(int32_t z = p[2]; z <= p[5]; z++)
		for(int32_t y = p[1]; y <= p[4]; y++)
		for(int32_t x = p[0]; x <= p[3]; x++, i++)
			vol.setVoxelAt(x, y, z, interface::VoxelInstance(words[i]));
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			world->set_volume(vol, true);
		});
		return 0;
	}

	// __luanti_refshot_mark(token): tell every client that the state it is
	// looking at is complete as far as this server is concerned, and that it
	// should photograph it once it has drawn what it has been sent.
	//
	// **The ordering is the whole mechanism.** The channel is reliable and
	// ordered, so by the time the client's handler for this runs, every
	// chunk packet sent before it has already been handled -- which is what
	// turns "my mesh queue is empty" from a guess into a fact. See
	// [ONE_CYCLE] in doc/plan/rendering_plan.md.
	static int l_refshot_mark(lua_State *L)
	{
		Module *self = module_of(L);
		const int token = (int)luaL_checkinteger(L, 1);
		// And where the state looks from, so that the client's half of the
		// rule can be about that place rather than about its queue as a
		// whole -- see the comment on the client's handler
		sv_<ss_> flat;
		flat.push_back(itos(token));
		flat.push_back(ftos((float)luaL_optnumber(L, 2, 0.0)));
		flat.push_back(ftos((float)luaL_optnumber(L, 3, 0.0)));
		flat.push_back(ftos((float)luaL_optnumber(L, 4, 0.0)));
		// Optional fifth: "1" means dump the client's meshes too
		if(lua_gettop(L) >= 5 && lua_toboolean(L, 5))
			flat.push_back("1");
		sv_<ss_> names;
		for(const auto &pair : self->m_player_peers)
			names.push_back(pair.first);
		for(const ss_ &n : names)
			self->send_to_player(n, "luanti:refshot_mark", flat);
		lua_pushinteger(L, (lua_Integer)names.size());
		return 1;
	}

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

	// flush_node_writes(): what a light query calls before it reads,
	// since the flood a buffered lamp makes is only in the world once the
	// buffer has landed; see read_node()
	static int l_flush_node_writes(lua_State *L)
	{
		module_of(L)->flush_node_writes();
		return 0;
	}

	// __luanti_region_to_world(x, y, z) -> wx, wy, wz, or nil: a body's
	// region position as the world point it is drawn at ([BODY_INTERACT])
	static int l_region_to_world(lua_State *L)
	{
		Module *self = module_of(L);
		float x = (float)luaL_checknumber(L, 1);
		float y = (float)luaL_checknumber(L, 2);
		float z = (float)luaL_checknumber(L, 3);
		float wx, wy, wz;
		if(!self->m_region_map || y < REGION_Y ||
				!self->m_region_map->to_world(x, y, z, wx, wy, wz))
			return 0;
		lua_pushnumber(L, wx);
		lua_pushnumber(L, wy);
		lua_pushnumber(L, wz);
		return 3;
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

	// __luanti_ids_at(flat) -> a flat array of content ids, one per position
	// in flat, which is x, y, z per position.
	//
	// The region reads answer "what is in this box"; this answers "what is
	// at each of these scattered places", which is the other shape a caller
	// has. One access() for the lot rather than one per position: a read
	// that crosses the Lua boundary costs a module lock and its hierarchy
	// validated, and the work inside voxelworld is nearly free beside it.
	// The emerge queue asks this of every request it is waiting on, once a
	// step.
	static int l_ids_at(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		const size_t n3 = lua_objlen(L, 1);
		const size_t n = n3 / 3;
		lua_createtable(L, (int)n, 0);
		if(n == 0 || !self->m_scene)
			return 1;
		// Whatever was written and not flushed is what a reader should see,
		// the same way read_node() does it
		self->flush_node_writes();
		sv_<int32_t> p(n3);
		for(size_t i = 0; i < n3; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			p[i] = (int32_t)lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		sv_<lua_Integer> ids(n);
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(size_t i = 0; i < n; i++){
				const uint32_t word = world->get_voxel(pv::Vector3DInt32(
						p[i * 3], p[i * 3 + 1], p[i * 3 + 2]), true).data;
				ids[i] = (lua_Integer)f.id.get(word);
			}
		});
		for(size_t i = 0; i < n; i++){
			lua_pushinteger(L, ids[i]);
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	// __luanti_section_state(x, y, z) -> "unloaded", "ungenerated" or
	// "generated", of the section a position is in: what the fuzz run's
	// hole check reads ([UNGENERATED_SAVED]).
	static int l_section_state(lua_State *L)
	{
		Module *self = module_of(L);
		if(!self->m_scene || self->m_section_size.getX() <= 0){
			lua_pushstring(L, "unloaded");
			return 1;
		}
		const pv::Vector3DInt16 sp = self->section_of(pv::Vector3DInt32(
				(int32_t)luaL_checknumber(L, 1),
				(int32_t)luaL_checknumber(L, 2),
				(int32_t)luaL_checknumber(L, 3)));
		const char *state = "unloaded";
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			if(world->is_section_generated(sp))
				state = "generated";
			else if(world->is_section_loaded(sp))
				state = "ungenerated";
		});
		lua_pushstring(L, state);
		return 1;
	}

	// __luanti_loaded_at(flat) -> a flat array of booleans, one per
	// position in flat: whether the section it is in is loaded. What the
	// emerge queue actually asks of its two thousand positions a step --
	// an ungenerated section reads as ignore everywhere -- answered per
	// section in one access(), where a get_voxel() per position was 0.4 s
	// of a step and a region read per block was worse.
	static int l_loaded_at(lua_State *L)
	{
		Module *self = module_of(L);
		luaL_checktype(L, 1, LUA_TTABLE);
		const size_t n3 = lua_objlen(L, 1);
		const size_t n = n3 / 3;
		lua_createtable(L, (int)n, 0);
		if(n == 0 || !self->m_scene || self->m_section_size.getX() <= 0)
			return 1;
		sv_<int32_t> p(n3);
		for(size_t i = 0; i < n3; i++){
			lua_rawgeti(L, 1, (int)i + 1);
			p[i] = (int32_t)lua_tointeger(L, -1);
			lua_pop(L, 1);
		}
		sv_<uint64_t> keys(n);
		sm_<uint64_t, bool> loaded;
		for(size_t i = 0; i < n; i++){
			keys[i] = section_key(self->section_of(pv::Vector3DInt32(
					p[i * 3], p[i * 3 + 1], p[i * 3 + 2])));
			loaded[keys[i]] = false;
		}
		// Generated, in a world with a mapgen: a section can be loaded
		// and not generated, holding only what a neighbour's padding
		// handed it -- the bare terrain under a chunk whose on_generated
		// has not run. A singlenode world's fill marks nothing generated,
		// and there loaded is all there is to wait for.
		const bool fill_only = (self->mapgen_name() == "singlenode");
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(auto &pair : loaded){
				const pv::Vector3DInt16 sp = section_from_key(pair.first);
				pair.second = fill_only ? world->is_section_loaded(sp) :
						world->is_section_generated(sp);
			}
		});
		for(size_t i = 0; i < n; i++){
			bool ready = loaded[keys[i]];
			if(ready && !self->m_chunks_pending.empty()){
				using luanti_mapgen::chunk_index;
				const int cx = chunk_index(p[i * 3]);
				const int cy = chunk_index(p[i * 3 + 1]);
				const int cz = chunk_index(p[i * 3 + 2]);
				if(self->m_chunks_pending.count(chunk_key(cx, cy, cz))){
					// Wanted now, so finished: what Luanti's emerge of a
					// block does with its chunk
					ready = false;
					voxelworld::access(self->m_server, self->m_scene,
							[&](voxelworld::Instance *world){
						if(self->ask_chunk(world, cx, cy, cz, true))
							self->m_chunks_to_run.push_back(
									pv::Vector3DInt16(cx, cy, cz));
					});
					if(self->m_load_points_changed){
						self->m_load_points_changed = false;
						self->update_load_points();
					}
				}
			}
			lua_pushboolean(L, ready ? 1 : 0);
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
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

	// Every loaded section as a voxel box, whether or not anybody is near
	// it: what core.get_loaded_blocks() answers out of. l_active_boxes()
	// above is the same list with the active range applied.
	static int l_loaded_boxes(lua_State *L)
	{
		Module *self = module_of(L);
		lua_newtable(L);
		if(!self->m_scene)
			return 1;
		int n = 0;
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			for(const pv::Vector3DInt16 &section_p :
					world->get_loaded_sections()){
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

	// __luanti_relight(x0, y0, z0, x1, y1, z1[, now]): work the light out again in
	// the sections this box touches. A mod's mapgen writes a chunk of
	// terrain with no light in it and then asks Luanti to light it, which is
	// VoxelManip:calc_lighting(); this is that call's other half.
	static int l_relight(lua_State *L)
	{
		Module *self = module_of(L);
		self->drop_read_cache();
		int32_t p[6];
		for(int i = 0; i < 6; i++)
			p[i] = (int32_t)luaL_checknumber(L, i + 1);
		if(!self->m_scene || p[3] < p[0] || p[4] < p[1] || p[5] < p[2])
			return 0;
		// What is buffered is part of the map, and the light is worked out
		// from what is in the map
		self->flush_node_writes();
		const pv::Region region(pv::Vector3DInt32(p[0], p[1], p[2]),
				pv::Vector3DInt32(p[3], p[4], p[5]));
		// Later, under the tick's budget, not inside the mod's own step
		// ([STEP_SLICE]); a relight asked for by a fixture that reads the
		// light back at once wants BUILDAT_LUANTI_RELIGHT_NOW=1
		// The seventh argument true is core.fix_light: Luanti's is done
		// when it returns, and its callers read the light back at once
		static const bool now_env = getenv("BUILDAT_LUANTI_RELIGHT_NOW") != nullptr;
		const bool now = now_env || lua_toboolean(L, 7);
		voxelworld::access(self->m_server, self->m_scene,
				[&](voxelworld::Instance *world){
			if(now)
				world->relight_region(region);
			else
				world->relight_region_later(region);
		});
		return 0;
	}

	// The level a player can stand at above (x, z), asked of the mapgen
	// rather than of the map: Luanti's spawn search does the same thing,
	// because at the moment a player joins the map around the origin is
	// half generated and answers about the world as it was rather than as
	// it will be. nil means the mapgen says this is no place to spawn -- a
	// river, or a surface under water -- or that there is no mapgen to ask.
	static int l_spawn_level(lua_State *L)
	{
		Module *self = module_of(L);
		const int x = (int)luaL_checknumber(L, 1);
		const int z = (int)luaL_checknumber(L, 2);
		int level = 0;
		bool ok = false;
		luanti_mapgen::access(self->m_server,
				[&](luanti_mapgen::Interface *im){
			ok = im->spawn_level(self->m_mapgen_params, x, z, level);
		});
		if(!ok)
			return 0;
		lua_pushinteger(L, level);
		return 1;
	}

	// __luanti_biome_at(x, y, z) -> index, heat, humidity, out of the
	// mapgen's own noise: which biome the world would have there, whether or
	// not anything has been generated. What asks is core.get_biome_data(),
	// and a game asks it a great deal -- VoxeLibre's weather and its sky
	// colour are per biome, and both ran into a nil every step without it.
	// The lookup object, taken once through access() and asked directly
	// after: an access() is a handoff to the mapgen module's thread and
	// back, a quarter of a millisecond, and VoxeLibre asks this for every
	// leaf it recolours. Dropped when luanti_mapgen unloads, and with a
	// new world's params.
	luanti_mapgen::BiomeQuery *m_biome_query = nullptr;

	void on_module_unloaded(const interface::ModuleUnloadedEvent &event)
	{
		if(event.name == "luanti_mapgen")
			m_biome_query = nullptr;
	}

	static int l_biome_at(lua_State *L)
	{
		Module *self = module_of(L);
		const int x = (int)luaL_checknumber(L, 1);
		const int y = (int)luaL_checknumber(L, 2);
		const int z = (int)luaL_checknumber(L, 3);
		size_t index = 0;
		float heat = 0.0f, humidity = 0.0f;
		bool ok = false;
		if(self->m_biome_query == nullptr){
			luanti_mapgen::access(self->m_server,
					[&](luanti_mapgen::Interface *im){
				self->m_biome_query = im->biome_query(self->m_mapgen_params);
			});
		}
		if(self->m_biome_query != nullptr)
			ok = self->m_biome_query->biome_at(x, y, z, index, heat, humidity);
		if(!ok)
			return 0;
		lua_pushinteger(L, (lua_Integer)index);
		lua_pushnumber(L, heat);
		lua_pushnumber(L, humidity);
		return 3;
	}

	// Where the server says the player is: the spawn, a teleport, a mod
	// moving them. Where the player walks is the client's own business and
	// arrives as set_player_pos(); this is the other direction, and without
	// it a player who was somewhere else last time starts wherever their
	// client felt like.
	static int l_send_player_pos(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		sv_<ss_> flat;
		for(int i = 2; i <= 4; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.3f",
					(double)luaL_checknumber(L, i));
			flat.push_back(buf);
		}
		// And which object is the player's own; see tell_the_client()
		flat.push_back(itos((int64_t)luaL_optnumber(L, 5, 0)));
		// And which way they were facing, in Luanti's own angles: the
		// horizontal one counter-clockwise from +Z and the vertical one
		// positive downwards, both in radians, which is what
		// get_look_horizontal() and get_look_vertical() answer.
		// The client turns them into its own convention -- see send_where()
		// in apps/vanilla, which is this in reverse.
		for(int i = 6; i <= 7; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.4f",
					(double)luaL_optnumber(L, i, 0));
			flat.push_back(buf);
		}
		self->send_to_player(name, "luanti:player_pos", flat);
		return 0;
	}

	// What time it is in the world, to everyone: the time of day as a
	// fraction of a day and how fast it runs, so a client can carry the
	// clock on between one of these and the next
	static int l_send_time(lua_State *L)
	{
		Module *self = module_of(L);
		sv_<ss_> flat;
		for(int i = 1; i <= 2; i++){
			char buf[32];
			snprintf(buf, sizeof buf, "%.6f",
					(double)luaL_checknumber(L, i));
			flat.push_back(buf);
		}
		// And when it was sent, the server's clock in microseconds, so
		// the client can read how long the packet waited behind bulk on
		// the way down ([NET_CHANNELS]; the up direction is main:where's)
		char stamp[32];
		snprintf(stamp, sizeof stamp, "%lld", (long long)interface::os::time_us());
		flat.push_back(stamp);
		sv_<ss_> names;
		for(const auto &pair : self->m_player_peers)
			names.push_back(pair.first);
		for(const ss_ &n : names)
			self->send_to_player(n, "luanti:time", flat);
		return 0;
	}

	// One change to a player's own HUD: what a game adds, changes and takes
	// away, as the flat list of strings lua/entity.lua builds
	static int l_send_hud(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:hud", flat);
		return 0;
	}

	// __luanti_send_privs(player_name, {priv, priv, ...}): what the player
	// may do, on join and whenever it changes; the client gates its fly,
	// fast and noclip on it ([FLY_MODES])
	static int l_send_privs(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:privs", flat);
		return 0;
	}

	// __luanti_send_physics(player_name, {name, value, name, value, ...}):
	// a player's physics override, which is what set_physics_override()
	// writes. The client's movement is its own constants times these, so a
	// game's speed boots and low gravity are these numbers arriving.
	static int l_send_physics(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:physics", flat);
		return 0;
	}

	// __luanti_send_modes(player_name, {"fly", "fast", "noclip"}): the
	// modes the player left on in this world, on join ([FLY_STATE_SAVE]).
	// See send_modes() in lua/entity.lua.
	static int l_send_modes(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		for(size_t i = 0; i < lua_objlen(L, 2); i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p, name_len), "luanti:modes", flat);
		return 0;
	}

	// __luanti_send_camera(player_name, {fov, is_multiplier, transition,
	// eye_x, eye_y, eye_z}): how wide the view is and where the eyes are,
	// which are the client's to draw and the game's to decide. See
	// send_camera() in lua/entity.lua.
	static int l_send_camera(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:camera", flat);
		return 0;
	}

	// What the light should be for one player whatever the hour, or an
	// empty string for "the clock decides"
	// __luanti_send_sound(player_name, {...}): one sound's record at one
	// player; see lua/sound.lua for what the fields are
	static int l_send_sound(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:sound", flat);
		return 0;
	}

	// __luanti_send_particles(player_name, {...}): one particle record at
	// one player; see lua/particles.lua for what the fields are
	static int l_send_particles(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		ss_ name(name_p ? name_p : "", name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		flat.reserve(n);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(name, "luanti:particles", flat);
		return 0;
	}

	// __luanti_sound_file(group) -> one file of the group, or nil
	//
	// A game names a sound group and the media holds the files in it:
	// "default_dig_cracky" is default_dig_cracky.1.ogg and .2.ogg, and which
	// one plays is a choice per play. The module is what knows which files
	// it serves, which is why the pick is here rather than in the Lua.
	// __luanti_add_media(name, path) -> whether it was added: one more file
	// into what this game serves, while it runs. A mod that draws a picture
	// and hands it to core.dynamic_add_media() is what wants it --
	// VoxeLibre's maps are drawn per map item and per player.
	//
	// client_file announces a file to every connected client as it is added,
	// so nothing else has to be sent; the name is the game's own, the way
	// every other media file's is.
	static int l_add_media(lua_State *L)
	{
		Module *self = module_of(L);
		const ss_ name = luaL_checkstring(L, 1);
		const ss_ path = luaL_checkstring(L, 2);
		if(name.empty() || path.empty() || !interface::fs::path_exists(path)){
			lua_pushboolean(L, false);
			return 1;
		}
		client_file::access(self->m_server, [&](client_file::Interface *i){
			i->add_file_path(media_resource_name(name), path);
		});
		self->m_served_media[name] = path;
		lua_pushboolean(L, true);
		return 1;
	}

	static int l_sound_file(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		ss_ group(p ? p : "", len);
		if(group.empty())
			return 0;
		sv_<ss_> files;
		// Luanti's own suffixes: the plain name and one digit, which is
		// what its media lookup accepts. The names are asked for rather
		// than scanned for, because what the module serves is a hash map.
		if(self->m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(self->m_served_media.count(name))
				files.push_back(name);
		}
		if(files.empty())
			return 0;
		const ss_ &pick = files[rand() % files.size()];
		lua_pushlstring(L, pick.c_str(), pick.size());
		return 1;
	}

	// __luanti_sound_files(group) -> {file, file, ...}, or nil
	//
	// The same lookup as __luanti_sound_file, without the pick: what a
	// client needs to play a sound of its own off a node's definition
	// ([NO_SOUND]'s footsteps), since the group is the module's to
	// resolve and the choice per step is the client's.
	static int l_sound_files(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		ss_ group(p ? p : "", len);
		if(group.empty())
			return 0;
		sv_<ss_> files;
		if(self->m_served_media.count(group+".ogg"))
			files.push_back(group+".ogg");
		for(char d = '0'; d <= '9'; d++){
			const ss_ name = group+"."+d+".ogg";
			if(self->m_served_media.count(name))
				files.push_back(name);
		}
		if(files.empty())
			return 0;
		lua_newtable(L);
		for(size_t i = 0; i < files.size(); i++){
			lua_pushlstring(L, files[i].c_str(), files[i].size());
			lua_rawseti(L, -2, (int)i + 1);
		}
		return 1;
	}

	static int l_send_day_night(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, v_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *v_p = luaL_checklstring(L, 2, &v_len);
		sv_<ss_> flat{ss_(v_p ? v_p : "", v_len)};
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:daynight", flat);
		return 0;
	}

	// The sky one player is under, as the flat key/value list
	// lua/entity.lua builds
	static int l_send_sky(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		luaL_checktype(L, 2, LUA_TTABLE);
		sv_<ss_> flat;
		const size_t n = lua_objlen(L, 2);
		for(size_t i = 0; i < n; i++){
			lua_rawgeti(L, 2, (int)i + 1);
			size_t len = 0;
			const char *p = lua_tolstring(L, -1, &len);
			flat.push_back(ss_(p ? p : "", p ? len : 0));
			lua_pop(L, 1);
		}
		self->send_to_player(ss_(name_p ? name_p : "", name_len),
				"luanti:sky", flat);
		return 0;
	}

	// A line of chat to one player, or to everyone when the name is empty
	// __luanti_request_shutdown(message): the server stops, the message in
	// its reason; core.request_shutdown's delay and reconnect are Lua's
	static int l_request_shutdown(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_optlstring(L, 1, "", &len);
		self->m_server->shutdown(0, "a mod asked: "+ss_(p ? p : "", len));
		return 0;
	}

	static int l_send_chat(lua_State *L)
	{
		Module *self = module_of(L);
		size_t name_len = 0, msg_len = 0;
		const char *name_p = luaL_checklstring(L, 1, &name_len);
		const char *msg_p = luaL_checklstring(L, 2, &msg_len);
		ss_ name(name_p ? name_p : "", name_len);
		sv_<ss_> flat{ss_(msg_p ? msg_p : "", msg_len)};
		if(name.empty()){
			// A copy, because a client that drops out while this is going
			// out would otherwise change the map underneath it
			sv_<ss_> names;
			for(const auto &pair : self->m_player_peers)
				names.push_back(pair.first);
			for(const ss_ &n : names)
				self->send_to_player(n, "luanti:chat", flat);
		} else {
			self->send_to_player(name, "luanti:chat", flat);
		}
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
	// The reference fixture's readiness reply: the client has drawn the state
	// it was marked for and has taken the picture. Carries the token and the
	// name the picture was saved under, and nothing else -- the fixture set
	// the state, so it is the one that knows which state this is. See
	// [ONE_CYCLE] in doc/plan/rendering_plan.md.
	void on_refshot_shot(const network::Packet &packet)
	{
		sv_<ss_> flat;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(flat);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:refshot_shot: %s", e.what());
			return;
		}
		if(flat.size() < 2){
			log_w(MODULE, "luanti:refshot_shot: %zu values", flat.size());
			return;
		}
		if(!m_lua)
			return;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__refshot_shot");
		if(!lua_isfunction(L, -1)){
			// Nobody is listening, which is every run that is not taking a
			// reference set
			lua_settop(L, base);
			return;
		}
		lua_pushinteger(L, atoi(flat[0].c_str()));
		lua_pushlstring(L, flat[1].c_str(), flat[1].size());
		int nargs = 2;
		if(flat.size() >= 3){
			lua_pushlstring(L, flat[2].c_str(), flat[2].size());
			nargs = 3;
		}
		if(lua_pcall(L, nargs, 0, 0) != 0)
			log_w(MODULE, "__refshot_shot(): %s", lua_tostring(L, -1));
		lua_settop(L, base);
	}

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
				flat.size() / 4);
	}

	// The quads of one model, asked for by name: an object whose visual is a
	// mesh is drawn as that mesh, and the client is told which file by the
	// appearance and asks for the file's contents once. The same reader a
	// mesh node goes through, so a format nothing reads answers with
	// nothing and the object keeps the cube it had.
	//
	// The numbers cross as text, which is what every other flat channel
	// here does: a model is asked for once and devtest's frog is thirty
	// kilobytes of it.
	void on_get_model(const network::Packet &packet)
	{
		sv_<ss_> asked;
		try {
			std::istringstream is(packet.data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(asked);
		} catch(std::exception &e){
			log_w(MODULE, "luanti:get_model: %s", e.what());
			return;
		}
		if(asked.empty() || asked[0].empty() || !m_lua)
			return;
		const ss_ name = asked[0];
		// The second value, if any, is the frame the model is wanted
		// posed at, and the answer carries it back so the client files
		// the quads under the right key
		const ss_ frame_s = asked.size() > 1 ? asked[1] : "";
		const float frame = frame_s.empty() ? -1.0f : (float)atof(frame_s.c_str());
		// The quads as doubles, 21 a quad -- the tile, four corners, four
		// texture coordinates -- after the name and the frame: as strings
		// a pose was 40 KB and 80 ms of the client's Lua to read, and a
		// walking mob is one pose after another ([OBJECT_MESH] step 1)
		sv_<double> nums;
		{
			interface::MutexScope ms(m_lua_mutex);
			// Scale 1: an object's model is scaled by its visual_size,
			// which is the client's to apply and is not the same number
			// for two objects of one kind
			const sv_<interface::VoxelQuad> quads = mesh_quads(name, 1.0f,
					frame);
			nums.reserve(quads.size() * 21);
			for(const interface::VoxelQuad &q : quads){
				nums.push_back((double)q.tile);
				for(size_t c = 0; c < 4; c++)
					for(size_t k = 0; k < 3; k++)
						nums.push_back(q.p[c][k]);
				for(size_t c = 0; c < 4; c++)
					for(size_t k = 0; k < 2; k++)
						nums.push_back(q.uv[c][k]);
			}
		}
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(name, frame_s, nums);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:model", os.str());
		});
		log_v(MODULE, "C%zu: model \"%s\": %zu quads", (size_t)packet.sender,
				cs(name), nums.size() / 21);
	}

	// How long a dig takes and how far a tool reaches, which the client
	// works out for itself rather than asking per dig. See core.__dig_props()
	// for what a record holds.
	void on_get_dig_props(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__dig_props");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:dig_props", os.str());
		});
		log_v(MODULE, "C%zu: %zu dig prop records", (size_t)packet.sender,
				flat.size());
	}

	// The game's name, the world's seed and which Luanti this is: what the
	// client's status line shows and cannot know. Constants for a session,
	// so they are asked for once instead of riding along with the position.
	void on_get_world_info(const network::Packet &packet)
	{
		// Remembered per peer, so the packet can be sent again unasked
		// when the step peak moves ([STEP_PEAK]); a mode's name, so short
		m_peer_mode[packet.sender] = packet.data.substr(0, 32);
		send_world_info(packet.sender, packet.data);
	}

	// The step peak's number changed by what the status row would show:
	// world_info goes out again to every client that has asked for it
	static int l_step_peak(lua_State *L)
	{
		lua_getfield(L, LUA_REGISTRYINDEX, "__luanti_module");
		Module *self = (Module*)lua_touserdata(L, -1);
		lua_pop(L, 1);
		if(!self || !self->m_game_running)
			return 0;
		for(const auto &pair : self->m_peer_mode)
			self->send_world_info(pair.first, pair.second);
		return 0;
	}

	sm_<network::PeerInfo::Id, ss_> m_peer_mode;

	// What is kept per peer goes with it: a peer that never became a
	// player was never removed from these, and the step peak's re-send
	// went on to it ([SECURITY_RUN_1])
	void on_client_disconnected(const network::OldClient &old)
	{
		m_peer_mode.erase(old.info.id);
		m_files_transmitted.erase(old.info.id);
		m_texmods_waiting.erase(old.info.id);
	}

	void send_world_info(network::PeerInfo::Id peer, const ss_ &asked_mode)
	{
		sv_<ss_> flat = string_list_from_lua("__world_info");
		// Which of the three rendering modes this session draws in --
		// "unlit", "shadows" or "pbr" -- which is a startup choice and not a
		// toggle: the atlas's surface maps have to be on from the first
		// texture the client builds. So it goes with the rest of what is
		// constant for a session rather than getting a packet of its own.
		// See [RENDER_MODES] in doc/plan/rendering_plan.md.
		//
		// The client asks for its own -- the packet carries what its
		// BUILDAT_LUANTI_PBR says, through buildat.get_env() -- and the
		// server's environment is the default for one that says nothing,
		// so one server can serve a client in each mode ([PROBE_CYCLE]).
		// An unset variable on both means this client's own default, which
		// is pbr. The numbers keep working for whatever already passes
		// them: 0 was the unlit path before either had a name.
		const char *mode = getenv("BUILDAT_LUANTI_PBR");
		ss_ m = !asked_mode.empty() ? asked_mode :
				(mode != nullptr) ? ss_(mode) : ss_("");
		// Neither side saying: the launcher game's setting
		// (user/shared/vanilla/settings.json, its "render_mode"; [LAUNCH_GRID])
		if(m.empty())
			m = settings_render_mode();
		if(m == "0")
			m = "unlit";
		else if(m == "" || m == "1")
			m = "pbr";
		else if(m != "unlit" && m != "shadows" && m != "pbr" &&
				m != "pbr_debug_shadows" && m != "pbr_debug_light" &&
				m != "pbr_debug_nibbles" && m != "pbr_debug_ground" &&
				m != "pbr_debug_skyamb" && m != "pbr_debug_baked"){
			log_w(MODULE, "BUILDAT_LUANTI_PBR=\"%s\" is not a mode; "
					"drawing pbr. Wanted unlit, shadows, pbr, "
					"pbr_debug_shadows, pbr_debug_light, "
					"pbr_debug_nibbles, pbr_debug_ground, "
					"pbr_debug_skyamb or pbr_debug_baked", cs(m));
			m = "pbr";
		}
		flat.push_back(m);
		// How far this client tilts the sun and the moon's orbit when the
		// game has no opinion, in degrees. A game that sets body_orbit_tilt
		// is obeyed instead, whatever this says; see the sky handler in
		// apps/vanilla. **Zero is what a comparison against
		// official Luanti wants**, because that is what Luanti does with a
		// game that never asks. Read here rather than in the client's Lua
		// for the same reason the mode is: that half runs in the sandbox,
		// where there is no getenv.
		const char *tilt = getenv("BUILDAT_LUANTI_ORBIT_TILT");
		flat.push_back(tilt != nullptr ? ss_(tilt) : ss_(""));
		// The server's step peak and the phase that set it, [STEP_PEAK]
		for(const ss_ &v : string_list_from_lua("__step_peak_info"))
			flat.push_back(v);
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(peer, "luanti:world_info", os.str());
		});
	}

	// What the game's locale/*.tr files say, for the one language in force,
	// as domain, key, value repeating. The lookup is the client's because
	// the markers are in every string that reaches it; see lua/
	// translations.lua for which language and why it is the server that
	// picks it.
	void on_get_translations(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__translations");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:translations", os.str());
		});
		log_v(MODULE, "C%zu: %zu translated strings", (size_t)packet.sender,
				flat.size() / 3);
	}

	// A core.__<name>() that answers with an array of strings, as a vector
	sv_<ss_> string_list_from_lua(const char *name)
	{
		sv_<ss_> flat;
		interface::MutexScope ms(m_lua_mutex);
		// No game yet -- a server at its world menu -- and a client may
		// ask anyway: an empty answer, not a null state
		if(!m_lua)
			return flat;
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
	void on_get_item_palettes(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__item_palettes");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:item_palettes", os.str());
		});
		log_v(MODULE, "C%zu: %zu item palettes", (size_t)packet.sender,
				flat.size() / 2);
	}

	// What a hand holding a mesh node draws ([WIELD_MESH]); see
	// core.__wield_meshes()
	void on_get_wield_meshes(const network::Packet &packet)
	{
		sv_<ss_> flat = string_list_from_lua("__wield_meshes");
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(flat);
		}
		network::access(m_server, [&](network::Interface *inetwork){
			inetwork->send(packet.sender, "luanti:wield_meshes", os.str());
		});
	}

	void on_get_item_images(const network::Packet &packet)
	{
		sv_<ss_> flat;
		{
			interface::MutexScope ms(m_lua_mutex);
			if(!m_lua)
				return;
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
		if(n_sets == 0 || x1 < x0 || y1 < y0 || z1 < z0 ||
				!box_ok(x0, y0, z0, x1, y1, z1))
			return 1;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "find_ids(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MAX_REGION_VOXELS);
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

	// liquid_edges(x0, y0, z0, x1, y1, z1, liquid_ids, floodable_ids) ->
	// positions, flat: the liquid nodes of a generated box that have
	// somewhere to flow, which is what Mapgen::updateLiquid queues --
	// per column from the top, the topmost node of a liquid run when a
	// floodable node is beside it, and the lowest node of a run when the
	// node under it is floodable (or the topmost was not checked and is
	// flowable). Columns on the box's rim are skipped as official skips
	// them: their side neighbours are outside. Ignore ends a run without
	// queueing. [LIQUID_FLOW]
	static int l_liquid_edges(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		luaL_checktype(L, 8, LUA_TTABLE);
		lua_newtable(L);
		if(!box_ok(x0, y0, z0, x1, y1, z1) || x1 - x0 < 2 || z1 - z0 < 2 ||
				y1 < y0)
			return 1;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS)
			return luaL_error(L, "liquid_edges(): %s voxels is more than "
					"the %d this reads at once", cs(itos((int64_t)volume)),
					(int)MAX_REGION_VOXELS);
		// Bit 0: a liquid; bit 1: floodable
		sv_<uint8_t> kind(65536, 0);
		for(int arg = 7; arg <= 8; arg++){
			size_t n_ids = lua_objlen(L, arg);
			for(size_t i = 1; i <= n_ids; i++){
				lua_rawgeti(L, arg, (int)i);
				lua_Integer id = lua_tointeger(L, -1);
				lua_pop(L, 1);
				if(id >= 0 && id <= 65535)
					kind[id] |= (arg == 7) ? 1 : 2;
			}
		}
		sv_<uint32_t> words;
		self->read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		const size_t sx = x1 - x0 + 1, sy = y1 - y0 + 1;
		auto at = [&](int32_t x, int32_t y, int32_t z) -> uint16_t {
			return f.id.get(words[((size_t)(z - z0) * sy + (y - y0)) * sx +
					(x - x0)]);
		};
		auto flowable = [&](int32_t x, int32_t y, int32_t z) -> bool {
			return (kind[at(x + 1, y, z)] & 2) || (kind[at(x - 1, y, z)] & 2) ||
					(kind[at(x, y, z + 1)] & 2) || (kind[at(x, y, z - 1)] & 2);
		};
		int n = 0;
		auto push = [&](int32_t x, int32_t y, int32_t z){
			lua_pushinteger(L, x); lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, y); lua_rawseti(L, -2, ++n);
			lua_pushinteger(L, z); lua_rawseti(L, -2, ++n);
		};
		for(int32_t z = z0 + 1; z <= z1 - 1; z++)
		for(int32_t x = x0 + 1; x <= x1 - 1; x++){
			bool wasignored = true, wasliquid = false;
			bool waschecked = false, waspushed = false;
			for(int32_t y = y1; y >= y0; y--){
				uint16_t id = at(x, y, z);
				bool isignored = id == 0;
				bool isliquid = (kind[id] & 1) != 0;
				if(isignored || wasignored || isliquid == wasliquid){
					waschecked = false;
					waspushed = false;
				} else if(isliquid){
					// The topmost node of a liquid run
					bool pushed = false;
					if(flowable(x, y, z)){
						push(x, y, z);
						pushed = true;
					}
					waschecked = true;
					waspushed = pushed;
				} else {
					// The topmost node under a liquid run
					if(!waspushed && ((kind[id] & 2) ||
							(!waschecked && flowable(x, y + 1, z))))
						push(x, y + 1, z);
				}
				wasliquid = isliquid;
				wasignored = isignored;
			}
		}
		return 1;
	}

	// find_nodes(x0, y0, z0, x1, y1, z1, ids) -> positions, ids_at
	//
	// Every voxel of the box whose content id is in the list: the positions
	// flat -- x, y, z, x, y, z -- and the id found at each, in the order
	// Luanti's own find_nodes_in_area() answers in, which is x fastest.
	//
	// The Lua this replaces walked the box a voxel at a time asking a
	// closure about each, and was a quarter of all the Lua VoxeLibre's world
	// generation ran. What is left in Lua is one table per *hit*, which is
	// what the API hands back and cannot be helped.
	static int l_find_nodes(lua_State *L)
	{
		Module *self = module_of(L);
		int32_t x0 = luaL_checkinteger(L, 1);
		int32_t y0 = luaL_checkinteger(L, 2);
		int32_t z0 = luaL_checkinteger(L, 3);
		int32_t x1 = luaL_checkinteger(L, 4);
		int32_t y1 = luaL_checkinteger(L, 5);
		int32_t z1 = luaL_checkinteger(L, 6);
		luaL_checktype(L, 7, LUA_TTABLE);
		lua_newtable(L); // positions
		lua_newtable(L); // ids at each
		if(x1 < x0 || y1 < y0 || z1 < z0 || !box_ok(x0, y0, z0, x1, y1, z1))
			return 2;
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "find_nodes(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MAX_REGION_VOXELS);
		}
		// A Luanti node id is 16 bits, so wanted-or-not is one byte per id
		// and the test in the loop is one load
		sv_<uint8_t> wanted(65536, 0);
		bool any = false;
		const size_t n_ids = lua_objlen(L, 7);
		for(size_t i = 1; i <= n_ids; i++){
			lua_rawgeti(L, 7, (int)i);
			lua_Integer id = lua_tointeger(L, -1);
			lua_pop(L, 1);
			if(id < 0 || id > 65535)
				continue;
			wanted[id] = 1;
			any = true;
		}
		if(!any)
			return 2;
		sv_<uint32_t> words;
		self->read_region(x0, y0, z0, x1, y1, z1, words);
		const interface::VoxelFormat f = interface::VoxelFormat::luanti();
		int n_pos = 0, n_hit = 0;
		size_t i = 0;
		for(int32_t z = z0; z <= z1; z++)
		for(int32_t y = y0; y <= y1; y++)
		for(int32_t x = x0; x <= x1; x++, i++){
			const uint32_t id = f.id.get(words[i]);
			if(!wanted[id])
				continue;
			lua_pushinteger(L, x);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, y);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, z);
			lua_rawseti(L, -3, ++n_pos);
			lua_pushinteger(L, (lua_Integer)id);
			lua_rawseti(L, -2, ++n_hit);
		}
		return 2;
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
		if(x1 < x0 || y1 < y0 || z1 < z0 || !box_ok(x0, y0, z0, x1, y1, z1)){
			lua_newtable(L);
			return 1;
		}
		double volume = (double)(x1 - x0 + 1) * (double)(y1 - y0 + 1) *
				(double)(z1 - z0 + 1);
		if(volume > (double)MAX_REGION_VOXELS){
			// Lua's own formatting, which has no %.0f in it
			return luaL_error(L, "get_region(): %s voxels is more than the "
					"%d this reads at once", cs(itos((int64_t)volume)),
					(int)MAX_REGION_VOXELS);
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

	// The LBMs a world has already had, which Luanti keeps in env_meta.txt as
	// "name~time;name~time;" and uses to decide what runs on a mapblock: an
	// LBM whose introduction time is older than the block does not run on it,
	// which for a world generated by the game that already had the LBM means
	// never. An imported world brings that list with it and this keeps it, so
	// that the module leaves alone what Luanti would leave alone.
	//
	// **What it cost while ignored.** VoxeLibre's
	// mcl_mapgen_core:fix_grass_palette_indexes re-derives every grass
	// block's palette index from the current version's biome code. The
	// reference world was generated five minor versions ago, so sweeping it
	// repainted its grass a different green -- and that was read as a
	// rendering fault for two days. See [GREEN_BIAS] in
	// doc/plan/rendering_plan.md.
	static ss_ lbm_names_of(const ss_ &field)
	{
		ss_ out;
		size_t at = 0;
		while(at < field.size()){
			const size_t end = field.find(';', at);
			const ss_ one = field.substr(at,
					end == ss_::npos ? ss_::npos : end - at);
			const size_t tilde = one.rfind('~');
			if(tilde != ss_::npos && tilde > 0)
				out += one.substr(0, tilde) + ";";
			if(end == ss_::npos)
				break;
			at = end + 1;
		}
		return out;
	}

	// The clock a Luanti world was left at: env_meta.txt, which is lines of
	// "key = value" and then EnvArgsEnd. Three of them are the clock, one is
	// the LBM bookkeeping above, and the rest is the object bookkeeping,
	// which has no meaning here yet.
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
			else if(key == "lbm_introduction_times"){
				const ss_ names = lbm_names_of(value);
				if(m_store)
					m_store->set("lbm_introduced", names);
				publish_lbm_introduced();
				log_v(MODULE, "import_world(): the world has already had "
						"these LBMs: %s", cs(names));
			}
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
	struct Player {
		double pitch = 0.0, yaw = 0.0;
		double x = 0.0, y = 0.0, z = 0.0;
		int hp = 20, breath = 10;
		sm_<ss_, ss_> fields;
		// What Luanti's own player file keeps the metadata in: one JSON
		// object, which the Lua side decodes because that is where the
		// parser is
		ss_ extended_attributes;
		// The list's name, and the item string of each slot in it. The
		// slots are kept by index because a database row says which one
		// it is and an empty slot has no row at all.
		sm_<ss_, sm_<int, ss_>> lists;
		sm_<ss_, int> list_sizes;
	};

	// Luanti keeps a player's position in BS units, which is nodes times
	// ten, and their angles in degrees; a node and a radian is what
	// everything on this side of the import is in.
	static constexpr double DEG_TO_RAD = 3.14159265358979323846 / 180.0;

	void import_players(const ss_ &luanti_world_path)
	{
		sm_<ss_, Player> players;
		read_player_database(luanti_world_path, players);
		// A world written before players.sqlite has a file per player
		// instead. Both are read, and the database wins where a name is in
		// both, which is the order Luanti migrates them in.
		read_player_files(luanti_world_path, players);
		if(players.empty())
			return;
		push_players(players);
	}

	void read_player_database(const ss_ &luanti_world_path,
			sm_<ss_, Player> &players)
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
		query("SELECT name, pitch, yaw, posX, posY, posZ, hp, breath"
				" FROM player", [&](sqlite3_stmt *st){
			Player &p = players[text(st, 0)];
			// Both in degrees in the file and both in the same sense the
			// Lua API uses: the pitch positive downwards, the yaw
			// counter-clockwise from +Z. They become look.v and look.h as
			// they are.
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
	}

	// A world written before players.sqlite: one file per player under
	// players/, holding what the database row holds -- "key = value" lines,
	// a PlayerArgsEnd, and then the inventory in the same shape a node's
	// metadata carries one, which is why mapblock.h's reader is what reads
	// it.
	//
	// A name Luanti could not use as a file name is written with the
	// unusable bytes as _<hex>; the name inside the file is the real one, so
	// that is what is taken and the file name is only how it was found.
	void read_player_files(const ss_ &luanti_world_path,
			sm_<ss_, Player> &players)
	{
		const ss_ dir = luanti_world_path+"/players";
		if(!interface::fs::path_exists(dir))
			return;
		size_t read = 0;
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(n.is_directory || n.name == "." || n.name == "..")
				continue;
			std::ifstream ifs(dir+"/"+n.name, std::ios::binary);
			if(!ifs.good())
				continue;
			std::ostringstream os;
			os<<ifs.rdbuf();
			const ss_ data = os.str();
			luanti_mapblock::Reader r(data);
			Player p;
			ss_ name;
			bool ended = false;
			while(r.p < data.size()){
				const ss_ line = r.line();
				if(line == "PlayerArgsEnd"){
					ended = true;
					break;
				}
				const size_t eq = line.find('=');
				if(eq == ss_::npos)
					continue;
				ss_ key = trimmed(line.substr(0, eq));
				ss_ value = trimmed(line.substr(eq + 1));
				if(key == "name")
					name = value;
				else if(key == "pitch")
					p.pitch = atof(value.c_str()) * DEG_TO_RAD;
				else if(key == "yaw")
					p.yaw = atof(value.c_str()) * DEG_TO_RAD;
				else if(key == "hp")
					p.hp = atoi(value.c_str());
				else if(key == "breath")
					p.breath = atoi(value.c_str());
				else if(key == "extended_attributes")
					p.extended_attributes = value;
				else if(key == "position"){
					// "(x,y,z)" in BS units, which is nodes times ten
					double v[3] = {0.0, 0.0, 0.0};
					sscanf(value.c_str(), "(%lf,%lf,%lf)", &v[0], &v[1],
							&v[2]);
					p.x = v[0] / 10.0;
					p.y = v[1] / 10.0;
					p.z = v[2] / 10.0;
				}
			}
			if(name.empty() || !ended){
				log_w(MODULE, "import_world(): players/%s is not a player "
						"file", cs(n.name));
				continue;
			}
			// The inventory, in the shape a node's metadata carries one
			luanti_mapblock::NodeMeta meta;
			luanti_mapblock::read_inventory(r, meta);
			for(const auto &list : meta.lists){
				p.list_sizes[list.first] = (int)list.second.size();
				for(size_t i = 0; i < list.second.size(); i++){
					if(!list.second[i].empty())
						p.lists[list.first][(int)i + 1] = list.second[i];
				}
			}
			// The database wins: a world that has been migrated has both,
			// and the file is then the older of the two
			if(players.count(name) == 0){
				log_i(MODULE, "import_world(): players/%s: %s at "
						"(%.1f, %.1f, %.1f), hp %i, %zu lists", cs(n.name),
						cs(name), p.x, p.y, p.z, p.hp, p.list_sizes.size());
				players[name] = p;
				read++;
			}
		}
		if(read > 0)
			log_i(MODULE, "import_world(): %zu players out of files", read);
	}

	static ss_ trimmed(const ss_ &s)
	{
		size_t a = s.find_first_not_of(" \t\r\n");
		if(a == ss_::npos)
			return "";
		size_t b = s.find_last_not_of(" \t\r\n");
		return s.substr(a, b - a + 1);
	}

	void push_players(const sm_<ss_, Player> &players)
	{
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
			// A player file keeps the same metadata as one JSON object;
			// core.__import_player() decodes it, the parser being there
			if(!p.extended_attributes.empty()){
				lua_pushlstring(L, p.extended_attributes.c_str(),
						p.extended_attributes.size());
				lua_setfield(L, -2, "extended_attributes");
			}
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

	// The timer on a node that had one, started again where it left off.
	// Luanti keeps a timer with the block; here they are the module's own
	// table and a mod reads them through core.get_node_timer().
	void import_node_timer(int32_t x, int32_t y, int32_t z,
			const luanti_mapblock::NodeTimer &timer)
	{
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.get_node_timer({x=%i, y=%i, z=%i}):set(%f, %f)",
				(int)x, (int)y, (int)z, (double)timer.timeout,
				(double)timer.elapsed);
		try {
			run_chunk_string(buf, "import_node_timer");
		} catch(Exception &e){
			log_w(MODULE, "import_node_timer(): %s", e.what());
		}
	}

	// One of the entities a block was holding. Luanti's static data is a
	// version, the entity's name and the state its on_activate is given;
	// the rest of it -- the hit points, the velocity, which way it faces --
	// is what the entity itself writes into its state when it is worth
	// keeping, so the name and the state are what crosses.
	//
	// Returns whether it was made: a game that does not register the entity
	// the world was holding is the usual reason it is not.
	bool import_static_object(const luanti_mapblock::StaticObject &o,
			ss_ &name_out)
	{
		// 7 is Luanti's LuaEntity. The lower numbers are the engine's own
		// objects from before mods could make one and no world written this
		// decade has any.
		if(o.type != 7)
			return false;
		luanti_mapblock::Reader r(o.data);
		ss_ name, state;
		try {
			r.u8(); // version
			name = r.string16();
			state = r.string32();
		} catch(std::exception &e){
			return false;
		}
		if(name.empty())
			return false;
		name_out = name;
		interface::MutexScope ms(m_lua_mutex);
		lua_State *L = m_lua;
		int base = lua_gettop(L);
		lua_getglobal(L, "core");
		lua_getfield(L, -1, "__import_entity");
		lua_pushnumber(L, o.x);
		lua_pushnumber(L, o.y);
		lua_pushnumber(L, o.z);
		lua_pushlstring(L, name.c_str(), name.size());
		lua_pushlstring(L, state.c_str(), state.size());
		bool made = false;
		if(lua_pcall(L, 5, 1, 0) != 0){
			log_w(MODULE, "__import_entity(): %s",
					lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
		} else {
			made = lua_toboolean(L, -1) != 0;
		}
		lua_settop(L, base);
		return made;
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
	// What comes over is the nodes, what hangs off them, the timer on a node
	// that had one and the entities the blocks were holding.
	//
	// simplified: an imported entity is made where it was and is live from
	// then on. Luanti keeps a block's entities with the block and wakes them
	// when somebody comes near; here they are all in the world at once,
	// which is the same shortcut as an object outside the active range
	// staying in the world and has the same upgrade path.

	void import_world(const ss_ &luanti_world_path)
	{
		if(m_game_running)
			throw Exception("luanti: import_world() after run_game(); the "
					"map is read while the world is made, before a "
					"generator has been asked for any part of it");
		m_import_path = luanti_world_path;
	}

	// The import itself, from inside run_game(): the game's nodes are
	// registered, the world exists, and nothing has asked for a section
	// yet. Both of those bound it -- a name is only a node once the mods
	// have loaded, and a section a generator has already been over is a
	// section this would be writing into behind the generator's back.
	void read_luanti_world(const ss_ &luanti_world_path)
	{
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
		size_t nodes_written = 0, meta_written = 0, timers_written = 0;
		// The sections this world has been written into, which are the ones
		// no generator is to be run over; see below
		set_<uint64_t> marked;
		size_t objects_written = 0, objects_dropped = 0;
		set_<ss_> unknown_names;
		set_<ss_> unknown_entities;
		// What is made once the map is not being held; see the loop
		sv_<std::pair<pv::Vector3DInt32, luanti_mapblock::NodeTimer>>
				pending_timers;
		sv_<luanti_mapblock::StaticObject> pending_objects;
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
				// A section this world reaches into is a section that has
				// been generated, by the engine that generated it. Without
				// that mark this one's own generator runs over it later --
				// a section is its generator's to write, so the volume
				// that arrives puts a fresh world where the read one was.
				// A section the import only partly covers keeps the rest
				// of itself undefined, which is what a Luanti world says
				// about a block it does not hold.
				//
				// simplified: the mark is per section and the map is per
				// block, so 64 blocks of a section share one answer. Where
				// the imported world ends mid-section, the rest of that
				// section is not generated either. Per-block would mean
				// generating the section and writing the blocks over it
				// afterwards, which is the source kept open until every
				// section it touches has been generated.
				const pv::Vector3DInt16 sp = section_of(
						pv::Vector3DInt32(x0, y0, z0));
				if(marked.insert(section_key(sp)).second)
					world->set_section_generated(sp);
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
				// The timers and the entities are kept for afterwards
				// rather than made here: an entity's own on_activate is a
				// mod's code and reads the map, and the map is what this
				// loop is holding. A mod that asks voxelworld for a node
				// from inside a voxelworld access waits for the access it
				// is already inside, which is a server that stops.
				for(const auto &pair : block.timers){
					int32_t tx = bx + (pair.first & 15);
					int32_t ty = by + ((pair.first >> 4) & 15);
					int32_t tz = bz + ((pair.first >> 8) & 15);
					if(tx < x0 || tx > x1 || ty < y0 || ty > y1 ||
							tz < z0 || tz > z1)
						continue;
					pending_timers.push_back(std::make_pair(
							pv::Vector3DInt32(tx, ty, tz), pair.second));
				}
				for(const luanti_mapblock::StaticObject &o : block.objects){
					if(o.x < (float)x0 || o.x > (float)x1 + 1.0f ||
							o.y < (float)y0 || o.y > (float)y1 + 1.0f ||
							o.z < (float)z0 || o.z > (float)z1 + 1.0f)
						continue;
					pending_objects.push_back(o);
				}
				blocks_read++;
			}
		});
		sqlite3_finalize(st);
		sqlite3_close(db);
		// The timers and the entities, now that the map is free: a timer
		// starts again where it left off and an entity is placed where it
		// was, and both of those are a mod's own code
		for(const auto &pair : pending_timers){
			import_node_timer(pair.first.getX(), pair.first.getY(),
					pair.first.getZ(), pair.second);
			timers_written++;
		}
		for(const luanti_mapblock::StaticObject &o : pending_objects){
			ss_ name;
			if(import_static_object(o, name)){
				objects_written++;
			} else {
				objects_dropped++;
				if(!name.empty())
					unknown_entities.insert(name);
			}
		}
		// What it read metadata for is mostly sections nothing has loaded,
		// and those are written out rather than waiting for an unload that
		// will not come
		if(meta_written != 0)
			write_all_node_meta();
		log_i(MODULE, "import_world(): %zu blocks of %s read into the world, "
				"%zu nodes and %zu of them with metadata; %zu blocks outside "
				"it, %zu it could not read; %zu sections it will not "
				"generate",
				blocks_read, cs(luanti_world_path), nodes_written,
				meta_written, blocks_outside, blocks_failed, marked.size());
		if(timers_written != 0 || objects_written != 0 || objects_dropped != 0)
			log_i(MODULE, "import_world(): %zu node timers and %zu entities, "
					"and %zu it could not make",
					timers_written, objects_written, objects_dropped);
		if(!unknown_entities.empty()){
			ss_ list;
			size_t n = 0;
			for(const ss_ &name : unknown_entities){
				if(n++ >= 10){
					list += ", and "+itos(unknown_entities.size() - 10)+
							" more";
					break;
				}
				if(!list.empty())
					list += ", ";
				list += name;
			}
			log_w(MODULE, "import_world(): the world was holding entities "
					"this game does not register: %s", cs(list));
		}
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

	// map_meta.txt: what a Luanti world is made out of -- its seed, which
	// mapgen made it and what that mapgen was told. Before run_game(),
	// because the world is made when the game starts: a mapgen told
	// afterwards has already generated the ground the player stands on.
	//
	// What the save already says is kept, so a world that has been played
	// here keeps its own terrain whatever it is imported over.
	void import_world_settings(const ss_ &luanti_world_path,
			storage::Save *save)
	{
		if(m_game_running)
			throw Exception("luanti: import_world_settings() after "
					"run_game(); the world is already made out of them");
		if(!save)
			throw Exception("luanti: import_world_settings() without a save");
		storage::Store *store = save->store("luanti");
		if(!store)
			return;
		std::ifstream ifs(luanti_world_path+"/map_meta.txt");
		if(!ifs.good())
			return;
		// The names on this side, for the four of Luanti's that mean
		// something to this module's mapgen
		static const sm_<ss_, ss_> WANTED = {
			{"seed", "seed"},
			{"mg_name", "mg_name"},
			{"water_level", "water_level"},
			{"mg_flags", "mg_flags"},
		};
		ss_ taken;
		ss_ line;
		while(std::getline(ifs, line)){
			size_t eq = line.find('=');
			if(eq == ss_::npos)
				continue;
			ss_ key = line.substr(0, eq);
			while(!key.empty() && (key.back() == ' ' || key.back() == '\t'))
				key.pop_back();
			auto it = WANTED.find(key);
			if(it == WANTED.end())
				continue;
			ss_ value = line.substr(eq + 1);
			size_t begin = value.find_first_not_of(" \t");
			if(begin == ss_::npos)
				continue;
			value = value.substr(begin);
			while(!value.empty() && (value.back() == ' ' ||
					value.back() == '\t' || value.back() == '\r'))
				value.pop_back();
			ss_ have;
			if(store->get(it->second, have) && !have.empty())
				continue; // The save's own, and it was here first
			store->set(it->second, value);
			if(!taken.empty())
				taken += ", ";
			taken += it->second+"="+value;
		}
		if(!taken.empty())
			log_i(MODULE, "The imported world is made with %s", cs(taken));
	}

	void set_progress_handler(std::function<void(const ss_ &)> handler)
	{
		m_progress = handler;
	}

	void progress(const ss_ &line)
	{
		// And the log's status line, which the client's waiting screen
		// and a shell start read ([START_PROGRESS])
		log_i(MODULE, "STATUS %s", cs(line));
		if(m_progress)
			m_progress(line);
	}

	// __luanti_progress(text): the mod loader saying which mod it is on
	static int l_progress(lua_State *L)
	{
		Module *self = module_of(L);
		size_t len = 0;
		const char *p = luaL_checklstring(L, 1, &len);
		self->progress(ss_(p ? p : "", len));
		return 0;
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
		progress("Loading "+game_path.substr(game_path.find_last_of('/') + 1));

		m_lua = luaL_newstate();
		if(!m_lua)
			throw Exception("luanti: cannot create a Lua state");
		luaL_openlibs(m_lua);
		{
			// The Lua sampling profiler, if this run asked for one
			const char *env = getenv("BUILDAT_LUANTI_LUAPROF");
			// The hook is on either way: without the profiler it is only
			// the step watchdog, at an interval coarse enough to cost
			// nothing measurable.
			if(env == nullptr || env[0] == '\0'){
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT, 1000000);
			}
			if(env != nullptr && env[0] != '\0'){
				const int n = atoi(env);
				g_lua_prof.interval = n > 0 ? n : 10000;
				g_lua_prof.enabled = true;
				lua_sethook(m_lua, lua_prof_hook, LUA_MASKCOUNT,
						g_lua_prof.interval);
				log_i(MODULE, "Lua profile: sampling every %i instructions; "
						"the report comes at shutdown",
						g_lua_prof.interval);
			}
		}
		// bit.band and its family, before any mod can ask for them
		lua_pushcfunction(m_lua, luaopen_bit);
		lua_pushstring(m_lua, "bit");
		lua_call(m_lua, 1, 0);

		set_global_cfunction("__luanti_log", l_log);
		set_global_cfunction("__luanti_accounts", l_accounts);
		set_global_cfunction("__luanti_get_us_time", l_get_us_time);
		set_global_cfunction("__luanti_list_dir", l_list_dir);
		set_global_cfunction("__luanti_path_exists", l_path_exists);
		set_global_cfunction("__luanti_create_directories", l_create_directories);
		set_global_cfunction("__luanti_encode_png", l_encode_png);
		set_global_cfunction("__luanti_sha1", l_sha1);
		set_global_cfunction("__luanti_sha256", l_sha256);
		set_global_cfunction("__luanti_compress", l_compress);
		set_global_cfunction("__luanti_decompress", l_decompress);
		set_global_cfunction("__luanti_refshot_mark", l_refshot_mark);
		set_global_cfunction("__luanti_set_node", l_set_node);
		set_global_cfunction("__luanti_get_node", l_get_node);
		set_global_cfunction("__luanti_region_to_world", l_region_to_world);
		set_global_cfunction("__luanti_get_region", l_get_region);
		set_global_cfunction("__luanti_get_region_data", l_get_region_data);
		set_global_cfunction("__luanti_set_region_data", l_set_region_data);
		set_global_cfunction("__luanti_noise_value", l_noise_value);
		set_global_cfunction("__luanti_noise_map", l_noise_map);
		set_global_cfunction("__luanti_bounded_pcall", l_bounded_pcall);
		set_global_cfunction("__luanti_forceload", l_forceload);
		set_global_cfunction("__luanti_active_boxes", l_active_boxes);
		set_global_cfunction("__luanti_loaded_boxes", l_loaded_boxes);
		set_global_cfunction("__luanti_find_ids", l_find_ids);
		set_global_cfunction("__luanti_liquid_edges", l_liquid_edges);
		set_global_cfunction("__luanti_find_nodes", l_find_nodes);
		set_global_cfunction("__luanti_ids_at", l_ids_at);
		// The world is not made yet and a mod that asks how big a chunk is
		// asks while it loads -- minetest_game does -- so this carries the
		// default until create_world() knows the real one. Without it the
		// read is of a global that does not exist, which the module's own
		// strict-global guard warns about, once, for nothing.
		set_global_string("__luanti_section_size", "64");
		set_global_cfunction("__luanti_show_objects", l_show_objects);
		set_global_cfunction("__luanti_show_object_props",
				l_show_object_props);
		set_global_cfunction("__luanti_send_inventory", l_send_inventory);
		set_global_cfunction("__luanti_send_player_pos", l_send_player_pos);
		set_global_cfunction("__luanti_spawn_level", l_spawn_level);
		set_global_cfunction("__luanti_biome_at", l_biome_at);
		set_global_cfunction("__luanti_relight", l_relight);
		set_global_cfunction("__luanti_send_chat", l_send_chat);
		set_global_cfunction("__luanti_send_hud", l_send_hud);
		set_global_cfunction("__luanti_send_physics", l_send_physics);
		set_global_cfunction("__luanti_send_privs", l_send_privs);
		set_global_cfunction("__luanti_send_camera", l_send_camera);
		set_global_cfunction("__luanti_send_modes", l_send_modes);
		set_global_cfunction("__luanti_send_day_night", l_send_day_night);
		set_global_cfunction("__luanti_send_sound", l_send_sound);
		set_global_cfunction("__luanti_sound_file", l_sound_file);
		set_global_cfunction("__luanti_sound_files", l_sound_files);
		set_global_cfunction("__luanti_add_media", l_add_media);
		set_global_cfunction("__luanti_lua_profile", l_lua_profile);
		set_global_cfunction("__luanti_copy_ints", l_copy_ints);
		set_global_cfunction("__luanti_nest_2d", l_nest_2d);
		set_global_cfunction("__luanti_nest_3d", l_nest_3d);
		set_global_cfunction("__luanti_send_particles", l_send_particles);
		set_global_cfunction("__luanti_send_sky", l_send_sky);
		set_global_cfunction("__luanti_send_time", l_send_time);
		set_global_cfunction("__luanti_show_formspec", l_show_formspec);
		set_global_cfunction("__luanti_request_shutdown", l_request_shutdown);
		set_global_cfunction("__luanti_player_formspec", l_player_formspec);
		set_global_cfunction("__luanti_send_node_inventory",
				l_send_node_inventory);
		set_global_cfunction("__luanti_progress", l_progress);
		set_global_cfunction("__luanti_step_peak", l_step_peak);
		set_global_cfunction("__luanti_flush_node_writes",
				l_flush_node_writes);
		set_global_cfunction("__luanti_loaded_at", l_loaded_at);
		set_global_cfunction("__luanti_section_state", l_section_state);
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
		// And what this tree adds to what the builtin registered: after it,
		// because it changes commands the builtin has already put there
		run_chunk_file(module_path()+"/lua/chatcommands.lua");
		for(const auto &pair : m_pending_lua)
			run_chunk_string(pair.first, pair.second);
		m_pending_lua.clear();
		// Before the mods load, because a mod can ask the time while it
		// does, and after the builtin, because that is where the clock is
		load_clock();
		load_seed();
		// Which mapgen this world is, before the mods load, because a mod
		// reads it while it loads -- VoxeLibre registers no biomes at all
		// for a singlenode world. The save's own answer, which for an
		// imported world is its map_meta.txt's and is in no setting here.
		set_global_string("__luanti_mapgen_name", mapgen_name());
		// And which LBMs this world has already had; see lbm_names_of()
		publish_lbm_introduced();

		run_chunk_file(module_path()+"/lua/modloader.lua");

		// After the mods, because what the metadata holds is item strings
		// and a mod's items have to be registered for one to mean anything.
		// The node metadata is not read here any more: it comes back with
		// the section it is in, and migrate_node_meta() below is what an
		// older save's one blob of it becomes.
		load_players();
		run_chunk_string("core.__check_players() "
				"core.__check_inventory_move() "
				"core.__check_bone_hand() "
				"core.__check_craft_index()", "check_players");

		check_shapes();
		check_mapblock();
		check_media_names();

		// The game's own media before the registry, because what a node's
		// tiles can be depends on which files were actually shipped
		progress("Serving the media");
		serve_game_media(game_path);

		// The registry, the world and the light, in that order: the ids the
		// mods asked for while loading are the ids the definitions are built
		// under, and the definitions have to exist before anything is lit.
		progress("Building the world");
		create_world();

		m_game_running = true;

		// The map of another engine's world, if this world is being made
		// out of one: after the nodes and the world, and before anything
		// has asked a generator for a section. The streamer was told to
		// take on nothing while this runs, because a section it generated
		// underneath the import would be one the import cannot have.
		if(!m_import_path.empty()){
			progress("Importing the world");
			read_luanti_world(m_import_path);
			m_import_path.clear();
			// What create_world() left to this: the sections around the
			// origin, so that whatever the imported world did not reach
			// still has ground under it
			generate_world();
			m_stream_budget = 2;
			update_load_points();
		}

		start_check_map();

		// Last, so that it is the hour whatever the save or the imported
		// world said
		force_clock();

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

	void set_admin(const ss_ &name, bool admin)
	{
		node_action("core.__set_admin(\""+lua_quoted(name)+"\", "+
				(admin ? "true" : "false")+") return true");
	}

	void chat_send(const ss_ &to, const ss_ &text)
	{
		if(to.empty())
			node_action("core.chat_send_all(\""+lua_quoted(text)+
					"\") return true");
		else
			node_action("core.chat_send_player(\""+lua_quoted(to)+"\", \""+
					lua_quoted(text)+"\") return true");
	}

	void remove_player(const ss_ &name)
	{
		node_action("core.__remove_player(\""+lua_quoted(name)+
				"\") return true");
		auto it = m_player_peers.find(name);
		if(it != m_player_peers.end()){
			m_peer_players.erase(it->second);
			m_peer_mode.erase(it->second);
			m_player_peers.erase(it);
		}
		// The world stops being kept loaded around where they were
		m_player_pos.erase(name);
	}

	void set_player_pos(const ss_ &name, float x, float y, float z,
			float look_h, float look_v, int32_t controls)
	{
		// Off the network: a NaN or a 1e30 was undefined in the cast below
		// and "nan" or a cut-off chunk in the Lua one ([SECURITY_RUN_1]).
		// Luanti's world ends at 31007; past 32000 is no position.
		for(float v : {x, y, z, look_h, look_v}){
			if(!std::isfinite(v))
				return;
		}
		if(std::fabs(x) > 32000 || std::fabs(y) > 32000 ||
				std::fabs(z) > 32000 || std::fabs(look_h) > 1e6 ||
				std::fabs(look_v) > 1e6)
			return;
		// What the world streams around and what is active near; the step
		// reads it, so this only writes it down
		m_player_pos[name] = pv::Vector3DInt32(
				(int32_t)std::floor(x), (int32_t)std::floor(y),
				(int32_t)std::floor(z));
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__set_player_pos(\"%s\", %f, %f, %f, %f, %f, %d) "
				"return true",
				lua_quoted(name).c_str(), (double)x, (double)y, (double)z,
				(double)look_h, (double)look_v, (int)controls);
		node_action(buf);
	}

	void player_fell(const ss_ &name, float speed)
	{
		if(!std::isfinite(speed) || std::fabs(speed) > 1e6)
			return;
		char buf[256];
		snprintf(buf, sizeof buf,
				"core.__player_fell(\"%s\", %f) return true",
				lua_quoted(name).c_str(), (double)speed);
		node_action(buf);
	}

	bool drop_wielded(const ss_ &player_name, int count)
	{
		if(player_name.empty())
			return false;
		return node_action("return core.__drop_wielded(\""+
				lua_quoted(player_name)+"\", "+itos(count)+")");
	}

	bool punch_object(int32_t id, const ss_ &player_name)
	{
		if(player_name.empty())
			return false;
		return node_action("return core.__punch_object(\""+
				lua_quoted(player_name)+"\", "+itos(id)+")");
	}

	void set_wield_index(const ss_ &player_name, int index)
	{
		node_action("core.__set_wield_index(\""+lua_quoted(player_name)+
				"\", "+itos(index)+") return true");
	}

	// A line a player typed, handed to the callbacks the way Luanti's own
	// server hands one over. The "/" commands are among those callbacks,
	// registered by the vendored builtin.
	void chat_message(const ss_ &player_name, const ss_ &message)
	{
		// Luanti's own limit on a chat line, and the reason for one here is
		// that this comes off the network
		static const size_t MAX_CHAT = 500;
		ss_ line = message.size() > MAX_CHAT ?
				message.substr(0, MAX_CHAT) : message;
		node_action("core.__chat_message(\""+lua_quoted(player_name)+
				"\", \""+lua_quoted(line)+"\") return true");
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

	bool punch_node(int32_t x, int32_t y, int32_t z, const ss_ &player_name)
	{
		ss_ puncher = player_name.empty() ? ss_("nil") :
				"core.get_player_by_name(\""+lua_quoted(player_name)+"\")";
		return node_action("return core.__punch_node({x = "+itos(x)+
				", y = "+itos(y)+", z = "+itos(z)+"}, "+puncher+")");
	}

	bool place_node(int32_t ux, int32_t uy, int32_t uz,
			int32_t ax, int32_t ay, int32_t az, const ss_ &player_name,
			bool sneak)
	{
		if(player_name.empty())
			return false;
		return node_action("return core.__use_node(\""+
				lua_quoted(player_name)+"\", "
				"{x = "+itos(ux)+", y = "+itos(uy)+", z = "+itos(uz)+"}, "
				"{x = "+itos(ax)+", y = "+itos(ay)+", z = "+itos(az)+"}, "+
				(sneak ? "true" : "false")+")");
	}

	sv_<ss_> call_string_list(const ss_ &name)
	{
		return string_list_from_lua(name.c_str());
	}

	bool m_server_physics = false;
	void set_server_physics(bool on)
	{
		m_server_physics = on;
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
