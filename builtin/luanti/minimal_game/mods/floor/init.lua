-- The smallest thing that proves the module: a node type, and a floor of it.
--
-- A real game would place its terrain from core.register_on_generated, which
-- is a mapgen away. Here the nodes are placed while the mod loads, which
-- works because builtin/luanti's set_node emerges the section it writes into
-- and the write-behind buffer does not reach voxelworld until the world
-- exists a moment later.

-- Mod storage, which is the one thing under the save that nothing had ever
-- called. It is read on the first get_mod_storage() and written through on
-- every set_string(), so what proves it is a value surviving a restart: this
-- counts the runs and says which one this is, and complains if the count
-- comes back as something that is not a number.
--
-- A check in the fixture rather than in lua/check_map.lua because
-- get_mod_storage() needs a mod to be running: outside one there is no
-- current modname and it has nothing to open.
do
	local storage = core.get_mod_storage()
	if not storage then
		error("floor: no mod storage")
	end
	local before = storage:get_string("runs")
	local runs = tonumber(before) or 0
	if before ~= "" and not tonumber(before) then
		error("floor: mod storage gave back " .. tostring(before))
	end
	runs = runs + 1
	storage:set_string("runs", tostring(runs))
	-- Read back through the same object, which is what a mod does next
	if storage:get_string("runs") ~= tostring(runs) then
		error("floor: mod storage did not keep what was set")
	end
	core.log("action", "floor: this world has been opened " .. runs ..
			(runs == 1 and " time" or " times"))
end

core.register_node("floor:stone", {
	description = "Stone",
	tiles = {"floor_stone.png"},
	groups = {cracky = 3},
})

core.register_node("floor:marker", {
	description = "Marker",
	tiles = {"floor_marker.png"},
	groups = {cracky = 3},
})

-- The two drawtypes the module builds shapes for, so that the visual check
-- shows them without a Luanti installation
core.register_node("floor:slab", {
	description = "Slab",
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5},
	},
	tiles = {"floor_stone.png"},
	groups = {cracky = 3},
})

-- A shape that is not symmetric, so that turning it is visible: a step
core.register_node("floor:step", {
	description = "Step",
	drawtype = "nodebox",
	node_box = {
		type = "fixed",
		fixed = {
			{-0.5, -0.5, -0.5, 0.5, 0, 0.5},
			{-0.5, 0, 0, 0.5, 0.5, 0.5},
		},
	},
	tiles = {
		"floor_face_top.png",
		"floor_face_bottom.png",
		"floor_face_side.png",
	},
	paramtype2 = "facedir",
	groups = {cracky = 3},
})

core.register_node("floor:plant", {
	description = "Plant",
	drawtype = "plantlike",
	tiles = {"floor_plant.png"},
	walkable = false,
	sunlight_propagates = true,
	groups = {snappy = 3},
})

core.register_node("floor:glass", {
	description = "Glass",
	drawtype = "glasslike",
	tiles = {"floor_glass.png"},
	sunlight_propagates = true,
	groups = {cracky = 3},
})

core.register_node("floor:leaves", {
	description = "Leaves",
	drawtype = "allfaces",
	tiles = {"floor_leaves.png"},
	groups = {snappy = 3},
})

-- A liquid and its flowing form, which name the same source and are
-- therefore the same liquid to the mesher
core.register_node("floor:water_source", {
	description = "Water",
	drawtype = "liquid",
	tiles = {"floor_water.png"},
	special_tiles = {
		{name = "floor_water.png", backface_culling = false},
		{name = "floor_water.png", backface_culling = true},
	},
	use_texture_alpha = "blend",
	paramtype = "light",
	walkable = false,
	pointable = false,
	liquidtype = "source",
	liquid_alternative_flowing = "floor:water_flowing",
	liquid_alternative_source = "floor:water_source",
	groups = {water = 3, liquid = 3},
})

core.register_node("floor:water_flowing", {
	description = "Flowing Water",
	drawtype = "flowingliquid",
	tiles = {"floor_water.png"},
	special_tiles = {
		{name = "floor_water.png", backface_culling = false},
		{name = "floor_water.png", backface_culling = false},
	},
	use_texture_alpha = "blend",
	paramtype = "light",
	paramtype2 = "flowingliquid",
	walkable = false,
	pointable = false,
	liquidtype = "flowing",
	liquid_alternative_flowing = "floor:water_flowing",
	liquid_alternative_source = "floor:water_source",
	groups = {water = 3, liquid = 3},
})

