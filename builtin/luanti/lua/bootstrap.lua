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
		-- A voxel is invisible to the mesher exactly when light goes through
		-- it: buildat's EDGEMATERIALID_EMPTY is one test and the mesher uses
		-- it for both. Luanti splits them, so this is the conservative half
		-- of the split until M3 brings the real drawtypes.
		local transparent = (drawtype == "airlike") or
				(def and def.sunlight_propagates) or false
		out[id] = {
			id = id,
			name = name or ("unknown_" .. id),
			drawtype = drawtype,
			transparent = transparent and true or false,
			-- Only airlike is nothing at all standing there; a glass pane
			-- that light passes through is still something
			empty = (drawtype == "airlike"),
			walkable = (def == nil) or (def.walkable ~= false),
			light_source = (def and def.light_source) or 0,
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
-- The map
--
-- These come after the stub list on purpose: they are the names it turns off
-- until the milestone that answers them, and this is that milestone for the
-- read and the write. Everything goes through two C functions, and what they
-- talk to is a write-behind buffer in the module that voxelworld sees once
-- per Luanti step. See doc/plan/luanti_module_plan.md, "set_node is buffered".

local __set_node = __luanti_set_node
local __get_node = __luanti_get_node

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

-- Luanti sorts by distance and returns the nearest; search_center adds pos
-- itself as the first thing looked at
function core.find_node_near(pos, radius, nodenames, search_center)
	local matches = name_matcher(nodenames)
	local x, y, z = to_pos(pos)
	if search_center then
		local id = __get_node(x, y, z)
		if matches(core.get_name_from_content_id(id)) then
			return {x = x, y = y, z = z}
		end
	end
	-- Shells outwards, so the first hit is the nearest one
	for r = 1, radius do
		for dx = -r, r do
			for dy = -r, r do
				for dz = -r, r do
					if math.max(math.abs(dx), math.abs(dy), math.abs(dz)) == r then
						local id = __get_node(x + dx, y + dy, z + dz)
						if matches(core.get_name_from_content_id(id)) then
							return {x = x + dx, y = y + dy, z = z + dz}
						end
					end
				end
			end
		end
	end
	return nil
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
	for z = z0, z1 do
		for y = y0, y1 do
			for x = x0, x1 do
				local id = __get_node(x, y, z)
				local name = core.get_name_from_content_id(id)
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
	for z = z0, z1 do
		for x = x0, x1 do
			-- Downwards, so the node above is the one just looked at
			local above_name = nil
			for y = y1, y0, -1 do
				local name = core.get_name_from_content_id(__get_node(x, y, z))
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
function core.__step(dtime)
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
dofile(module_path .. "/lua/check_map.lua")

-- vim: set noet ts=4 sw=4:
