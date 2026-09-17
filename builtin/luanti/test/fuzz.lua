-- [AUTO_PLAYTEST] part 1: the server half of a fuzz run. The client walks
-- at random (fuzz.sh writes the command file from a seed); this asserts
-- what must hold whatever it does, once a second, and logs one line per
-- second for the runner to read afterwards:
--
--   fuzz: t=12 pos=(1,8,-3) moved=14.2 hp=20 dug=3 placed=1 picked=2 trees=17 objs=4 step=0.08 over=0
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
-- The step ceiling ([STEP_PEAK]): warned over the first, failed over the
-- second. `over` counts the seconds the peak was over the ceiling.
local STEP_CEILING_S, STEP_FAIL_S = 0.25, 1.0
local over = 0
-- How many seconds each nearby section has been loaded and ungenerated
local ungenerated_for = {}

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
			-- [NO_TREES]: a VoxeLibre world with grass and no trees. A
			-- mushroom island has huge mushrooms where a forest has trees
			-- (seed 3 spawns on one), and both are schematic decorations,
			-- which is the mechanism the fault was in.
			local _, counts = core.find_nodes_in_area(
					vector.subtract(start, 40), vector.add(start, 40),
					{"group:tree", "group:huge_mushroom"})
			for _, n in pairs(counts) do
				trees = trees + n
			end
			if trees == 0 and core.get_modpath("mcl_core") then
				fail("no group:tree or huge mushroom within 40 nodes of spawn")
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
		-- No loaded section near the player stays ungenerated: one that
		-- does is a hole in the world ([UNGENERATED_SAVED]). Thirty
		-- seconds is longer than any emerge seen; the sections within
		-- two of the player's are read once a second.
		local ps = vector.round(pos)
		for dx = -128, 128, 64 do
			for dy = -64, 64, 64 do
				for dz = -128, 128, 64 do
					local x, y, z = ps.x + dx, ps.y + dy, ps.z + dz
					local key = math.floor(x / 64) .. "," ..
							math.floor(y / 64) .. "," .. math.floor(z / 64)
					if __luanti_section_state(x, y, z) == "ungenerated" then
						ungenerated_for[key] = (ungenerated_for[key] or 0) + 1
						if ungenerated_for[key] > 30 then
							fail("section " .. key .. " has been loaded and " ..
									"ungenerated for " .. ungenerated_for[key] ..
									" s")
						end
					else
						ungenerated_for[key] = nil
					end
				end
			end
		end
		-- The server answers inside a second, and normally well inside
		-- it: the step peak since the last check is under STEP_CEILING_S
		-- while the walk interacts, and no step at all is over
		-- STEP_FAIL_S. First cut, argued with in doc/plan/performance_plan.md
		-- under [STEP_PEAK]. The peak is read fresh each tick -- decay
		-- barely moves it in a second -- and a stall is named with its
		-- phase.
		local peak, phase = core.get_server_step_peak()
		if peak > STEP_FAIL_S then
			fail(string.format("a step took %.2f s in %s", peak, phase))
		elseif peak > STEP_CEILING_S and t > 20 then
			core.log("warning", string.format(
					"fuzz: step peak %.2f s in %s at t=%d", peak, phase, t))
			over = over + 1
		end
		local objs = #core.get_objects_inside_radius(pos, 16)
		core.log("action", string.format(
				"fuzz: t=%d pos=%s moved=%.1f hp=%d dug=%d placed=%d " ..
				"picked=%d trees=%d objs=%d step=%.2f over=%d", t,
				core.pos_to_string(vector.round(pos)), moved, hp, dug, placed,
				picked, trees, objs, peak, over))
		core.after(1, tick)
	end
	core.after(5, tick)
end)
