-- Buildat: builtin/luanti/lua/stubs.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The auth database, what is recorded and not implemented, and the stubs.
-- Run by bootstrap.lua ([SPLITS]: moved out as it was).

--
-- The auth database
--
-- What the vendored builtin's auth handler is written on: a row per player
-- with a password, the privileges they have and when they last logged in.
-- In Luanti it is a table in the world's auth.sqlite; here it is a table in
-- memory, because nothing asks a player for a password -- whoever connects
-- is who they say they are, which is what a buildat server already decided
-- one layer down.
--
-- It goes into the save with the players, which is where a privilege a mod
-- granted belongs: see core.__save_players() in lua/entity.lua.

local auth_entries = {}

-- What that reads and writes; it is beside the players rather than a blob of
-- its own because one is what the other is about
core.__auth_entries = auth_entries

core.auth = {
	read = function(name)
		local e = auth_entries[name]
		if e == nil then
			return nil
		end
		return {name = e.name, password = e.password,
				privileges = e.privileges, last_login = e.last_login}
	end,
	save = function(entry)
		if type(entry) ~= "table" or type(entry.name) ~= "string" then
			return false
		end
		auth_entries[entry.name] = entry
		return true
	end,
	create = function(entry)
		if type(entry) ~= "table" or type(entry.name) ~= "string" then
			return false
		end
		auth_entries[entry.name] = entry
		return true
	end,
	delete = function(name)
		if auth_entries[name] == nil then
			return false
		end
		auth_entries[name] = nil
		return true
	end,
	list_names = function()
		local out = {}
		for name, _ in pairs(auth_entries) do
			out[#out + 1] = name
		end
		return out
	end,
	reload = function()
		return true
	end,
}

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
	if core.__forget_craft_index then
		core.__forget_craft_index()
	end
end

-- Detached inventories: the ones that belong to nobody, which builtin keeps
-- the callbacks of in core.detached_inventories
core.__detached_inventories = {}

-- Who a detached inventory is for: a player's name, or nil for everyone.
-- Luanti sends one made for a player to that player alone, and takes
-- actions on it from nobody else (checkDetachedInventoryAccess).
core.__detached_players = {}

function core.create_detached_inventory_raw(name, player_name)
	local inv = core.__new_inventory({type = "detached", name = name})
	core.__detached_inventories[name] = inv
	core.__detached_players[name] =
			(type(player_name) == "string" and player_name ~= "") and
			player_name or nil
	return inv
end

function core.remove_detached_inventory_raw(name)
	local existed = core.__detached_inventories[name] ~= nil
	core.__detached_inventories[name] = nil
	core.__detached_players[name] = nil
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
	"find_nodes_in_area_under_air",
	"get_node_light", "get_natural_light", "get_artificial_light",
	"place_node", "dig_node", "punch_node",
	-- spawn_tree and spawn_tree_on_vmanip are in lua/treegen.lua
	"get_mapgen_setting_noiseparams", "set_mapgen_setting_noiseparams",
	"set_noiseparams", "get_noiseparams", "generate_ores", "generate_decorations",
	"clear_objects", "delete_area",
	-- get_loaded_blocks, get_active_blocks, get_loadable_blocks and
	-- compare_block_status are below
	-- line_of_sight and raycast are in lua/raycast.lua
	"find_path",
	-- get_heat, get_humidity, get_biome_data, get_biome_id and
	-- get_biome_name are above core.__mapgen_biomes()
	"get_meta", "get_node_metadata",
	-- Time and the world (M2)
	"get_timeofday", "set_timeofday", "get_gametime", "get_day_count",
	"set_time_of_day",
	-- The players and the objects are in lua/entity.lua
	-- Inventory, craft, metadata (M4); the recipes are in lua/craft.lua
	"register_craft_raw",
	-- Chat, HUD, sound, particles (M4, M5)
	"send_join_message",
	"send_leave_message",
	-- sound_play, sound_stop and sound_fade are in lua/sound.lua, and the
	-- three particle calls in lua/particles.lua
	"hud_replace_builtin",
	-- Auth and privileges (M4)
	"set_player_privs", "auth_reload",
	-- kick_player, disconnect_player, the bans and get_player_ip are
	-- builtin/accounts', below
	-- The server itself
	"cancel_shutdown_requests", "get_server_status",
	"get_server_max_lag", "get_worldpath_nocreate",
	"get_mod_data", "set_mod_data", "get_mod_data_path",
	-- Not in this at all: HTTP, IPC, the async environment, mod channels,
	-- SSCSM, translations beyond passing strings through
	"request_http_api", "set_http_api_lua",
	"register_sscsm", "get_globals_to_transfer",
	-- Found by the feature sweep of 2026-09-15 rather than by a game asking
	-- for one: every documented core.* this does not implement is here now,
	-- so that a mod calling one gets a line naming the feature instead of
	-- "attempt to call a nil value", and the next sweep finds it by reading
	-- a log. A directory copied, moved or removed is also a decision about
	-- what a downloaded game may do to the user's disk, which is why these
	-- three are a stub and not four lines of implementation.
	"cpdir", "mvdir", "rmdir", "save_gen_notify",
}