-- A plant rooted in the cube it stands in, which is drawn as ground with
-- the plant in the voxel above -- and lit by that voxel's light and not the
-- ground's own
core.register_node("floor:rooted", {
	description = "Rooted Plant",
	drawtype = "plantlike_rooted",
	tiles = {"floor_stone.png"},
	special_tiles = {{name = "floor_plant.png"}},
	paramtype = "light",
	groups = {snappy = 3},
})

-- A node that faces a direction, for the twenty-four turns a facedir
-- permutes a cube's six textures into. Three tiles, expanded the way Luanti
-- expands fewer than six: the last one over the rest.
core.register_node("floor:facing", {
	description = "Facing Block",
	tiles = {
		"floor_face_top.png",
		"floor_face_bottom.png",
		"floor_face_side.png",
	},
	paramtype2 = "facedir",
	groups = {cracky = 3},
})

-- One quad, lying whichever way its wallmounted param2 says: a torch leans
-- on the floor and lies flat on a wall, which is not one shape turned
core.register_node("floor:torch", {
	description = "Torch",
	drawtype = "torchlike",
	tiles = {"floor_torch.png"},
	paramtype = "light",
	paramtype2 = "wallmounted",
	walkable = false,
	sunlight_propagates = true,
	groups = {snappy = 3},
})

-- A post that is always there and a pair of bars towards each direction
-- that has something to reach: another fence, or anything solid
core.register_node("floor:fence", {
	description = "Fence",
	drawtype = "fencelike",
	tiles = {"floor_face_side.png"},
	paramtype = "light",
	sunlight_propagates = true,
	groups = {cracky = 3},
})

-- One quad, and which of four tiles it wears and which way it is turned is
-- what its neighbours say: a shape per mask of the four horizontal
-- connections, which is what the mesher's shape_masked is for
core.register_node("floor:rail", {
	description = "Rail",
	drawtype = "raillike",
	tiles = {
		"floor_rail_straight.png",
		"floor_rail_curved.png",
		"floor_rail_junction.png",
		"floor_rail_crossing.png",
	},
	connect_to_raillike = 1,
	paramtype = "light",
	walkable = false,
	sunlight_propagates = true,
	groups = {cracky = 3},
})

-- The callbacks a mod is written around, declared here because a registered
-- definition refuses new keys: register.lua sets __newindex to ignore them,
-- on purpose, so a callback cannot be bolted on afterwards and a check for
-- one has to be where the node is registered.
local probe = {placed = 0, dug = 0, constructed = 0, destructed = 0}

core.register_node("floor:probe", {
	description = "Probe",
	tiles = {"floor_marker.png"},
	groups = {cracky = 3},
	on_construct = function() probe.constructed = probe.constructed + 1 end,
	on_destruct = function() probe.destructed = probe.destructed + 1 end,
	after_place_node = function() probe.placed = probe.placed + 1 end,
	after_dig_node = function() probe.dug = probe.dug + 1 end,
})

-- A rule that runs on every node of a kind forever, which is what a game's
-- growing and burning and decaying are made of. Registered here because the
-- registry freezes once the mods have loaded, so nothing outside a mod can
-- add one; core.__game_check at the end of this file is what drives it.
core.register_node("floor:seed", {
	description = "Seed",
	drawtype = "plantlike",
	tiles = {"floor_plant.png"},
	paramtype = "light",
	walkable = false,
	groups = {snappy = 3},
})

core.register_node("floor:sprout", {
	description = "Sprout",
	drawtype = "plantlike",
	tiles = {"floor_plant.png"},
	paramtype = "light",
	walkable = false,
	visual_scale = 1.4,
	groups = {snappy = 3},
})

-- neighbors is the half that makes this more than a sweep over one name: a
-- seed grows on the ground and one in the air stays a seed
core.register_abm({
	label = "floor: seeds sprout",
	nodenames = {"floor:seed"},
	neighbors = {"floor:stone"},
	interval = 1,
	chance = 1,
	min_y = 1,
	max_y = 1,
	action = function(pos, node)
		core.set_node(pos, {name = "floor:sprout"})
	end,
})

