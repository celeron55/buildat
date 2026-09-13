-- Buildat: builtin/luanti/lua/bootstrap.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What Luanti's vendored builtin expects to find already registered when it
-- starts: in Luanti this is the C API, and here it is this file plus the four
-- C functions luanti.cpp sets as globals. Lua 5.1 brings io and os, so
-- anything that is a file or a string is done here rather than in C++.
--
-- What is not here is a stub that logs once and returns nothing, so a mod
-- calling it does not take the server down. The list at the bottom is the
-- work queue: a name leaves it when it is written for real.

core = {}
minetest = core

INIT = "game"
DIR_DELIM = "/"

local module_path = __luanti_module_path
local cache_path = __luanti_cache_path
local game_path = __luanti_game_path
local world_path = __luanti_world_path

--
-- Logging, time, and the filesystem
--

function core.log(level, text)
	if text == nil then
		level, text = "action", level
	end
	__luanti_log(tostring(level), tostring(text))
end

core.get_us_time = __luanti_get_us_time

-- {name, is_directory} for everything in a directory; an empty list for one
-- that is not there
core.get_dir_list = function(path, list_dirs)
	local out = {}
	for _, node in ipairs(__luanti_list_dir(path)) do
		if list_dirs == nil or list_dirs == node.is_directory then
			out[#out + 1] = node.name
		end
	end
	return out
end

core.mkdir = __luanti_create_directories

function core.safe_file_write(path, content)
	local f = io.open(path, "wb")
	if not f then
		return false
	end
	f:write(content)
	f:close()
	return true
end

-- Not Luanti's; used by this file and modloader.lua
local function read_file(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data = f:read("*a")
	f:close()
	return data
end
core.__read_file = read_file

--
-- Paths
--

function core.get_builtin_path()
	return module_path .. "/vendor/builtin/"
end

function core.get_mainmenu_path()
	return module_path .. "/vendor/builtin/mainmenu"
end

function core.get_worldpath()
	return world_path
end

function core.get_gamepath()
	return game_path
end

function core.get_cache_path()
	return cache_path
end

function core.get_temp_path(dir)
	local path = cache_path .. "/tmp"
	core.mkdir(path)
	return path
end

--
-- Settings
--
-- A key=value file the way Luanti writes them, with everything unknown
-- answered from DEFAULTS below. Luanti's settings object is a userdata with
-- a dozen methods; this is the same shape in a table.
--

local DEFAULTS = {
	["mg_name"] = "singlenode",
	["water_level"] = "1",
	["mapgen_limit"] = "31000",
	["chunksize"] = "5",
	["map_generation_limit"] = "31000",
	["time_speed"] = "72",
	["creative_mode"] = "false",
	["enable_damage"] = "true",
	["profiler.load"] = "false",
	["max_block_generate_distance"] = "10",
	["language"] = "",
	["debug_log_level"] = "action",
	["secure.enable_security"] = "false",
}

local function parse_conf(text)
	local out = {}
	if not text then
		return out
	end
	for line in text:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([^#=][^=]-)%s*=%s*(.-)%s*$")
		if key then
			out[key] = value
		end
	end
	return out
end

local settings_values = parse_conf(read_file(world_path .. "/world.mt"))

local Settings = {}
Settings.__index = Settings

function Settings:get(key)
	local v = settings_values[key]
	if v == nil then
		v = DEFAULTS[key]
	end
	return v
end

function Settings:get_bool(key, default)
	local v = self:get(key)
	if v == nil or v == "" then
		return default
	end
	return v == "true"
end

function Settings:get_int(key, default)
	return tonumber(self:get(key)) or default
end

function Settings:get_float(key, default)
	return tonumber(self:get(key)) or default
end

function Settings:get_pos(key)
	return nil
end

function Settings:get_np_group(key)
	return nil
end

function Settings:get_flags(key)
	return {}
end

function Settings:set(key, value)
	settings_values[key] = tostring(value)
end

Settings.set_bool = Settings.set

function Settings:remove(key)
	settings_values[key] = nil
	return true
end

function Settings:get_names()
	local out = {}
	for k, _ in pairs(settings_values) do
		out[#out + 1] = k
	end
	return out
end

function Settings:has(key)
	return self:get(key) ~= nil
end

function Settings:write()
	local lines = {}
	for k, v in pairs(settings_values) do
		lines[#lines + 1] = k .. " = " .. v
	end
	return core.safe_file_write(world_path .. "/world.mt",
			table.concat(lines, "\n") .. "\n")
end

function Settings:to_table()
	local out = {}
	for k, v in pairs(settings_values) do
		out[k] = v
	end
	return out
end

core.settings = setmetatable({}, Settings)

function core.setting_get_pos(key)
	return nil
end

--
-- The item and node registry
--
-- Luanti's C++ keeps two managers and hands out content ids. Here the
-- definitions themselves live in the Lua tables the vendored builtin already
-- keeps; what this has to add is the id, because a content id is what the
-- world is made of.
--

core.__content_ids = {}      -- name -> id
core.__content_names = {}    -- id -> name
core.__aliases = {}          -- name -> name
local next_content_id = 0

local function reserve_content_id(name, id)
	if id == nil then
		id = next_content_id
		next_content_id = next_content_id + 1
	end
	core.__content_ids[name] = id
	core.__content_names[id] = name
end

-- A content id here is a buildat VoxelRegistry id, not a number copied from
-- Luanti: the ids are allocated by whichever engine is running the game, and
-- here this module is that engine. devtest's own content_ids.lua only ever
-- asserts relations between them, never a literal.
--
-- So the three constants land where the registry already puts them:
-- VOXELTYPEID_UNDEFINED is 0 and means "nothing has generated this yet",
-- which is exactly ignore; add_voxel() then hands out 1, 2, 3... in the order
-- the definitions are built, which is content id order.
core.CONTENT_IGNORE = 0
core.CONTENT_UNKNOWN = 1
core.CONTENT_AIR = 2
reserve_content_id("ignore", core.CONTENT_IGNORE)
reserve_content_id("unknown", core.CONTENT_UNKNOWN)
reserve_content_id("air", core.CONTENT_AIR)
next_content_id = 3

function core.register_item_raw(def)
	local name = def.name
	if name == nil or name == "" then
		return
	end
	-- Only a node takes a content id; a craftitem or a tool is never in the
	-- world by itself
	if def.type == "node" and core.__content_ids[name] == nil then
		reserve_content_id(name)
	end
	return name
end

function core.unregister_item_raw(name)
	-- The id stays taken: a world already written in it does not stop
	-- meaning what it meant
	core.__aliases[name] = nil
end

function core.register_alias_raw(name, convert_to)
	core.__aliases[name] = convert_to
end

function core.get_content_id(name)
	if type(name) ~= "string" then
		error("get_content_id(): not a name: " .. tostring(name))
	end
	name = core.__aliases[name] or name
	local id = core.__content_ids[name]
	if id == nil then
		error("Unknown node: " .. tostring(name))
	end
	return id
end

-- What the importer asks for every name a Luanti world's blocks carry: the
-- id this run gave that node, through whatever alias the game registered,
-- and whether the game knows it at all. A name it does not know comes back
-- as "unknown", which is Luanti's own answer and is a node you can see and
-- dig rather than a hole in the world.
function core.__content_id_or_unknown(name)
	name = core.__aliases[name] or name
	local id = core.__content_ids[name]
	if id ~= nil then
		return id, true
	end
	return core.__content_ids["unknown"] or 0, false
end

function core.get_name_from_content_id(id)
	if type(id) ~= "number" then
		error("get_name_from_content_id(): not a content id: " .. tostring(id))
	end
	return core.__content_names[id] or "unknown"
end

-- Every node that has an id, from 1 upwards, flattened to what the module's
-- C++ needs to build a VoxelDefinition. Called once, after the mods have
-- loaded: add_voxel() takes a finished definition and hands out ids in call
-- order, so the definitions have to be built in one pass in id order, and
-- doing it at the end is also what makes core.override_item and
-- core.unregister_item non-issues -- only the final registered_nodes is ever
-- looked at.
--
-- Id 0 is ignore, which is VOXELTYPEID_UNDEFINED and has no definition.
-- Luanti's tiles are +Y, -Y, +X, -X, +Z, -Z and buildat's six textures are
-- the same six in the same order, so they map one to one. Fewer than six
-- copies the last one over the rest, which is what Luanti does.
--
-- What comes out is the tile *string*, texture modifiers and all: the server
-- decides which voxel types exist and the client decides what their pixels
-- are. See doc/plan/luanti_module_plan.md, "Who resolves textures".
local function tile_name_of(t)
	if type(t) == "table" then
		t = t.name or t.image
	end
	if type(t) == "string" then
		return t
	end
	return nil
end

local function tile_names(def)
	local tiles = def and (def.tiles or def.tile_images)
	if type(tiles) ~= "table" then
		return nil
	end
	local out = {}
	local last = nil
	for i = 1, 6 do
		local t = tile_name_of(tiles[i]) or last
		if t == nil then
			return nil
		end
		out[i] = t
		last = t
	end
	return out
end

-- A liquid wears its special_tiles and not its tiles: the first is the
-- surface and the second the sides, and `tiles` is what the item looks like
-- in a hand. Same six faces in the same order as everything else.
local function liquid_tiles(def)
	local st = def and def.special_tiles
	if type(st) ~= "table" then
		return nil
	end
	local top = tile_name_of(st[1])
	if top == nil then
		return nil
	end
	local side = tile_name_of(st[2]) or top
	return {top, top, side, side, side, side}
end

-- A nodebox's boxes, flattened to six numbers each, in Luanti's own
-- -0.5...0.5 voxel coordinates -- which are buildat's own, so they travel as
-- they were written.
--
-- Only "fixed". The connected, wallmounted and leveled kinds want neighbours
-- or a param, and the shape a neighbour decides is the mesher's connect_dir
-- and the shape a param decides is a VoxelVariant; neither is a list of
-- boxes the server can hand over on its own.
-- Which way a node's param2 says it faces. The colour* kinds put a palette
-- index in the high bits and the direction in the same low ones, so they are
-- the same thing as far as this is concerned.
local FACING_OF_PARAMTYPE2 = {
	facedir = "facedir", colorfacedir = "facedir",
	["4dir"] = "4dir", color4dir = "4dir",
	wallmounted = "wallmounted", colorwallmounted = "wallmounted",
}

local function node_boxes(def)
	local nb = def and def.node_box
	if type(nb) ~= "table" or nb.type ~= "fixed" then
		return nil
	end
	local fixed = nb.fixed
	if type(fixed) ~= "table" then
		return nil
	end
	-- One box is six numbers; several is a list of those
	if type(fixed[1]) == "number" then
		fixed = {fixed}
	end
	local out = {}
	for _, box in ipairs(fixed) do
		if type(box) == "table" and #box >= 6 then
			for i = 1, 6 do
				if type(box[i]) ~= "number" then
					return nil
				end
				out[#out + 1] = box[i]
			end
		end
	end
	if #out == 0 then
		return nil
	end
	return out
end

function core.__voxel_defs()
	local max_id = 0
	for id in pairs(core.__content_names) do
		if id > max_id then
			max_id = id
		end
	end
	local out = {}
	for id = 1, max_id do
		local name = core.__content_names[id]
		local def = name and core.registered_nodes[name] or nil
		local drawtype = def and def.drawtype or "normal"
		-- Whether light gets past this node, which in Luanti is a separate
		-- thing from whether it is drawn: glass has faces and lets the sun
		-- through. buildat used to have one test for both; see
		-- VoxelDefinition::transmits_light.
		local sunlight = (drawtype == "airlike") or
				(def and def.sunlight_propagates) or false
		local is_liquid = (drawtype == "liquid") or
				(drawtype == "flowingliquid")
		out[id] = {
			id = id,
			name = name or ("unknown_" .. id),
			drawtype = drawtype,
			sunlight = sunlight and true or false,
			-- Only airlike is nothing at all standing there; a glass pane
			-- that light passes through is still something
			empty = (drawtype == "airlike"),
			walkable = (def == nil) or (def.walkable ~= false),
			light_source = (def and def.light_source) or 0,
			tiles = is_liquid and (liquid_tiles(def) or tile_names(def)) or
					tile_names(def),
			node_box = (drawtype == "nodebox") and node_boxes(def) or nil,
			visual_scale = (def and def.visual_scale) or 1.0,
			-- What says two liquid nodes are the same liquid: a water source
			-- and a flowing water both name the source. Luanti pairs them
			-- this way and so does the mesher's shape_group.
			liquid_group = is_liquid and
					((def and def.liquid_alternative_source) or name) or nil,
			-- How many of the eight levels this liquid actually spends; a
			-- shorter range puts them all at the top of the voxel
			liquid_range = (def and def.liquid_range) or 8,
			-- A rooted plant's plant, which is special_tiles[1]: the node's
			-- own tiles are the cube it is rooted in
			overlay_tile = (drawtype == "plantlike_rooted") and
					tile_name_of((def and def.special_tiles or {})[1]) or nil,
			-- Blended rather than alpha masked. Without it framed glass and
			-- panes are drawn with every texel either solid or gone, where
			-- the game meant them to be seen through.
			alpha_blend = (def and def.use_texture_alpha == "blend") or false,
			facing = def and FACING_OF_PARAMTYPE2[def.paramtype2] or nil,
			-- Which rails this one reaches: Luanti's connect_to_raillike,
			-- an id from core.raillike_group(). Rails of the same id join.
			raillike_group = (drawtype == "raillike") and
					((def and def.connect_to_raillike) or 0) or nil,
		}
	end
	return out
end

--
-- What a mod is told about itself; modloader.lua sets these as it goes
--

core.__current_modname = nil
core.__mod_paths = {}
core.__mod_names = {}

function core.get_current_modname()
	return core.__current_modname
end

function core.get_modpath(modname)
	return core.__mod_paths[modname]
end

-- Alphabetical by default and in load order when asked, which is what Luanti
-- promises and what devtest checks
function core.get_modnames(by_load_order)
	local out = {}
	for _, name in ipairs(core.__mod_names) do
		out[#out + 1] = name
	end
	if not by_load_order then
		table.sort(out)
	end
	return out
end

function core.get_game_info()
	return {
		id = game_path:match("[^/]+$") or "",
		title = "",
		author = "",
		path = game_path,
	}
end

function core.is_singleplayer()
	return false
end

function core.request_insecure_environment()
	return nil
end

function core.get_version()
	return {project = "Luanti", string = "5.13.0", proto_min = 48,
			proto_max = 48, is_dev = false}
end

--
-- Mod storage
--
-- A file per mod under the world, written when the mod writes to it. Luanti
-- keeps this in the world's database and flushes it on a timer; a file is the
-- same promise with less machinery, and a mod cannot tell the difference
-- except in how often the disk is touched.
--

local mod_storages = {}

function core.get_mod_storage()
	local modname = core.get_current_modname()
	if modname == nil then
		return nil
	end
	if mod_storages[modname] then
		return mod_storages[modname]
	end
	local dir = world_path .. "/mod_storage"
	local path = dir .. "/" .. modname
	local fields = {}
	local data = read_file(path)
	if data then
		local ok, loaded = pcall(core.deserialize, data, true)
		if ok and type(loaded) == "table" then
			fields = loaded
		else
			core.log("error", "Cannot read mod storage of " .. modname)
		end
	end
	local storage = core.__new_metadata(fields)
	local set_string = storage.set_string
	-- Written through rather than on a timer: a mod that sets a value and
	-- then crashes the server has still set it
	storage.set_string = function(self, key, value)
		set_string(self, key, value)
		core.mkdir(dir)
		core.safe_file_write(path, core.serialize(self.fields))
	end
	mod_storages[modname] = storage
	return storage
end

--
-- Recorded, not implemented
--
-- Registrations whose effect is a milestone away but whose data is what that
-- milestone will need. Recording them costs a table and means a mod that
-- registers one at load is not lied to.
--

-- Which mod is running now, for the callback-origin tracking builtin does
local last_run_mod = nil

function core.set_last_run_mod(name)
	last_run_mod = name
end

function core.get_last_run_mod()
	return last_run_mod or core.get_current_modname()
end

core.__crafts = {}

function core.register_craft(recipe)
	core.__crafts[#core.__crafts + 1] = recipe
end

-- Detached inventories: the ones that belong to nobody, which builtin keeps
-- the callbacks of in core.detached_inventories
core.__detached_inventories = {}

function core.create_detached_inventory_raw(name, player_name)
	local inv = core.__new_inventory({type = "detached", name = name})
	core.__detached_inventories[name] = inv
	return inv
end

function core.remove_detached_inventory_raw(name)
	local existed = core.__detached_inventories[name] ~= nil
	core.__detached_inventories[name] = nil
	return existed
end

function core.get_inventory(location)
	location = location or {}
	if location.type == "detached" then
		return core.__detached_inventories[location.name]
	end
	if location.type == "node" and location.pos then
		return core.get_meta(location.pos):get_inventory()
	end
	return nil
end

--
-- Stubs
--
-- Everything the environment, the objects, the world and the network are
-- behind. A milestone moves names out of this list; see
-- doc/plan/luanti_module_plan.md for which milestone owns which.
--

local stub_warned = {}

local function stub(name, ret)
	core[name] = function()
		if not stub_warned[name] then
			stub_warned[name] = true
			core.log("warning", "core." .. name .. "() is a stub")
		end
		return ret
	end
end

local STUBS_NIL = {
	-- The environment (M2)
	"get_node", "get_node_or_nil", "get_node_raw", "set_node", "add_node",
	"bulk_set_node", "bulk_swap_node", "swap_node", "remove_node",
	"find_node_near", "find_nodes_in_area",
	"find_nodes_in_area_under_air", "find_nodes_with_meta",
	"get_node_light", "get_natural_light", "get_artificial_light",
	"place_node", "dig_node", "punch_node", "spawn_tree", "spawn_tree_on_vmanip",
	"get_perlin", "get_perlin_map", "get_value_noise", "get_value_noise_map",
	"get_voxel_manip", "set_mapgen_params", "get_mapgen_params",
	"get_mapgen_setting", "get_mapgen_setting_noiseparams",
	"set_mapgen_setting", "set_mapgen_setting_noiseparams",
	"get_mapgen_object", "get_mapgen_edges", "get_mapgen_chunksize",
	"set_noiseparams", "get_noiseparams", "generate_ores", "generate_decorations",
	"clear_objects", "load_area", "emerge_area", "delete_area",
	"line_of_sight", "raycast", "find_path", "transforming_liquid_add",
	"get_node_max_level", "get_node_level", "set_node_level", "add_node_level",
	"fix_light",
	"get_spawn_level", "get_heat", "get_humidity", "get_biome_data",
	"get_biome_id", "get_biome_name", "get_mapgen_params",
	"forceload_block", "forceload_free_block", "compare_block_status",
	"get_meta", "get_node_metadata",
	-- Time and the world (M2)
	"get_timeofday", "set_timeofday", "get_gametime", "get_day_count",
	"set_time_of_day",
	-- Players (M5); the objects are in lua/entity.lua
	"get_player_by_name", "get_connected_players", "get_player_information",
	"get_player_window_information",
	-- Inventory, craft, metadata (M4); the recipes are in lua/craft.lua
	"register_craft_raw",
	"get_dig_params", "get_hit_params", "get_tool_wear_after_use",
	-- Chat, HUD, sound, particles (M4, M5)
	"chat_send_all", "chat_send_player", "send_join_message",
	"send_leave_message", "sound_play", "sound_stop", "sound_fade",
	"add_particle", "add_particlespawner", "delete_particlespawner",
	"show_formspec", "close_formspec", "hud_replace_builtin",
	-- Auth and privileges (M4)
	"get_password_hash", "check_password_entry", "notify_authentication_modified",
	"set_player_privs", "get_player_privs", "auth_reload",
	"kick_player", "disconnect_player", "ban_player", "unban_player_or_ip",
	"get_ban_list", "get_ban_description",
	-- The server itself
	"request_shutdown", "cancel_shutdown_requests", "get_server_status",
	"get_server_uptime", "get_server_max_lag", "get_worldpath_nocreate",
	"dynamic_add_media", "get_mod_data", "set_mod_data", "get_mod_data_path",
	-- Not in this at all: HTTP, IPC, the async environment, mod channels,
	-- SSCSM, translations beyond passing strings through
	"request_http_api", "set_http_api_lua", "ipc_get", "ipc_set", "ipc_cas",
	"ipc_poll", "mod_channel_join", "register_async_dofile",
	"register_mapgen_script", "register_sscsm", "do_async_callback",
	"serialize_roundtrip", "get_globals_to_transfer",
	"urlencode",
}

for _, name in ipairs(STUBS_NIL) do
	stub(name, nil)
end

-- The ones Luanti always answers with a list, whether or not there is
-- anything in it. A stub that says nil instead takes its caller down the
-- moment it writes the ipairs() every one of these is written for: devtest's
-- testhud does it in a globalstep, twelve times a second, and the error is
-- in the mod rather than anywhere that says what is really missing.
--
-- A fresh table each call, because a caller may keep or add to what it is
-- given and the next caller should not see that.
local function stub_list(name)
	core[name] = function()
		if not stub_warned[name] then
			stub_warned[name] = true
			core.log("warning", "core." .. name .. "() is a stub")
		end
		return {}
	end
end

for _, name in ipairs({
	"get_connected_players", "find_nodes_with_meta",
}) do
	stub_list(name)
end

-- The two an object is in, which lua/entity.lua fills: tables rather than
-- functions, because indexing a function is an error and a mod that only
-- looks should not be broken by what it finds
core.object_refs = {}
core.luaentities = {}

-- The few whose nil would take a caller down where an empty one will not
-- The mapgen registrations are recorded rather than stubbed: the terrain is
-- a milestone away, and when it arrives this is the data it wants. The
-- handles are indices, which is what Luanti's are.
core.registered_biomes = {}
core.registered_ores = {}
core.registered_decorations = {}

local function recording_registration(kind)
	local list = core["registered_" .. kind .. "s"]
	core["register_" .. kind] = function(def)
		list[#list + 1] = def
		return #list
	end
	core["clear_registered_" .. kind .. "s"] = function()
		for i = #list, 1, -1 do
			list[i] = nil
		end
	end
end

recording_registration("biome")
recording_registration("ore")
recording_registration("decoration")
stub("register_schematic", 0)
stub("clear_registered_schematics", nil)
stub("read_schematic", nil)
stub("create_schematic", nil)
stub("place_schematic", nil)
stub("place_schematic_on_vmanip", nil)
stub("serialize_schematic", nil)

--
-- The map
--
-- These come after the stub list on purpose: they are the names it turns off
-- until the milestone that answers them, and this is that milestone for the
-- read and the write. Everything goes through two C functions, and what they
-- talk to is a write-behind buffer in the module that voxelworld sees once
-- per Luanti step. See doc/plan/luanti_module_plan.md, "set_node is buffered".

local __set_node = __luanti_set_node
local __get_node = __luanti_get_node
local __get_region = __luanti_get_region
-- The loaded sections, as voxel boxes; see the ABMs further down
local __active_boxes = __luanti_active_boxes
-- The voxels of a kind in a box; see the ABMs further down
local __find_ids = __luanti_find_ids

local function to_pos(pos)
	-- Luanti rounds, it does not truncate: -0.4 is 0 and not 0
	return math.floor(pos.x + 0.5), math.floor(pos.y + 0.5),
			math.floor(pos.z + 0.5)
end

-- Luanti takes a node as a name or as a table with one, and fills in the two
-- params from the definition when they are not given
local function to_node(node)
	if type(node) == "string" then
		node = {name = node}
	end
	local name = node.name
	if name == nil then
		error("set_node(): the node has no name")
	end
	return core.get_content_id(name), node.param1 or 0, node.param2 or 0
end

function core.get_node(pos)
	local x, y, z = to_pos(pos)
	local id, param1, param2 = __get_node(x, y, z)
	return {
		name = core.get_name_from_content_id(id),
		param1 = param1,
		param2 = param2,
	}
end

-- nil where the map is not loaded. Ignore is what voxelworld says for a
-- section that has not been generated, which is the same statement.
function core.get_node_or_nil(pos)
	local x, y, z = to_pos(pos)
	local id, param1, param2 = __get_node(x, y, z)
	if id == core.CONTENT_IGNORE then
		return nil
	end
	return {
		name = core.get_name_from_content_id(id),
		param1 = param1,
		param2 = param2,
	}
end

core.get_node_raw = function(x, y, z)
	local id, param1, param2 = __get_node(
			math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5))
	return id, param1, param2, id ~= core.CONTENT_IGNORE
end

-- The bare write, without the callbacks. set_node and add_node are the same
-- call in Luanti; swap_node is this one, by definition.
function core.swap_node(pos, node)
	local x, y, z = to_pos(pos)
	local id, param1, param2 = to_node(node)
	__set_node(x, y, z, id, param1, param2)
	return true
end

--
-- Node metadata
--
-- A metadata object per position, which is what a chest's contents, a sign's
-- text and anything else a node remembers live in. The builtin reaches for
-- one on every dig of a node whose definition has an after_dig_node, so this
-- is what makes those callbacks work at all.
--
-- simplified: in memory, so it is gone when the server stops. Putting it in
-- the save is step 5c of doc/plan/world_persistence_plan.md -- "with M4, not
-- before it" -- and until then a chest remembers what is in it for as long
-- as the server runs and no longer. Worth knowing before building on it.

local node_meta = {}

local function pos_key(x, y, z)
	return x .. "," .. y .. "," .. z
end

function core.get_meta(pos)
	local x, y, z = to_pos(pos)
	local key = pos_key(x, y, z)
	local meta = node_meta[key]
	if meta == nil then
		meta = core.__new_metadata({})
		-- A node's metadata carries an inventory and an item stack's does
		-- not, which is the whole difference between the two in Luanti as
		-- well: a chest is a list in here
		meta.inventory = core.__new_inventory(
				{type = "node", pos = {x = x, y = y, z = z}})
		node_meta[key] = meta
	end
	return meta
end

core.get_node_metadata = core.get_meta

-- A timer per position, which is what a furnace burning down and a plant
-- growing on its own are written on. Luanti keeps one per block and runs
-- the ones whose block is loaded; here the world is loaded whole, so a
-- timer runs wherever it is.
--
-- simplified: in memory beside the metadata above, and gone when the server
-- stops, for the same reason and with the same upgrade path.

local node_timers = {}

local NodeTimerRef = {}
NodeTimerRef.__index = NodeTimerRef

function NodeTimerRef:set(timeout, elapsed)
	if timeout == nil or timeout <= 0 then
		node_timers[self.key] = nil
		return
	end
	node_timers[self.key] = {
		pos = self.pos,
		timeout = timeout,
		elapsed = elapsed or 0,
	}
end

function NodeTimerRef:start(timeout)
	self:set(timeout, 0)
end

function NodeTimerRef:stop()
	node_timers[self.key] = nil
end

function NodeTimerRef:is_started()
	return node_timers[self.key] ~= nil
end

function NodeTimerRef:get_timeout()
	local t = node_timers[self.key]
	return t and t.timeout or 0
end

function NodeTimerRef:get_elapsed()
	local t = node_timers[self.key]
	return t and t.elapsed or 0
end

function core.get_node_timer(pos)
	local x, y, z = to_pos(pos)
	return setmetatable({key = pos_key(x, y, z), pos = {x = x, y = y, z = z}},
			NodeTimerRef)
end

-- A timer that has run out is stopped before its on_timer is called, so that
-- the callback is free to start it again -- and it is restarted with the
-- same timeout when the callback says true, which is Luanti's own rule.
local function run_node_timers(dtime)
	local due = nil
	for key, t in pairs(node_timers) do
		t.elapsed = t.elapsed + dtime
		if t.elapsed >= t.timeout then
			due = due or {}
			due[#due + 1] = key
		end
	end
	if due == nil then
		return
	end
	for _, key in ipairs(due) do
		local t = node_timers[key]
		if t then
			node_timers[key] = nil
			local def = core.registered_nodes[core.get_node(t.pos).name]
			if def and def.on_timer then
				local ok, again = pcall(def.on_timer, t.pos, t.elapsed)
				if not ok then
					core.log("error", "on_timer: " .. tostring(again))
				elseif again then
					node_timers[key] = {pos = t.pos, timeout = t.timeout,
							elapsed = 0}
				end
			end
		end
	end
end

function core.set_node(pos, node)
	local x, y, z = to_pos(pos)
	local id, param1, param2 = to_node(node)
	-- What was there gets its on_destruct, what arrives gets its
	-- on_construct: a mod that keeps state per node is written around these
	-- two and would leak without them. Node metadata and timers are M4, so
	-- nothing is dropped here that exists yet.
	local oldnode = core.get_node(pos)
	local olddef = core.registered_nodes[oldnode.name]
	if olddef and olddef.on_destruct then
		olddef.on_destruct(pos)
	end
	__set_node(x, y, z, id, param1, param2)
	-- "Any existing metadata is deleted", which is what separates set_node
	-- from swap_node; see core.get_meta(). The timer goes with it: it was
	-- the old node's.
	node_meta[pos_key(x, y, z)] = nil
	node_timers[pos_key(x, y, z)] = nil
	local newdef = core.registered_nodes[core.get_name_from_content_id(id)]
	if newdef and newdef.on_construct then
		newdef.on_construct(pos)
	end
	if olddef and olddef.after_destruct then
		olddef.after_destruct(pos, oldnode)
	end
	return true
end

core.add_node = core.set_node

function core.remove_node(pos)
	return core.set_node(pos, {name = "air"})
end

function core.bulk_set_node(positions, node)
	local id, param1, param2 = to_node(node)
	for i = 1, #positions do
		local x, y, z = to_pos(positions[i])
		__set_node(x, y, z, id, param1, param2)
	end
	return true
end

function core.bulk_swap_node(positions, node)
	return core.bulk_set_node(positions, node)
end

-- The light voxelworld propagates, which the voxel word carries in the same
-- bits Luanti's param1 does. Time of day is M2's clock; until it is there,
-- the sky is at full strength.
function core.get_natural_light(pos, timeofday)
	local x, y, z = to_pos(pos)
	local _, param1 = __get_node(x, y, z)
	return math.floor(param1 % 16)
end

function core.get_artificial_light(param1)
	return math.floor(param1 / 16) % 16
end

function core.get_node_light(pos, timeofday)
	local x, y, z = to_pos(pos)
	local id, param1 = __get_node(x, y, z)
	if id == core.CONTENT_IGNORE then
		return nil
	end
	local day = math.floor(param1 % 16)
	local night = math.floor(param1 / 16) % 16
	return day > night and day or night
end

-- The region reads: the same seam over a box instead of a voxel.
--
-- simplified: a voxel at a time through the same two C functions, so a big
-- box is a lot of small reads. The upgrade path is one C call that reads a
-- region out of voxelworld, which is what VoxelManip wants anyway; the
-- shapes of these functions do not change when it arrives.

local function name_matcher(nodenames)
	if type(nodenames) == "string" then
		nodenames = {nodenames}
	end
	local plain = {}
	local groups = {}
	for _, n in ipairs(nodenames) do
		local g = string.match(n, "^group:(.*)$")
		if g then
			groups[#groups + 1] = g
		else
			plain[n] = true
		end
	end
	return function(name)
		if plain[name] then
			return true
		end
		for _, g in ipairs(groups) do
			if core.get_item_group(name, g) ~= 0 then
				return true
			end
		end
		return false
	end
end

-- The box read the three functions below share: one engine call rather than
-- one per voxel, since a read that crosses the Lua boundary costs a module
-- lock and its hierarchy validated, and the work inside voxelworld is nearly
-- free by comparison. The array is x fastest and then y and then z.
--
-- The name lookup is cached per content id, because a box is usually a
-- handful of distinct nodes however large it is.
local function region_names(x0, y0, z0, x1, y1, z1)
	local ids = __get_region(x0, y0, z0, x1, y1, z1)
	local names = {}
	local name_of = {}
	for i = 1, #ids do
		local id = ids[i]
		local name = name_of[id]
		if name == nil then
			name = core.get_name_from_content_id(id)
			name_of[id] = name
		end
		names[i] = name
	end
	return names
end

-- Luanti sorts by distance and returns the nearest; search_center adds pos
-- itself as the first thing looked at
function core.find_node_near(pos, radius, nodenames, search_center)
	local matches = name_matcher(nodenames)
	local x, y, z = to_pos(pos)
	local names = region_names(x - radius, y - radius, z - radius,
			x + radius, y + radius, z + radius)
	local w = radius * 2 + 1
	local function at(dx, dy, dz)
		return names[(dx + radius) + (dy + radius) * w +
				(dz + radius) * w * w + 1]
	end
	if search_center and matches(at(0, 0, 0)) then
		return {x = x, y = y, z = z}
	end
	-- Shells outwards, so the first hit is the nearest one
	for r = 1, radius do
		for dx = -r, r do
			for dy = -r, r do
				for dz = -r, r do
					if math.max(math.abs(dx), math.abs(dy), math.abs(dz)) == r then
						if matches(at(dx, dy, dz)) then
							return {x = x + dx, y = y + dy, z = z + dz}
						end
					end
				end
			end
		end
	end
	return nil
end

-- add_node is set_node under another name, which is what it is in Luanti too
core.add_node = core.set_node

function core.remove_node(pos)
	return core.set_node(pos, {name = "air"})
end

-- What set_node would clear and this keeps: no on_destruct, no on_construct,
-- and the metadata and the node timer left where they are. What wants it is
-- a node changing its own appearance -- a furnace lighting up -- where a
-- construct and a destruct would throw away the state the change is about.
function core.swap_node(pos, node)
	local x, y, z = to_pos(pos)
	local id, param1, param2 = to_node(node)
	__set_node(x, y, z, id, param1, param2)
	return true
end

function core.bulk_set_node(positions, node)
	for _, pos in ipairs(positions) do
		core.set_node(pos, node)
	end
	return true
end

function core.bulk_swap_node(positions, node)
	for _, pos in ipairs(positions) do
		core.swap_node(pos, node)
	end
	return true
end

--
-- Digging, placing and punching, with nobody doing them
--
-- The three things a player's actions come to, and what a mod calls when it
-- wants the same thing to happen without one. Luanti's own l_dig_node,
-- l_place_node and l_punch_node: each makes the pointed thing a player's
-- action would have made, hands it to the vendored builtin with a nil actor,
-- and lets that run the callbacks. So `on_dig`, `can_dig`, `after_dig_node`,
-- `on_construct`, `after_place_node`, the drop list and the registered
-- on_dignodes and on_placenodes are the builtin's own and behave as they do
-- in Luanti, rather than being written again here.
--
-- What a dig drops lands on the ground: core.handle_node_drops() hands the
-- drops to core.add_item(), which is the vendored builtin's own item entity
-- now that there are objects for it to be. With no digger there is no
-- inventory to put anything in, so everything a dig drops is spawned.

local function pointed_at(pos)
	return {
		type = "node",
		above = {x = pos.x, y = pos.y, z = pos.z},
		under = {x = pos.x, y = pos.y - 1, z = pos.z},
	}
end

function core.dig_node(pos)
	local node = core.get_node(pos)
	if node.name == "ignore" then
		return false
	end
	return core.node_dig(pos, node, nil) and true or false
end

function core.punch_node(pos)
	local node = core.get_node(pos)
	if node.name == "ignore" then
		return false
	end
	core.node_punch(pos, node, nil, pointed_at(pos))
	return true
end

function core.place_node(pos, node, placer)
	local name = type(node) == "string" and node or node.name
	if name == nil then
		error("place_node(): the node has no name")
	end
	local param2 = type(node) == "table" and node.param2 or nil
	-- Luanti places it as an item so that a node with an on_place of its own
	-- gets it, which is how a mod makes placing one node put down another
	core.item_place(ItemStack(name), placer, pointed_at(pos), param2)
	return true
end

-- Returns positions, counts -- or a table of name to positions when grouped
function core.find_nodes_in_area(minp, maxp, nodenames, grouped)
	local matches = name_matcher(nodenames)
	local x0, y0, z0 = to_pos(minp)
	local x1, y1, z1 = to_pos(maxp)
	if x1 < x0 or y1 < y0 or z1 < z0 then
		return grouped and {} or {}, {}
	end
	local positions = {}
	local counts = {}
	local by_name = {}
	local names = region_names(x0, y0, z0, x1, y1, z1)
	local i = 0
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				i = i + 1
				local name = names[i]
				if matches(name) then
					local p = {x = x, y = y, z = z}
					if grouped then
						local list = by_name[name]
						if not list then
							list = {}
							by_name[name] = list
						end
						list[#list + 1] = p
					else
						positions[#positions + 1] = p
						counts[name] = (counts[name] or 0) + 1
					end
				end
			end
		end
	end
	if grouped then
		-- Luanti gives an empty list for every name that was asked for
		if type(nodenames) == "string" then
			nodenames = {nodenames}
		end
		for _, n in ipairs(nodenames) do
			if by_name[n] == nil and not string.match(n, "^group:") then
				by_name[n] = {}
			end
		end
		return by_name
	end
	return positions, counts
end

function core.find_nodes_in_area_under_air(minp, maxp, nodenames)
	local matches = name_matcher(nodenames)
	local x0, y0, z0 = to_pos(minp)
	local x1, y1, z1 = to_pos(maxp)
	local positions = {}
	if x1 < x0 or y1 < y0 or z1 < z0 then
		return positions
	end
	local names = region_names(x0, y0, z0, x1, y1, z1)
	local w = x1 - x0 + 1
	local h = y1 - y0 + 1
	for z = z0, z1 do
		for x = x0, x1 do
			-- Downwards, so the node above is the one just looked at
			local above_name = nil
			for y = y1, y0, -1 do
				local name = names[(x - x0) + (y - y0) * w +
						(z - z0) * w * h + 1]
				if above_name == "air" and matches(name) then
					positions[#positions + 1] = {x = x, y = y, z = z}
				end
				above_name = name
			end
		end
	end
	return positions
end

--
-- The clock
--
-- Luanti's own, stepped with the environment rather than read off the wall:
-- time_speed is how many game seconds a real second is, 72 by default, which
-- is a 20 minute day.
--
-- It is kept in the save's object store, beside the map; the module reads it
-- before the mods load and writes it at shutdown, through the two functions
-- at the end of this section.

local time_of_day = 0.5     -- 0..1, noon
local game_time = 0.0       -- seconds since the world was made
local day_count = 0

function core.get_timeofday()
	return time_of_day
end

function core.set_timeofday(new_time)
	if type(new_time) ~= "number" then
		error("set_timeofday(): not a number: " .. tostring(new_time))
	end
	time_of_day = new_time % 1.0
end

core.set_time_of_day = core.set_timeofday

function core.get_gametime()
	return math.floor(game_time)
end

function core.get_day_count()
	return day_count
end

-- One Luanti step. The module calls this at Luanti's own rate rather than
-- buildat's, because a mod's globalstep dtime and core.after's resolution are
-- written against dedicated_server_step.
-- The globalsteps a mod registered, run once per Luanti step.
--
-- core.after is one of them: the vendored builtin/common/after.lua keeps its
-- queue in a globalstep of its own, so this is what makes core.after fire at
-- all -- and what every mod that does anything on a timer is written around.
--
-- A callback that errors is logged and the rest still run, where Luanti
-- stops the server. One mod's bad frame should not stop the clock or the
-- other mods here: the module already treats a failed step as a warning
-- rather than the end, and this is the same posture one level down.
local function run_globalsteps(dtime)
	local callbacks = core.registered_globalsteps
	if callbacks == nil then
		return
	end
	for i = 1, #callbacks do
		local callback = callbacks[i]
		local origin = core.callback_origins and core.callback_origins[callback]
		if origin then
			core.set_last_run_mod(origin.mod)
		end
		local ok, err = pcall(callback, dtime)
		if not ok then
			core.log("error", "globalstep: " .. tostring(err))
		end
	end
end

--
-- ABMs
--
-- An ABM is a rule that runs on every node of a kind, forever: grass turns
-- to dirt under something, a furnace burns, a leaf decays. Luanti runs them
-- over the blocks that are active -- near a player -- and here over the
-- sections that are loaded, which is the same idea and the same list under
-- another name, since there are no players yet.
--
-- The registry freezes after the mods have loaded, so the timers are built
-- on the first step rather than kept up to date with it.
--
-- The match is on content ids and happens in the module, so what crosses
-- into Lua is the voxels a rule is about and not the section.
--
-- simplified: no time budget and no catch-up, and every loaded section is
-- read for every rule that is due. Luanti spends at most a share of a step
-- on ABMs, skips ahead when a block comes back after a long time away, and
-- keeps a per-block list of which node kinds are in it so that most blocks
-- are never read. All three are about a map bigger than the sections a mod
-- can reach here; the upgrade path is M6's, with the map that wants them.

local abm_timers = nil
local abm_ids = nil

-- Which content ids a rule is about, since the sweep matches ids and not
-- names: a name list is turned into one of these once, because the node
-- registry is frozen by the time anything steps.
local function ids_matching(nodenames)
	local matches = name_matcher(nodenames)
	local ids = {}
	for name, _ in pairs(core.registered_nodes) do
		if matches(name) then
			ids[#ids + 1] = core.get_content_id(name)
		end
	end
	return ids
end

local function abm_neighbors_ok(abm, pos)
	if abm.neighbors == nil or #abm.neighbors == 0 then
		return true
	end
	return core.find_node_near(pos, 1, abm.neighbors) ~= nil
end

-- Every loaded section, once, against a set of ids per rule: on_hits(k,
-- hits) gets the flat x,y,z list of what the section held of set k. One read
-- per section however many rules there are, because the read is what a sweep
-- costs and the module matches 32 sets of ids at a time.
local function sweep_sections(id_sets, on_hits)
	if #id_sets == 0 then
		return 0
	end
	local boxes = __active_boxes()
	for _, box in ipairs(boxes) do
		for first = 1, #id_sets, 32 do
			local last = math.min(first + 31, #id_sets)
			local batch = {}
			for k = first, last do
				batch[#batch + 1] = id_sets[k]
			end
			local found = __find_ids(box[1], box[2], box[3],
					box[4], box[5], box[6], batch)
			for k = first, last do
				on_hits(k, found[k - first + 1])
			end
		end
	end
	return #boxes
end

-- One rule over the voxels of its kind that one section turned out to hold
local function run_abm(abm, hits)
	local chance = abm.chance or 1
	local min_y = abm.min_y or -32768
	local max_y = abm.max_y or 32767
	for i = 1, #hits, 3 do
		local y = hits[i + 1]
		if y >= min_y and y <= max_y and
				(chance <= 1 or math.random(chance) == 1) then
			local pos = {x = hits[i], y = y, z = hits[i + 2]}
			if abm_neighbors_ok(abm, pos) then
				core.set_last_run_mod(abm.mod_origin)
				-- The two counts are how many objects are in the block and
				-- around it; there are none yet
				local ok, err = pcall(abm.action, pos, core.get_node(pos),
						0, 0)
				if not ok then
					core.log("error", "abm " .. tostring(abm.label or "?") ..
							": " .. tostring(err))
				end
			end
		end
	end
end

local function run_abms(dtime)
	local abms = core.registered_abms
	if abms == nil or #abms == 0 then
		return
	end
	if abm_timers == nil then
		abm_timers = {}
		abm_ids = {}
		for i = 1, #abms do
			abm_timers[i] = 0
			abm_ids[i] = ids_matching(abms[i].nodenames)
		end
	end
	local due = nil
	for i = 1, #abms do
		abm_timers[i] = abm_timers[i] + dtime
		if abm_timers[i] >= (abms[i].interval or 1) then
			abm_timers[i] = 0
			due = due or {}
			due[#due + 1] = i
		end
	end
	if due == nil then
		return
	end
	local sets = {}
	for k = 1, #due do
		sets[k] = abm_ids[due[k]]
	end
	sweep_sections(sets, function(k, hits)
		run_abm(abms[due[k]], hits)
	end)
end

--
-- LBMs
--
-- The same idea on a section rather than on a timer: a rule that runs over
-- the nodes of a kind when the part of the map they are in is loaded, which
-- is how a game fixes up what it saved before it changed its mind about it.
--
-- simplified: the whole world is loaded before anything steps and nothing
-- unloads it, so "on load" is once, at the first step, over every section --
-- and run_at_every_load and Luanti's record of which blocks are older than
-- which rule have nothing to be different about yet. Both belong with M6's
-- map, which is where a section stops being loaded for the whole run.

local lbms_run = false

local function run_lbm(lbm, hits)
	local positions = {}
	for i = 1, #hits, 3 do
		positions[#positions + 1] =
				{x = hits[i], y = hits[i + 1], z = hits[i + 2]}
	end
	if #positions == 0 then
		return
	end
	core.set_last_run_mod(lbm.mod_origin)
	-- dtime_s is how long the block was away, and nothing here has been
	local ok, err
	if lbm.bulk_action then
		ok, err = pcall(lbm.bulk_action, positions, 0)
	else
		ok = true
		for _, pos in ipairs(positions) do
			local ok1, err1 = pcall(lbm.action, pos, core.get_node(pos), 0)
			if not ok1 then
				ok, err = false, err1
				break
			end
		end
	end
	if not ok then
		core.log("error", "lbm " .. tostring(lbm.name or "?") .. ": " ..
				tostring(err))
	end
end

-- Returns whether this was the load: the first steps happen before the world
-- has a section in it -- lua/check_map.lua steps the clock a whole day
-- before anything is flushed -- and a sweep over nothing is not one.
local function run_lbms()
	local lbms = core.registered_lbms
	if lbms == nil or #lbms == 0 then
		return true
	end
	local sets = {}
	for i = 1, #lbms do
		sets[i] = ids_matching(lbms[i].nodenames)
	end
	return sweep_sections(sets, function(k, hits)
		run_lbm(lbms[k], hits)
	end) > 0
end

function core.__step(dtime)
	run_globalsteps(dtime)
	core.__step_objects(dtime)
	run_node_timers(dtime)
	if not lbms_run then
		lbms_run = run_lbms()
	end
	run_abms(dtime)
	game_time = game_time + dtime
	local speed = tonumber(core.settings:get("time_speed")) or 72
	local day_seconds = 24 * 60 * 60
	time_of_day = time_of_day + dtime * speed / day_seconds
	while time_of_day >= 1.0 do
		time_of_day = time_of_day - 1.0
		day_count = day_count + 1
	end
end

-- What the module reads out of the clock and puts back into it. Three numbers
-- rather than a table, because that is all the clock is.
function core.__get_clock()
	return time_of_day, game_time, day_count
end

function core.__set_clock(tod, gt, dc)
	time_of_day = tod % 1.0
	game_time = gt
	day_count = dc
end

--
-- The classes a mod builds while it loads: ItemStack and the generators
--

dofile(module_path .. "/lua/classes.lua")
dofile(module_path .. "/lua/colorspec.lua")
dofile(module_path .. "/lua/png.lua")
dofile(module_path .. "/lua/misc.lua")
dofile(module_path .. "/lua/entity.lua")
dofile(module_path .. "/lua/craft.lua")
dofile(module_path .. "/lua/check_map.lua")

-- vim: set noet ts=4 sw=4:
