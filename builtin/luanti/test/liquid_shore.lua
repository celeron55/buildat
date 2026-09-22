-- [WATER_LIGHT] 3: the stage for liquid_shore.sh -- a pool of source water
-- with a row of flowing water along its edge and open floor beyond, seen
-- from just above the waterline. Luanti's getCornerLevel() answers a corner
-- any source touches with the full height of the voxel; averaging the
-- source in with the flow instead makes the shore sag.
-- Which game's water: the difference the corner rule makes needs a source
-- whose param2 is something of its own -- VoxeLibre's water carries its
-- palette index there, which is what made it read as a variant and be
-- averaged in. devtest's source has no param2 and answered the corner
-- either way.
local function names()
	if core.registered_nodes["mcl_core:water_source"] then
		return "mcl_core:water_source", "mcl_core:water_flowing",
				"mcl_core:stone"
	end
	return "basenodes:water_source", "basenodes:water_flowing",
			"basenodes:stone"
end

-- The same world every run: the platform is at a fixed place, and what is
-- around it is the seed's ([FUZZ_SEED]'s way of saying it). This runs
-- before the module reads the seed.
core.settings:set("fixed_map_seed", "5")

core.register_on_joinplayer(function(player)
	core.settings:set("time_speed", "0")
	core.set_timeofday(0.5)
	core.after(6, function()
		-- A fixed place, not the player's spawn: two clients join at two
		-- spawns and would be shot against two different landscapes
		local base = {x = 100, y = 120, z = 100}
		local SOURCE, FLOWING, STONE = names()
		local function set(dx, dy, dz, name, param2)
			core.set_node({x = base.x + dx, y = base.y + dy,
					z = base.z + dz}, {name = name, param2 = param2})
		end
		for dz = -8, 10 do
			for dx = -8, 8 do
				for dy = -1, 6 do
					set(dx, dy, dz, dy == -1 and STONE or "air")
				end
			end
		end
		-- The pool, and the flowing row along its near edge
		for dz = 1, 8 do
			for dx = -8, 8 do
				set(dx, 0, dz, SOURCE)
			end
		end
		for dx = -8, 8 do
			set(dx, 0, 0, FLOWING, 3)
		end
		-- Just above the water on the dry side, looking across the
		-- waterline: the flowing row and the pool behind it are then the
		-- same surface at the same angle, which is what makes the shore's
		-- shape and the two rows' brightness both readable
		player:set_pos({x = base.x + 0.5, y = base.y + 1.2,
				z = base.z - 3.0})
		player:set_look_horizontal(0)
		player:set_look_vertical(math.rad(12))
		core.log("action", "liquid_shore: the pool is placed")
		-- Not before the light has settled: a section's relight is
		-- deferred and runs under a budget, and a shot taken while it is
		-- still going is a shot of a dark pool. Two equal readings a few
		-- seconds apart is what says it has finished.
		local last = nil
		local function settle()
			local n = core.get_node({x = base.x, y = base.y, z = base.z + 4})
			local sky = math.floor((n.param1 or 0) % 16)
			if last == sky then
				core.log("action", "liquid_shore: the pool is lit " .. sky)
				core.chat_send_all("liquid_shore: ready")
				return
			end
			last = sky
			core.after(4, settle)
		end
		core.after(6, settle)
	end)
end)