-- The same idea when the map is loaded rather than on a timer: this one
-- only looks, and counts what it was given, because what the check is about
-- is that it ran over the right nodes at all.
local lbm = {seen = 0, wrong = 0}

core.register_lbm({
	name = "floor:count_torches",
	nodenames = {"floor:torch"},
	action = function(pos, node)
		lbm.seen = lbm.seen + 1
		if node.name ~= "floor:torch" then
			lbm.wrong = lbm.wrong + 1
		end
	end,
})

local HALF = 12   -- a 25x25 floor, which is one voxelworld section across
local Y = 0

for x = -HALF, HALF do
	for z = -HALF, HALF do
		core.set_node({x = x, y = Y, z = z}, {name = "floor:stone"})
	end
end

-- Something to tell the axes apart in a screenshot: a short wall along +X and
-- a single block up +Y, in the other colour
for x = 0, 6 do
	core.set_node({x = x, y = Y + 1, z = 0}, {name = "floor:marker"})
end
for y = 1, 4 do
	core.set_node({x = 0, y = Y + y, z = 0}, {name = "floor:marker"})
end

-- One row per drawtype the module builds, along +X beside the marker wall and
-- out of the tower's shadow, so that a screenshot shows what each one is
for x = 1, 6 do
	core.set_node({x = x, y = Y + 1, z = -2}, {name = "floor:slab"})
	core.set_node({x = x, y = Y + 1, z = -4}, {name = "floor:plant"})
end

-- A pane two high, for the faces glass draws against air and does not draw
-- against more of itself
for x = 1, 6 do
	for y = 1, 2 do
		core.set_node({x = x, y = Y + y, z = -6}, {name = "floor:glass"})
	end
end

-- A clump, for the faces leaves draw even against their own kind
for x = 1, 3 do
	for y = 1, 2 do
		for z = -9, -8 do
			core.set_node({x = x, y = Y + y, z = z}, {name = "floor:leaves"})
		end
	end
end

-- A walled pool of sources, for the surface a body of liquid has and the
-- faces it does not draw inside itself
for x = -8, -4 do
	for z = -2, 2 do
		local rim = (x == -8 or x == -4 or z == -2 or z == 2)
		core.set_node({x = x, y = Y + 1, z = z},
				{name = rim and "floor:stone" or "floor:water_source"})
	end
end

-- All twenty-four facedirs in a row, so a screenshot says whether the tables
-- are right: the red top and its white corner give the axis and the turn,
-- and the arrow on the sides gives the rest
for i = 0, 23 do
	core.set_node({x = -2 + i % 6, y = Y + 1, z = 7 + math.floor(i / 6)},
			{name = "floor:facing", param2 = i})
end

-- The same step in the four ways a 4dir turns it, so a screenshot says
-- whether a shape turns with its node
for i = 0, 3 do
	core.set_node({x = -2 + i, y = Y + 1, z = 4},
			{name = "floor:step", param2 = i})
end

-- A torch in each of the six wallmounted directions, standing free so that
-- each one's lean is its own and not a wall's
local TORCHES = 6
for i = 0, 5 do
	core.set_node({x = -2 + i, y = Y + 2, z = 2},
			{name = "floor:torch", param2 = i})
end

-- A fence with a corner in it and one post standing alone, so a screenshot
-- says which bars are drawn and which are not
for x = -8, -5 do
	core.set_node({x = x, y = Y + 1, z = -8}, {name = "floor:fence"})
end
for z = -7, -5 do
	core.set_node({x = -8, y = Y + 1, z = z}, {name = "floor:fence"})
end
core.set_node({x = -4, y = Y + 1, z = -6}, {name = "floor:fence"})

-- A rail run with a corner, a junction and a crossing in it, so a screenshot
-- says whether each mask picks the tile and the turn Luanti picks
for z = -8, -4 do
	core.set_node({x = 8, y = Y + 1, z = z}, {name = "floor:rail"})
end
for x = 6, 10 do
	core.set_node({x = x, y = Y + 1, z = -6}, {name = "floor:rail"})
end
for x = 6, 8 do
	core.set_node({x = x, y = Y + 1, z = -9}, {name = "floor:rail"})
end
core.set_node({x = 6, y = Y + 1, z = -8}, {name = "floor:rail"})

-- Rooted plants set into the floor itself, so the cube reads as ground
for x = -8, -4, 2 do
	core.set_node({x = x, y = Y, z = 8}, {name = "floor:rooted"})
