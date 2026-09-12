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

core.log("action", "floor: placed a " .. (HALF * 2 + 1) .. "x" ..
		(HALF * 2 + 1) .. " floor")
