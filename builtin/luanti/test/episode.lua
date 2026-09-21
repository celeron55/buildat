-- [AUTO_PLAYTEST] part 2: a compared episode. The same worldmod runs on
-- official Luanti's server and on this module, builds one well-defined
-- state with server-side API both have, lets the client do one scripted
-- thing for a few seconds, and logs a census the runner (episode.sh) diffs
-- between the two engines:
--
--   episode: ready dig
--   episode: census dig nodes=dirt:24,air:... inv=dirt:1 objs=1
--
-- The state: a 5x5 platform of the game's own dirt in the sky, the player
-- standing on its middle looking straight down, an entity beside them, an
-- empty inventory, ABMs, LBMs and the clock off, every HUD element gone.
-- The names come out of the registry at run time, so one file serves
-- devtest and VoxeLibre. What the client does is episode.sh's command
-- file; what is asserted is the census, never a coordinate.
--
-- EPISODE_NAME picks the episode; "dig" is the first. EPISODE_SECONDS is
-- how long after `ready` the census is taken; episode.sh writes the
-- client's action at `ready`.

local NAME = rawget(_G, "EPISODE_NAME") or "dig"
local SECONDS = tonumber(rawget(_G, "EPISODE_SECONDS")) or 20
-- The episodes in the pool, where gravity stays on and the census reads y
local POOL = {sink = true, swim = true, fall = true, dive = true}
local ORIGIN = {x = 0, y = 120, z = 0}

-- The first registered node whose name says what it is: a game's dirt
-- under any mod prefix, with nothing that is dirt with grass on it
local function node_named(word)
	local found = {}
	for name, def in pairs(core.registered_nodes) do
		if name:find(word, 1, true) and not name:find("with", 1, true)
				and def.drawtype == "normal" then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end

-- The first registered entity that is a mob or an item: something a
-- census can count and a punch can reach
local function some_entity()
	local found = {}
	for name, def in pairs(core.registered_entities) do
		if not name:find("^__builtin") and def.initial_properties and
				def.initial_properties.physical ~= nil then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found[1]
end

local function freeze()
	core.settings:set("time_speed", "0")
	core.settings:set("mobs_spawn", "false")
	for i = #core.registered_abms, 1, -1 do
		core.registered_abms[i] = nil
	end
	for i = #core.registered_lbms, 1, -1 do
		core.registered_lbms[i] = nil
	end
	-- And no entity walks: devtest's bigfoot paces ten nodes through the
	-- player, and where it is when the ray goes down is a matter of
	-- timing on each engine
	for _, def in pairs(core.registered_entities) do
		def.on_step = nil
	end
end
core.register_on_mods_loaded(freeze)

local dirt = nil
-- The game's water source, by name
local water = nil
local function stamp()
	dirt = node_named("dirt")
	local air = core.get_content_id("air")
	local cid = core.get_content_id(dirt)
	local p1 = vector.subtract(ORIGIN, 3)
	local p2 = vector.add(ORIGIN, 3)
	local vm = VoxelManip(p1, p2)
	local emin, emax = vm:get_emerged_area()
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	for i in area:iterp(p1, p2) do
		data[i] = air
	end
	for x = -2, 2 do
		for z = -2, 2 do
			data[area:index(ORIGIN.x + x, ORIGIN.y, ORIGIN.z + z)] = cid
		end
	end
	for name, def in pairs(core.registered_nodes) do
		if def.drawtype == "liquid" and name:find("water", 1, true) and
				(water == nil or name < water) then
			water = name
		end
	end
	if POOL[NAME] then
		-- A pool three deep with dirt walls, the platform its floor, the
		-- game's own water source ([WATER_PARITY]): what the player's body
		-- does in it is what is compared
		local wid = core.get_content_id(water)
		for x = -2, 2 do
			for z = -2, 2 do
				for y = 1, 3 do
					local edge = (x == -2 or x == 2 or z == -2 or z == 2)
					data[area:index(ORIGIN.x + x, ORIGIN.y + y, ORIGIN.z + z)] =
							edge and cid or wid
				end
			end
		end
	end
	vm:set_data(data)
	vm:write_to_map()
end