for _, name in ipairs(STUBS_NIL) do
	stub(name, nil)
end

-- **Kicks and bans are the server's accounts'** ([VANILLA_PUBLIC] 4): a
-- ban is of the account and of the address it last joined from, and an
-- admin sees and lifts it on the Users page as well as with /unban.
-- simplified: reconnect (a kick's "join again") is not said to the client
function core.kick_player(name, reason)
	return __luanti_accounts("kick", name, reason or "") == ""
end
core.disconnect_player = core.kick_player

function core.ban_player(name)
	local why = __luanti_accounts("ban", name)
	if why ~= "" then
		core.log("action", "ban_player(" .. tostring(name) .. "): " .. why)
	end
	return why == ""
end

function core.unban_player_or_ip(name_or_ip)
	return __luanti_accounts("unban", name_or_ip) == ""
end

function core.get_ban_list()
	return __luanti_accounts("ban_list")
end

-- The bans that name the account or the address, as get_ban_list says
-- them
function core.get_ban_description(name_or_ip)
	local out = {}
	for ban in core.get_ban_list():gmatch("[^,]+") do
		ban = ban:match("^%s*(.-)%s*$")
		-- "name|address", or the name alone for a ban of the account
		local n, ip = ban:match("^([^|]*)|?(.*)$")
		if n == name_or_ip or ip == name_or_ip then
			out[#out + 1] = ban
		end
	end
	return table.concat(out, ", ")
end

function core.get_player_ip(name)
	local ip = __luanti_accounts("ip", name)
	return ip ~= "" and ip or nil
end

-- A mod channel with nobody on the other end: no client here speaks the
-- channel protocol, so what is sent is dropped, and what a mod keeps is
-- the object -- mcl_sprint calls channel:send_all() on the one it
-- joined at login, and a nil there ended a respawn. Luanti's is_writeable
-- answers whether the channel is joined, which this always is.
local ModChannel = {}
ModChannel.__index = ModChannel
function ModChannel:leave() self.joined = false end
function ModChannel:is_writeable() return self.joined end
function ModChannel:send_all(message) return self.joined end
function core.mod_channel_join(name)
	return setmetatable({name = tostring(name), joined = true}, ModChannel)
end

-- core.get_node_boxes(box_type, pos, node) -> {{x1,y1,z1,x2,y2,z2}, ...}
--
-- A node's real shape, which a mod reasoning about collision or selection
-- asks for (VoxeLibre's mob spawning, its line of sight). The box of the
-- type asked for, falling back as Luanti does: collision_box -> node_box,
-- selection_box -> node_box, and a nodebox-less node is the whole cube.
-- "fixed" as given; "regular" the cube; "leveled" the cube up to param2
-- sixty-fourths; "wallmounted" the wall_* box the param2 picks;
-- "connected" the fixed part and each connect_* side whose neighbour is
-- one of connects_to (or solid, the fence's rule). Boxes are turned by
-- a facedir/4dir param2 about y, which is what a stair or a slab asks
-- for; simplified: the facedir's other 20 orientations (a node on its
-- side) are answered unturned.
-- BEGIN get_node_boxes (builtin/luanti/test/node_boxes.lua runs this span alone)
local function rotate_box_y(b, turns)
	local x1, y1, z1, x2, y2, z2 = b[1], b[2], b[3], b[4], b[5], b[6]
	for _ = 1, turns % 4 do
		-- Luanti's facedir 1 is rotateXZBy(-90): (x, z) -> (z, -x); the
		-- box's corners re-sorted, since a rotated min is not a min
		x1, z1, x2, z2 = z1, -x2, z2, -x1
	end
	return {x1, y1, z1, x2, y2, z2}
end

local function box_list(boxes)
	if type(boxes) ~= "table" then
		return {}
	end
	if type(boxes[1]) == "number" then
		return {{boxes[1], boxes[2], boxes[3], boxes[4], boxes[5], boxes[6]}}
	end
	local out = {}
	for _, b in ipairs(boxes) do
		if type(b) == "table" and #b >= 6 then
			out[#out + 1] = {b[1], b[2], b[3], b[4], b[5], b[6]}
		end
	end
	return out
end

local CUBE = {{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}}
local WALLMOUNTED_KEYS = {[0] = "wall_top", "wall_bottom", "wall_side",
		"wall_side", "wall_side", "wall_side"}
local CONNECT_SIDES = {
	{key = "connect_top", d = {x = 0, y = 1, z = 0}},
	{key = "connect_bottom", d = {x = 0, y = -1, z = 0}},
	{key = "connect_front", d = {x = 0, y = 0, z = -1}},
	{key = "connect_left", d = {x = -1, y = 0, z = 0}},
	{key = "connect_back", d = {x = 0, y = 0, z = 1}},
	{key = "connect_right", d = {x = 1, y = 0, z = 0}},
}

local function connects(def, other_name)
	local odef = core.registered_nodes[other_name]
	if not odef then
		return false
	end
	for _, want in ipairs(def.connects_to or {}) do
		if want == other_name then
			return true
		end
		local g = want:match("^group:(.+)$")
		if g and (odef.groups or {})[g] and odef.groups[g] > 0 then
			return true
		end
	end
	return false
end

function core.get_node_boxes(box_type, pos, node)
	node = node or core.get_node(pos)
	local def = core.registered_nodes[node.name]
	if not def then
		return {}
	end
	local box = nil
	if box_type == "collision_box" then
		box = def.collision_box or def.node_box
	elseif box_type == "selection_box" then
		box = def.selection_box or def.node_box
	else
		box = def.node_box
	end
	if type(box) ~= "table" then
		if def.drawtype == "nodebox" or def.drawtype == "mesh" then
			return {}
		end
		return {CUBE[1]}
	end
	local p2 = node.param2 or 0
	local out
	if box.type == "regular" then
		out = {CUBE[1]}
	elseif box.type == "leveled" then
		local h = -0.5 + math.max(0, math.min(64, p2)) / 64
		out = {{-0.5, -0.5, -0.5, 0.5, h, 0.5}}
	elseif box.type == "wallmounted" then
		local key = WALLMOUNTED_KEYS[p2 % 8] or "wall_side"
		out = box_list(box[key] or box.wall_side)
		if key == "wall_side" then
			-- The side boxes are given for the -x wall (Luanti's
			-- transformNodeBox: +x turned 180, -z +90, +z -90; a turn
			-- here is -90): param2 2 +x, 3 -x, 4 +z, 5 -z
			local turns = ({[2] = 2, [3] = 0, [4] = 1, [5] = 3})[p2 % 8] or 0
			for i, b in ipairs(out) do
				out[i] = rotate_box_y(b, turns)
			end
		end
		return out
	elseif box.type == "connected" then
		out = box_list(box.fixed)
		for _, side in ipairs(CONNECT_SIDES) do
			local n = core.get_node({x = pos.x + side.d.x, y = pos.y + side.d.y,
					z = pos.z + side.d.z})
			if connects(def, n.name) then
				for _, b in ipairs(box_list(box[side.key])) do
					out[#out + 1] = b
				end
			else
				for _, b in ipairs(box_list(box["dis" .. side.key])) do
					out[#out + 1] = b
				end
			end
		end
		return out
	else
		out = box_list(box.fixed)
	end
	local ptype = def.paramtype2 or ""
	if ptype == "facedir" or ptype == "colorfacedir" then
		local fd = p2 % 32
		if ptype == "colorfacedir" then
			fd = p2 % 32
		end
		if fd < 4 then
			for i, b in ipairs(out) do
				out[i] = rotate_box_y(b, fd)
			end
		end
	elseif ptype == "4dir" or ptype == "color4dir" then
		for i, b in ipairs(out) do
			out[i] = rotate_box_y(b, p2 % 4)
		end
	end
	return out
end
-- END get_node_boxes

-- The two an object is in, which lua/entity.lua fills: tables rather than
-- functions, because indexing a function is an error and a mod that only
-- looks should not be broken by what it finds
core.object_refs = {}
core.luaentities = {}

-- The few whose nil would take a caller down where an empty one will not
-- The mapgen registrations are recorded rather than stubbed. The handles
-- are indices, which is what Luanti's are.
core.registered_biomes = {}
core.registered_ores = {}
core.registered_decorations = {}

-- What a registration answered with, by the name the definition carried:
-- Luanti hands back a handle and a mod asks for it again by name later, as
-- VoxeLibre's mapgen mod does for every decoration it wants to hear about.
core.__mapgen_handles = {biome = {}, ore = {}, decoration = {}}

-- What the mapgen is built from is this module's own record, in the order
-- they came: the public table is the game's to change, and a change there
-- does not reach Luanti's managers either. Walked out of the public one,
-- VoxeLibre's decorations crossed in another order, the numbers gennotify
-- reports named other decorations, and every structure was a shipwreck.
core.__mapgen_registered = {biome = {}, ore = {}, decoration = {}}

local function recording_registration(kind)
	local list = core["registered_" .. kind .. "s"]
	local own = core.__mapgen_registered[kind]
	local handles = core.__mapgen_handles[kind]
	core["register_" .. kind] = function(def)
		own[#own + 1] = def
		-- By name, as Luanti's builtin keys it (make_registration_wrap):
		-- VoxeLibre reads registered_biomes[name]
		if def.name ~= nil then
			list[def.name] = def
		else
			list[#own] = def
		end
		if def.name ~= nil and def.name ~= "" then
			handles[def.name] = #own
		end
		return #own
	end
	core["clear_registered_" .. kind .. "s"] = function()
		for i = #own, 1, -1 do
			own[i] = nil
		end
		for k in pairs(list) do
			list[k] = nil
		end
		for k in pairs(handles) do
			handles[k] = nil
		end
	end
end

recording_registration("biome")
recording_registration("ore")
recording_registration("decoration")
-- The schematics a mod built in Lua and handed over, by the handle it was
-- given. Luanti keeps them in its SchematicManager and answers with an
-- integer; what uses one is a decoration, which resolves it in
-- schematic_of() above.
--
-- simplified: a handle is an index into this list and means nothing outside
-- this server, which is what Luanti's own ObjDefHandle is as well. What is
-- not here is core.place_schematic() and the rest of the family -- a
-- registered schematic is placed by the mapgen and not by a mod, so far.
core.__registered_schematics = {}

function core.register_schematic(schematic, replacements)
	if type(schematic) ~= "table" then
		-- A file name is already usable as it is, and a handle is one
		-- already; neither wants keeping
		return schematic
	end
	local n = #core.__registered_schematics + 1
	core.__registered_schematics[n] = {
		schematic = schematic,
		replacements = replacements,
	}
	return n
end

function core.clear_registered_schematics()
	core.__registered_schematics = {}
end
-- A schematic read into the table form, which is what read_schematic()
-- answers with and what a mod builds by hand: {size, yslice_prob, data},
-- data x fastest then y then z, one {name, prob, param2, force_place}
-- per node. A .mts file is 'MTSM', u16 version, u16 x y z, a u8 per y
-- slice (version 3 up), u16 names each as u16 length and bytes, then a
-- zlib stream of u16 ids, u8 param1 and u8 param2 for every node --
-- builtin/luanti_mapgen/vendor/mg_schematic.cpp reads the same bytes.
local PROB_ALWAYS = 0x7F
local FORCE_PLACE = 0x80

local function be16(str, i)
	local a, b = str:byte(i, i + 1)
	return a * 256 + b
end

local function read_mts(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local str = f:read("*a")
	f:close()
	if str:sub(1, 4) ~= "MTSM" then
		return nil
	end
	local version = be16(str, 5)
	local sx, sy, sz = be16(str, 7), be16(str, 9), be16(str, 11)
	local i = 13
	local yslice_prob = {}
	for y = 0, sy - 1 do
		local prob = PROB_ALWAYS
		if version >= 3 then
			prob = str:byte(i)
			i = i + 1
		end
		-- Twice the file's byte, as Luanti's read_schematic hands it out
		yslice_prob[#yslice_prob + 1] = {ypos = y, prob = (prob % 128) * 2}
	end
	local n_names = be16(str, i)
	i = i + 2
	local names = {}
	for k = 1, n_names do
		local len = be16(str, i)
		local name = str:sub(i + 2, i + 1 + len)
		-- A v1 "ignore" is air that is never placed
		names[k] = name == "ignore" and "air" or name
		i = i + 2 + len
	end
	local n = sx * sy * sz
	local raw = core.decompress(str:sub(i), "deflate")
	if not raw or #raw < n * 4 then
		return nil
	end
	local data = {}
	for k = 1, n do
		local id = be16(raw, k * 2 - 1)
		local p1 = raw:byte(n * 2 + k)
		local p2 = raw:byte(n * 3 + k)
		data[k] = {name = names[id + 1] or "air", param2 = p2,
				prob = p1 % 128 == PROB_ALWAYS and 255 or (p1 % 128) * 2,
				force_place = p1 >= FORCE_PLACE}
	end
	return {size = {x = sx, y = sy, z = sz}, yslice_prob = yslice_prob,
			data = data}
end

-- A cache by path: a village places the same house many times over
local mts_cache = {}
local function schematic_table(sch)
	if type(sch) == "number" then
		local kept = core.__registered_schematics[sch]
		sch = kept and kept.schematic
	end
	if type(sch) == "table" then
		return sch
	end
	if type(sch) ~= "string" then
		return nil
	end
	local have = mts_cache[sch]
	if have == nil then
		have = read_mts(sch) or false
		mts_cache[sch] = have
	end
	return have or nil
end

function core.read_schematic(schematic, options)
	local t = schematic_table(schematic)
	if not t then
		return nil
	end
	-- Handed out as a copy, since a mod edits what it is given
	local out = {size = {x = t.size.x, y = t.size.y, z = t.size.z},
			yslice_prob = {}, data = {}}
	for k, v in ipairs(t.yslice_prob) do
		out.yslice_prob[k] = {ypos = v.ypos, prob = v.prob}
	end
	for k, v in ipairs(t.data) do
		out.data[k] = {name = v.name, param2 = v.param2, prob = v.prob,
				force_place = v.force_place}
	end
	return out
end

-- The bytes of a .mts for a {size, yslice_prob, data} table: read_mts's
-- layout backwards (version 4, a prob byte per y slice, the names, then
-- the deflated ids, param1s and param2s)
local function write_mts(t)
	local function u16(n)
		return string.char(math.floor(n / 256) % 256, n % 256)
	end
	local sx, sy, sz = t.size.x, t.size.y, t.size.z
	local n = sx * sy * sz
	local out = {"MTSM", u16(4), u16(sx), u16(sy), u16(sz)}
	local slice = {}
	for _, v in ipairs(t.yslice_prob or {}) do
		slice[v.ypos] = v.prob
	end
	for y = 0, sy - 1 do
		local p = slice[y]
		out[#out + 1] = string.char(p == nil and PROB_ALWAYS or
				math.min(PROB_ALWAYS, math.floor(p / 2)))
	end
	local names, ids = {}, {}
	local id_bytes, p1_bytes, p2_bytes = {}, {}, {}
	for k = 1, n do
		local v = t.data[k] or {name = "air"}
		local name = v.name or "air"
		local id = ids[name]
		if id == nil then
			id = #names
			names[#names + 1] = name
			ids[name] = id
		end
		id_bytes[k] = u16(id)
		local prob = v.prob == nil and 255 or v.prob
		local p1 = prob >= 255 and PROB_ALWAYS or math.floor(prob / 2)
		if v.force_place then
			p1 = p1 + FORCE_PLACE
		end
		p1_bytes[k] = string.char(p1)
		p2_bytes[k] = string.char((v.param2 or 0) % 256)
	end
	out[#out + 1] = u16(#names)
	for _, name in ipairs(names) do
		out[#out + 1] = u16(#name) .. name
	end
	out[#out + 1] = core.compress(table.concat(id_bytes) ..
			table.concat(p1_bytes) .. table.concat(p2_bytes), "deflate")
	return table.concat(out)
end

-- core.create_schematic(p1, p2, probability_list, filename, slice_prob_list):
-- the box of the map as a .mts file, each listed node's prob (0-255, with
-- 128 added for a per-node force place, which is the file's own byte) and
-- each listed y slice's; true when written
function core.create_schematic(p1, p2, probability_list, filename, slice_prob_list)
	local function xyz(p)
		return math.floor(p.x), math.floor(p.y), math.floor(p.z)
	end
	local x1, y1, z1 = xyz(p1)
	local x2, y2, z2 = xyz(p2)
	x1, x2 = math.min(x1, x2), math.max(x1, x2)
	y1, y2 = math.min(y1, y2), math.max(y1, y2)
	z1, z2 = math.min(z1, z2), math.max(z1, z2)
	local probs = {}
	for _, e in ipairs(probability_list or {}) do
		local x, y, z = xyz(e.pos)
		if x >= x1 and x <= x2 and y >= y1 and y <= y2 and z >= z1 and z <= z2 then
			probs[(z - z1) * (y2 - y1 + 1) * (x2 - x1 + 1) +
					(y - y1) * (x2 - x1 + 1) + (x - x1) + 1] = e.prob
		end
	end
	local data = {}
	for z = z1, z2 do
		for y = y1, y2 do
			for x = x1, x2 do
				local node = core.get_node({x = x, y = y, z = z})
				local k = #data + 1
				local p = probs[k]
				data[k] = {name = node.name, param2 = node.param2,
						prob = p and (p % 128) * 2 or 255,
						force_place = p ~= nil and p >= 128}
			end
		end
	end
	local yslice_prob = {}
	for _, e in ipairs(slice_prob_list or {}) do
		yslice_prob[#yslice_prob + 1] = {ypos = e.ypos, prob = e.prob}
	end
	return core.safe_file_write(filename, write_mts({
			size = {x = x2 - x1 + 1, y = y2 - y1 + 1, z = z2 - z1 + 1},
			yslice_prob = yslice_prob, data = data}))
end

-- The "lua" format, which is the one a mod parses back, and "mts", the
-- file's bytes
function core.serialize_schematic(schematic, format, options)
	if format == "mts" then
		local t = core.read_schematic(schematic)
		return t and write_mts(t) or nil
	end
	if format ~= "lua" then
		return nil
	end
	local t = core.read_schematic(schematic)
	if not t then
		return nil
	end
	-- Written out plainly, since a mod does `loadstring(s .. " return
	-- schematic")()` and core.serialize() starts with a local
	local out = {"schematic = {size = {x=" .. t.size.x .. ", y=" ..
			t.size.y .. ", z=" .. t.size.z .. "}, yslice_prob = {"}
	for _, v in ipairs(t.yslice_prob) do
		out[#out + 1] = "{ypos=" .. v.ypos .. ", prob=" .. v.prob .. "},"
	end
	out[#out + 1] = "}, data = {"
	for _, v in ipairs(t.data) do
		out[#out + 1] = string.format("{name=%q, prob=%d, param2=%d%s},",
				v.name, v.prob or 255, v.param2 or 0,
				v.force_place and ", force_place=true" or "")
	end
	out[#out + 1] = "}}"
	return table.concat(out, "\n")
end

-- simplified: a rotated node keeps its param2 unless it is an upright
-- facedir, whose facing turns with the schematic; wallmounted and the
-- other facedir axes would need nodedef.cpp's rotateAlongYAxis tables.
local function rotate_param2(name, param2, rot)
	if rot == 0 then
		return param2
	end
	local def = core.registered_nodes[name]
	local pt2 = def and def.paramtype2
	if (pt2 == "facedir" or pt2 == "colorfacedir" or pt2 == "4dir" or
			pt2 == "color4dir") and math.floor(param2 % 32 / 4) == 0 then
		local high = param2 - param2 % 4
		return high + (param2 % 4 + rot) % 4
	end
	return param2
end

-- What place_schematic() and place_schematic_on_vmanip() share: every node
-- of the schematic through `put(pos, node)`, with the rotation, the
-- replacements, the probabilities and the centering flags applied the
-- way mg_schematic.cpp's blitToVManip and placeOnVManip apply them.
-- `occupied(pos)` says whether a node is already there for the
-- force_placement rule.
local function blit_schematic(sch, pos, rotation, replacements,
		force_placement, flags, put, occupied)
	local t = schematic_table(sch)
	if not t then
		return false
	end
	if type(sch) == "number" then
		local kept = core.__registered_schematics[sch]
		local merged = {}
		for from, to in pairs(kept and kept.replacements or {}) do
			merged[from] = to
		end
		for from, to in pairs(replacements or {}) do
			merged[from] = to
		end
		replacements = merged
	end
	replacements = replacements or {}
	local rot = ({["0"] = 0, ["90"] = 1, ["180"] = 2, ["270"] = 3})[
			tostring(rotation or "0")]
	if rotation == "random" or rot == nil then
		rot = math.random(0, 3)
	end
	local sx, sy, sz = t.size.x, t.size.y, t.size.z
	local ex, ez = sx, sz
	if rot == 1 or rot == 3 then
		ex, ez = sz, sx
	end
	local p = {x = math.floor(pos.x), y = math.floor(pos.y),
			z = math.floor(pos.z)}
	-- A string, or a table of flag = true, the way Luanti's read_flags
	-- takes either
	local function flag(f)
		if type(flags) == "table" then
			return flags[f] == true
		end
		return type(flags) == "string" and flags:find(f) ~= nil
	end
	if flag("place_center_x") then
		p.x = p.x - math.floor((ex - 1) / 2)
	end
	if flag("place_center_y") then
		p.y = p.y - math.floor((sy - 1) / 2)
	end
	if flag("place_center_z") then
		p.z = p.z - math.floor((ez - 1) / 2)
	end
	local ystride, zstride = sx, sx * sy
	-- Where the schematic's own x and z go when it is turned, as a
	-- start index and a step per axis
	local i_start, step_x, step_z
	if rot == 1 then
		i_start, step_x, step_z = sx - 1, zstride, -1
	elseif rot == 2 then
		i_start, step_x, step_z = zstride * (sz - 1) + sx - 1, -1, -zstride
	elseif rot == 3 then
		i_start, step_x, step_z = zstride * (sz - 1), -zstride, 1
	else
		i_start, step_x, step_z = 0, 1, zstride
	end
	for y = 0, sy - 1 do
		local slice = t.yslice_prob[y + 1]
		local sprob = slice and slice.prob or 255
		-- 254 is what the file's always-byte reads out as, twice 0x7F
		if sprob == PROB_ALWAYS or sprob >= 254 then
			sprob = 255
		end
		if sprob >= 255 or sprob > math.random(1, 255) then
			for z = 0, ez - 1 do
				local i = z * step_z + y * ystride + i_start
				for x = 0, ex - 1 do
					local node = t.data[i + 1]
					local prob = node and (node.prob or 255) or 0
					if prob == PROB_ALWAYS or prob >= 254 then
						prob = 255
					end
					if node and prob > 0 and node.name ~= "ignore" and
							(prob >= 255 or prob > math.random(1, 255)) then
						local at = {x = p.x + x, y = p.y + y, z = p.z + z}
						if force_placement or node.force_place or
								not occupied(at) then
							local name = replacements[node.name] or node.name
							put(at, {name = name, param2 = rotate_param2(
									name, node.param2 or 0, rot)})
						end
					end
					i = i + step_x
				end
			end
		end
	end
	return true
end

-- No callbacks and no per-node reads, the way Luanti's own is: what is
-- there is read once as a VoxelManip of the box, and the writes go
-- through the buffer as one batch. Through set_node() each node read
-- first, and a read flushes the buffer -- a commit with the skylight
-- per node of every village.
function core.place_schematic(pos, schematic, rotation, replacements,
		force_placement, flags)
	local t = schematic_table(schematic)
	if not t then
		return false
	end
	local span = math.max(t.size.x, t.size.z)
	local p1 = {x = math.floor(pos.x) - span, y = math.floor(pos.y) - t.size.y,
			z = math.floor(pos.z) - span}
	local p2 = {x = math.floor(pos.x) + span, y = math.floor(pos.y) + t.size.y,
			z = math.floor(pos.z) + span}
	local vm = VoxelManip(p1, p2)
	return blit_schematic(schematic, pos, rotation, replacements,
			force_placement, flags,
			function(at, node)
				-- swap_node: the buffered write with no callbacks and no
				-- read; it is defined below this, so it is looked up here
				core.swap_node(at, node)
			end,
			function(at)
				local name = vm:get_node_at(at).name
				return name ~= "air" and name ~= "ignore"
			end)
end

function core.place_schematic_on_vmanip(vmanip, pos, schematic, rotation,
		replacements, force_placement, flags)
	return blit_schematic(schematic, pos, rotation, replacements,
			force_placement, flags,
			function(at, node)
				vmanip:set_node_at(at, node)
			end,
			function(at)
				local name = vmanip:get_node_at(at).name
				return name ~= "air" and name ~= "ignore"
			end)
end
-- vim: set noet ts=4 sw=4:
