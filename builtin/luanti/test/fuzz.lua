-- [AUTO_PLAYTEST] part 1: the server half of a fuzz run. The client walks
-- at random (fuzz.sh writes the command file from a seed); this asserts
-- what must hold whatever it does, once a second, and logs one line per
-- second for the runner to read afterwards:
--
--   fuzz: t=12 pos=(1,8,-3) moved=14.2 hp=20 dug=3 placed=1 picked=2 trees=17 objs=4
--
-- and `fuzz: FAILED <why>` on the first invariant that breaks. No oracle:
-- the two engines diverge within seconds under physics at the frame rate,
-- so a long run is comparable to nothing but its own invariants.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=fuzz \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/fuzz.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- The world is left running -- ABMs, LBMs, the clock, mobs -- because a
-- long run is what meets the faults a frozen one cannot.

-- The world is the seed's: fuzz.sh prepends `rawset(_G, "FUZZ_SEED", n)`
-- and this file runs before the module reads the seed, so fixed_map_seed
-- is what a new save takes. A save that has a seed keeps it.
local seed = rawget(_G, "FUZZ_SEED")
if seed then
	core.settings:set("fixed_map_seed", tostring(seed))
end

local dug, placed, picked = 0, 0, 0

core.register_on_dignode(function(pos, node, digger)
	dug = dug + 1
end)
core.register_on_placenode(function(pos, node, placer)
	placed = placed + 1
end)
core.register_on_item_pickup(function(itemstack, picker)
	picked = picked + 1
end)

-- An entity within reach that was healthy a second ago is not gone now:
-- [PUNCH_VANISH]. Punches are not hooked -- a mob's on_punch is its own --
-- so the sample is every object within four nodes, remembered with the
-- health it had. A mob killed by punching runs its health down first; one
-- removed at full health vanished. VoxeLibre keeps health on the
-- luaentity; a game without one is read through the engine's hp.
local watched = {}
local function health_of(obj)
	local le = obj:get_luaentity()
	return (le and tonumber(le.health)) or obj:get_hp()
end
local function punch_watch(player)
	local near = {}
	for _, obj in ipairs(core.get_objects_inside_radius(player:get_pos(), 4)) do
		if not obj:is_player() then
			near[obj] = health_of(obj)
		end
	end
	local why
	for obj, health in pairs(watched) do
		-- get_pos() is nil for a removed object and a position for one
		-- that walked away
		if near[obj] == nil and obj:get_pos() == nil and health > 2 then
			why = "an entity within reach was removed at health " .. health
		end
	end
	watched = near
	return why
end

core.register_on_joinplayer(function(player)
	local t = 0
	local start = player:get_pos()
	local moved = 0
	local last = start
	local failed = false
	local function fail(why)
		if failed then
			return
		end
		failed = true
		core.log("action", "fuzz: FAILED " .. why)
	end
	local function tick()
		if not player:is_player() then
			return
		end
		t = t + 1
		local pos = player:get_pos()
		moved = moved + vector.distance(last, pos)
		last = pos
		local trees = 0
		if t % 10 == 0 then
			local _, counts = core.find_nodes_in_area(
					vector.subtract(start, 40), vector.add(start, 40),
					{"group:tree"})
			for _, n in pairs(counts) do
				trees = trees + n
			end
			-- [NO_TREES]: a VoxeLibre world with grass and no trees
			if trees == 0 and core.get_modpath("mcl_core") then
				fail("no group:tree within 40 nodes of spawn")
			end
		end
		local hp = player:get_hp()
		if hp <= 0 then
			fail("the player died at t=" .. t)
		end
		-- After a minute a random walk has gone somewhere; a player who
		-- has not is a client whose keys never arrived ([HELD_KEY_FLAKE])
		if t == 60 and moved < 5 then
			fail("the player did not move in a minute")
		end
		if t >= 20 and dug == 0 and t % 60 == 0 then
			core.log("warning", "fuzz: nothing dug yet at t=" .. t)
		end
		-- A dug node became an item the player holds. handle_node_drops
		-- puts it straight into the inventory when there is room, so the
		-- pickup hook is for what was dropped and the inventory is the
		-- check: two dug and an empty inventory a minute later is the
		-- drop path
		if dug >= 2 and t % 60 == 0 then
			local inv = player:get_inventory()
			if inv and inv:is_empty("main") then
				fail("dug " .. dug .. " nodes and holds nothing")
			end
		end
		local why = punch_watch(player)
		if why then
			fail(why)
		end
		local objs = #core.get_objects_inside_radius(pos, 16)
		core.log("action", string.format(
				"fuzz: t=%d pos=%s moved=%.1f hp=%d dug=%d placed=%d " ..
				"picked=%d trees=%d objs=%d", t,
				core.pos_to_string(vector.round(pos)), moved, hp, dug, placed,
				picked, trees, objs))
		core.after(1, tick)
	end
	core.after(5, tick)
end)
