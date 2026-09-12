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

core.log("action", "floor: placed a " .. (HALF * 2 + 1) .. "x" ..
		(HALF * 2 + 1) .. " floor")