local function census(player)
	local p1 = vector.subtract(ORIGIN, 3)
	local p2 = vector.add(ORIGIN, 3)
	local names = {}
	for x = p1.x, p2.x do
		for y = p1.y, p2.y do
			for z = p1.z, p2.z do
				local n = core.get_node({x = x, y = y, z = z}).name
				names[n] = (names[n] or 0) + 1
			end
		end
	end
	local parts = {}
	for n, c in pairs(names) do
		parts[#parts + 1] = n .. ":" .. c
	end
	table.sort(parts)
	local inv = {}
	for _, stack in ipairs(player:get_inventory():get_list("main")) do
		if not stack:is_empty() then
			inv[#inv + 1] = stack:get_name() .. ":" .. stack:get_count()
		end
	end
	table.sort(inv)
	-- Objects by name, so a difference says which one: a dropped item
	-- and a mob are not the same "2"
	local objs = {}
	for _, obj in ipairs(core.get_objects_inside_radius(ORIGIN, 10)) do
		if not obj:is_player() then
			local le = obj:get_luaentity()
			local n = le and le.name or "?"
			objs[n] = (objs[n] or 0) + 1
		end
	end
	local olist = {}
	for n, c in pairs(objs) do
		olist[#olist + 1] = n .. ":" .. c
	end
	table.sort(olist)
	local out = "nodes=" .. table.concat(parts, ",") .. " inv=" ..
			table.concat(inv, ",") .. " objs=" .. table.concat(olist, ",")
	if POOL[NAME] then
		-- Where the body ended, a tenth of a node coarse, and the breath:
		-- the pool episodes' measure
		local p = player:get_pos()
		out = out .. string.format(" y=%.1f breath=%d", p.y - ORIGIN.y,
				player:get_breath())
	end
	if NAME == "pour" then
		-- How far the poured source spread: the flowing nodes by level
		-- ([LIQUID_FLOW])
		local levels = {}
		for x = p1.x, p2.x do
			for y = p1.y, p2.y do
				for z = p1.z, p2.z do
					local n = core.get_node({x = x, y = y, z = z})
					local def = core.registered_nodes[n.name]
					if def and def.liquidtype == "flowing" then
						local l = n.param2 % 8
						levels[l] = (levels[l] or 0) + 1
					end
				end
			end
		end
		local parts = {}
		for l = 7, 0, -1 do
			if levels[l] then
				parts[#parts + 1] = l .. ":" .. levels[l]
			end
		end
		out = out .. " levels=" .. table.concat(parts, ",")
	end
	return out
end

core.register_on_joinplayer(function(player)
	core.after(3, function()
		stamp()
		player:get_inventory():set_list("main", {})
		if NAME == "place" then
			-- Ten of the dirt in the first slot, which is what the
			-- launcher's and the extension's hotbar select on join
			player:get_inventory():set_stack("main", 1,
					ItemStack(dirt .. " 10"))
		end
		-- Gravity stays on in the pool: sinking is the measure
		if not POOL[NAME] then
			player:set_physics_override({gravity = 0})
		end
		for id, _ in pairs(player:hud_get_all()) do
			player:hud_remove(id)
		end
		player:hud_set_flags({hotbar = false, healthbar = false,
				breathbar = false, crosshair = false, minimap = false})
		player:set_look_horizontal(0)
		player:set_look_vertical(math.pi / 2)
		-- In the pool's middle, a node under the surface, for the pool
		-- episodes; on the platform otherwise
		-- a node under the surface for sink and swim, four above it for
		-- the fall in
		local drop = NAME == "fall" and 8 or (POOL[NAME] and 2 or 1)
		player:set_pos({x = ORIGIN.x, y = ORIGIN.y + drop, z = ORIGIN.z})
		local ent = some_entity()
		if ent then
			core.add_entity({x = ORIGIN.x + 2, y = ORIGIN.y + 1,
					z = ORIGIN.z}, ent)
		end
		core.log("action", "episode: state " .. NAME .. " dirt=" ..
				tostring(dirt) .. " entity=" .. tostring(ent))
		-- A second for the client to receive the stamp before it acts
		core.after(1, function()
			-- Re-aimed, since the client had a say about the look
			player:set_look_horizontal(0)
			player:set_look_vertical(math.pi / 2)
			core.log("action", "episode: ready " .. NAME)
			if NAME == "pour" then
				-- The game's water source on the platform's middle; the
				-- census counts what it spread to ([LIQUID_FLOW])
				core.set_node({x = ORIGIN.x, y = ORIGIN.y + 1, z = ORIGIN.z},
						{name = water})
			end
			core.after(SECONDS, function()
				if not player:is_player() then
					core.log("action", "episode: FAILED the player left " ..
							"before the census")
					return
				end
				core.log("action", "episode: census " .. NAME .. " " ..
						census(player))
			end)
		end)
	end)
end)