end

-- And a run of flowing water down the levels, for the sloped surface the
-- corner averaging makes of them
for i = 0, 4 do
	core.set_node({x = -8 + i, y = Y + 1, z = 5},
			{name = "floor:water_flowing", param2 = 7 - i})
end

-- Placing and digging with nobody doing them, and the callbacks that go with
-- them: core.place_node() and core.dig_node() hand the work to the vendored
-- builtin's item_place and node_dig, so what this proves is that the builtin
-- reaches a definition's callbacks through this module's map.
do
	local p = {x = 10, y = Y + 1, z = 10}
	core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = "floor:stone"})
	core.set_node(p, {name = "air"})
	probe.placed, probe.dug = 0, 0
	probe.constructed, probe.destructed = 0, 0

	if not core.place_node(p, {name = "floor:probe"}) then
		error("floor: place_node said no")
	end
	if core.get_node(p).name ~= "floor:probe" then
		error("floor: place_node left " .. core.get_node(p).name)
	end
	if probe.placed ~= 1 or probe.constructed ~= 1 then
		error("floor: after_place_node " .. probe.placed ..
				", on_construct " .. probe.constructed)
	end

	if not core.dig_node(p) then
		error("floor: dig_node said no")
	end
	if core.get_node(p).name ~= "air" then
		error("floor: dig_node left " .. core.get_node(p).name)
	end
	if probe.dug ~= 1 or probe.destructed ~= 1 then
		error("floor: after_dig_node " .. probe.dug ..
				", on_destruct " .. probe.destructed)
	end

	-- swap_node is the one that runs neither, which is what it is for
	probe.constructed, probe.destructed = 0, 0
	core.swap_node(p, {name = "floor:probe"})
	if probe.constructed ~= 0 or probe.destructed ~= 0 then
		error("floor: swap_node ran a callback")
	end
	core.set_node(p, {name = "air"})
	core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = "air"})
	core.log("action", "floor: place_node and dig_node run their callbacks")
end

-- Three seeds for the ABM, one for each half of what decides whether it
-- runs: one on the floor, which grows; one off the edge of the floor, which
-- has no floor:stone next to it; and one a voxel above the rule's max_y, on
-- a block of its own so that it is only the height that stops it. All are
-- placed here and looked at in core.__game_check, which lua/check_map.lua
-- calls once the map has been flushed.
local SEED_ON_FLOOR = {x = -10, y = Y + 1, z = -10}
local SEED_IN_AIR = {x = 20, y = Y + 1, z = 20}
local SEED_TOO_HIGH = {x = -9, y = Y + 2, z = -10}

core.set_node(SEED_ON_FLOOR, {name = "floor:seed"})
core.set_node(SEED_IN_AIR, {name = "floor:seed"})
core.set_node({x = SEED_TOO_HIGH.x, y = SEED_TOO_HIGH.y - 1,
		z = SEED_TOO_HIGH.z}, {name = "floor:stone"})
core.set_node(SEED_TOO_HIGH, {name = "floor:seed"})

function core.__game_check()
	-- One step of the ABM's whole interval, so it runs exactly once
	core.__step(1.0)
	local grown = core.get_node(SEED_ON_FLOOR).name
	if grown ~= "floor:sprout" then
		error("floor: the abm left the seed on the floor as " .. grown)
	end
	local kept = core.get_node(SEED_IN_AIR).name
	if kept ~= "floor:seed" then
		error("floor: the abm grew a seed with no floor under it: " .. kept)
	end
	local high = core.get_node(SEED_TOO_HIGH).name
	if high ~= "floor:seed" then
		error("floor: the abm grew a seed above its max_y: " .. high)
	end
	core.log("action", "floor: the abm grew the one seed of three that its " ..
			"neighbors and max_y allowed")

	-- The same step is the one the map was loaded for, so the lbm has run
	if lbm.seen ~= TORCHES or lbm.wrong ~= 0 then
		error("floor: the lbm saw " .. lbm.seen .. " of " .. TORCHES ..
				" torches, " .. lbm.wrong .. " of them something else")
	end
	core.log("action", "floor: the lbm ran over all " .. TORCHES ..
			" torches when the map was loaded")
end

core.log("action", "floor: placed a " .. (HALF * 2 + 1) .. "x" ..
		(HALF * 2 + 1) .. " floor")
