// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// A Luanti game's own Lua -- its builtin layer and a game's mods -- running
// inside buildat_server. Luanti's network protocol is nowhere in this; the
// game logic is Luanti's and everything around it is buildat's. See
// doc/luanti_module.txt and local/luanti_module_plan.md.
//
// This file is deliberately thin. Lua 5.1 comes with io and os, so reading
// files, splitting paths and running chunks all happen in Lua; the only
// things C++ has that Lua does not are a directory listing, the log and the
// clock. The arrangement -- what a mod is, what order mods load in, what the
// core table holds -- is in lua/ beside this file, where it can be read.
#include "luanti/api.h"
#include "voxelworld/api.h"
#include "main_context/api.h"
#include "client_file/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/voxel.h"
#include <fstream>
#include <sstream>
#include <unordered_map>
extern "C" {
#include <Lua/lua.h>
#include <Lua/lualib.h>
#include <Lua/lauxlib.h>
}
// Luanti's core.encode_png() is a real function of its API and devtest checks
// what comes out of it, so it is written rather than stubbed. Urho3D ships
// stb_image_write but does not export it, so it is compiled in here; it is
// one header and the only C++ in this file that is not glue.
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
	// Away from the dark end and away from grey: a palette of flat colours
	// reads as different blocks, a palette of muds does not
	rgb[0] = 80 + (h & 0x7f);
	rgb[1] = 80 + ((h >> 8) & 0x7f);
	rgb[2] = 80 + ((h >> 16) & 0x7f);
}

static ss_ node_texture_name(const ss_ &name)
{
	uint32_t h = 2166136261u;
	for(char c : name){
		h ^= (uint8_t)c;
		h *= 16777619u;
	}
	char buf[32];
	snprintf(buf, sizeof buf, "luanti/node_%08x.png", (unsigned)h);
	return buf;
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
	bool m_game_running = false;
	// What load_lua() was handed before run_game(), in the order it came
	sv_<std::pair<ss_, ss_>> m_pending_lua;

	// The map. One voxelworld instance, in a scene of this module's own: the
	// module is what knows the Luanti world's shape, its node ids and its
	// light, so it is what owns them. The launcher is told about the scene by
	// luanti:game_loaded.
	SceneReference m_scene = nullptr;

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
		m_server->sub_event(this, Event::t("core:continue"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:unload", on_unload)
		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
	}

	void on_start(){}
	void on_unload(){}
	void on_continue(){}

	void on_tick(const interface::TickEvent &event)
	{
		if(!m_game_running)
			return;
		m_step_accum += event.dtime;
		if(m_step_accum < STEP_S)
			return;
		m_step_accum = 0.0f;
		flush_node_writes();
	}

	// The map

	// Floor division, because a section boundary is not at zero and C's
	// division rounds towards it
	static int32_t floordiv(int32_t a, int32_t b)
	{
		return (a >= 0) ? (a / b) : -((-a + b - 1) / b);
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

	// simplified: a read that misses the buffer takes one voxelworld
	// access(), which commits on the way out. commit() is cheap with nothing
	// dirty, but it is not free, and a mod that reads a region a voxel at a
	// time pays it per voxel. The upgrade path is the region read
	// find_nodes_in_area wants anyway.
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
		// the only nodes in it are the ones a mod places. The region is what
		// a mod can reach; a Luanti-sized map is M6's problem, together with
		// the mapgen that would fill it.
		voxelworld::access(m_server, [&](voxelworld::Interface *iv){
			pv::Region region(-1, -1, -1, 1, 1, 1);
			iv->create_instance(m_scene, region);
		});

		voxelworld::access(m_server, m_scene, [&](voxelworld::Instance *world){
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			// Luanti's cut of the voxel word: a 16-bit node id, param1 as
			// two light nibbles, param2 above them. Nothing is packed by
			// hand anywhere in this module because of this line.
			reg->set_format(interface::VoxelFormat::luanti());
			build_voxel_registry(reg);
			// The light is voxelworld's, so core.get_node_light is a read
			// and not a second store
			world->set_skylight_enabled(true);
		});
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
	void build_voxel_registry(interface::VoxelRegistry *reg)
	{
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
		for(size_t i = 1; i <= n; i++){
			lua_rawgeti(L, -1, (int)i);
			if(!lua_istable(L, -1)){
				lua_pop(L, 1);
				continue;
			}
			ss_ name = table_string(L, "name");
			bool transparent = table_boolean(L, "transparent");
			bool empty = table_boolean(L, "empty");
			bool walkable = table_boolean(L, "walkable");
			lua_pop(L, 1);

			ss_ texture = empty ? "" : node_texture_name(name);
			if(!texture.empty())
				textures.push_back(name);

			interface::VoxelDefinition vdef;
			vdef.name.block_name = name;
			vdef.name.segment_x = 0;
			vdef.name.segment_y = 0;
			vdef.name.segment_z = 0;
			vdef.name.rotation_primary = 0;
			vdef.name.rotation_secondary = 0;
			vdef.handler_module = "";
			for(size_t f = 0; f < 6; f++){
				interface::AtlasSegmentDefinition &seg = vdef.textures[f];
				seg.resource_name = texture;
				seg.total_segments = magic::IntVector2(
						texture.empty() ? 0 : 1, texture.empty() ? 0 : 1);
				seg.select_segment = magic::IntVector2(0, 0);
				seg.roughness = 0.95f;
				seg.spec_strength = 0.15f;
				seg.bumpiness = 0.0f;
			}
			// EDGEMATERIALID_EMPTY is one test doing two jobs in buildat: a
			// face is drawn against it and light passes through it. Luanti
			// splits them; this is the half that is safe until the drawtypes
			// arrive with M3.
			vdef.edge_material_id = transparent ?
					interface::EDGEMATERIALID_EMPTY :
					interface::EDGEMATERIALID_GROUND;
			vdef.physically_solid = walkable && !empty;
			vdef.fully_empty = empty;
			reg->add_voxel(vdef);
		}
		lua_settop(L, base);

		serve_node_textures(textures);
		log_i(MODULE, "%zu node types in the voxel registry", n);
	}

	// One flat PNG per node, generated and handed to client_file rather than
	// written to disk: there is no file behind these and there should not be
	// one. M3 replaces them with the game's own media.
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

	// Interface

	void run_game(const ss_ &game_path, const ss_ &world_path)
	{
		if(m_game_running)
			throw Exception("luanti: run_game() called twice");
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
		set_global_cfunction("__luanti_set_node", l_set_node);
		set_global_cfunction("__luanti_get_node", l_get_node);
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
		run_chunk_file(module_path()+"/lua/modloader.lua");

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
