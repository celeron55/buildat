-- The smallest thing that proves the module: a node type, and a floor of it.
--
-- A real game would place its terrain from core.register_on_generated, which
-- is a mapgen away. Here the nodes are placed while the mod loads, which
-- works because builtin/luanti's set_node emerges the section it writes into
-- and the write-behind buffer does not reach voxelworld until the world
-- exists a moment later.

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

core.log("action", "floor: placed a " .. (HALF * 2 + 1) .. "x" ..
		(HALF * 2 + 1) .. " floor")
