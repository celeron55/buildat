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
		-- Luanti hands these out from zero and jumps over its own three,
		-- which sit at the top of the first byte
		while next_content_id >= 125 and next_content_id <= 127 do
			next_content_id = next_content_id + 1
		end
		id = next_content_id
		next_content_id = next_content_id + 1
	end
	core.__content_ids[name] = id
	core.__content_names[id] = name
end

-- Luanti's three, at the numbers Luanti gives them: a world written by one
-- engine and read by the other has to agree about what air is. The rest are
-- handed out in registration order, as Luanti does.
reserve_content_id("unknown", 125)
reserve_content_id("air", 126)
reserve_content_id("ignore", 127)

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

function core.get_name_from_content_id(id)
	if type(id) ~= "number" then
		error("get_name_from_content_id(): not a content id: " .. tostring(id))
	end
	return core.__content_names[id] or "unknown"
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
	return nil
end

--
-- Stubs
--
-- Everything the environment, the objects, the world and the network are
-- behind. A milestone moves names out of this list; see
-- local/luanti_module_plan.md for which milestone owns which.
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
	"fix_light", "check_single_for_falling", "check_for_falling",
	"get_spawn_level", "get_heat", "get_humidity", "get_biome_data",
	"get_biome_id", "get_biome_name", "get_mapgen_params",
	"forceload_block", "forceload_free_block", "compare_block_status",
	"get_node_timer", "get_meta", "get_node_metadata",
	-- Time and the world (M2)
	"get_timeofday", "set_timeofday", "get_gametime", "get_day_count",
	"set_time_of_day",
	-- Objects and players (M5)
	"add_entity", "add_item", "get_player_by_name", "get_objects_inside_radius",
	"get_objects_in_area", "get_connected_players", "get_player_information",
	"get_player_window_information", "object_refs", "luaentities",
	-- Inventory, craft, metadata (M4)
	"get_craft_result", "get_craft_recipe",
	"get_all_craft_recipes", "register_craft_raw", "clear_craft",
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
-- The classes a mod builds while it loads: ItemStack and the generators
--

dofile(module_path .. "/lua/classes.lua")
dofile(module_path .. "/lua/colorspec.lua")
dofile(module_path .. "/lua/png.lua")
dofile(module_path .. "/lua/misc.lua")

-- vim: set noet ts=4 sw=4:
