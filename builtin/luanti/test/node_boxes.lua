-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- core.get_node_boxes() against Luanti's own rotations, without a world:
-- the function's span is cut out of lua/bootstrap.lua (between its BEGIN
-- and END marks) and run over a few made-up nodes.
--
--   lua builtin/luanti/test/node_boxes.lua
local dir = arg[0]:match("^(.*)/[^/]*$") or "."
local f = assert(io.open(dir .. "/../lua/bootstrap.lua"))
local src = f:read("*a")
f:close()
local span = src:match("%-%- BEGIN get_node_boxes.-\n(.-)%-%- END get_node_boxes")
assert(span, "the BEGIN/END get_node_boxes marks are gone from bootstrap.lua")

core = {}
core.registered_nodes = {
	["t:stair"] = {drawtype = "nodebox", paramtype2 = "facedir",
		node_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, 0, 0.5}, {-0.5, 0, 0, 0.5, 0.5, 0.5}}}},
	["t:torch"] = {drawtype = "nodebox", paramtype2 = "wallmounted",
		node_box = {type = "wallmounted", wall_top = {-0.1, 0, -0.1, 0.1, 0.5, 0.1},
			wall_bottom = {-0.1, -0.5, -0.1, 0.1, 0, 0.1}, wall_side = {-0.5, -0.3, -0.1, -0.3, 0.3, 0.1}}},
	["t:stone"] = {drawtype = "normal"},
	["t:fence"] = {drawtype = "nodebox", connects_to = {"group:fence"}, groups = {fence = 1},
		node_box = {type = "connected", fixed = {-0.125, -0.5, -0.125, 0.125, 0.5, 0.125},
			connect_right = {0.125, 0, 0, 0.5, 0.2, 0.1}, connect_left = {-0.5, 0, 0, -0.125, 0.2, 0.1}}},
}
local world = {}
function core.get_node(p)
	return world[p.x .. "," .. p.y .. "," .. p.z] or {name = "air", param2 = 0}
end
assert(loadstring or load)(span, "get_node_boxes")()

local function eq(a, b)
	for i = 1, 6 do
		if math.abs(a[i] - b[i]) > 1e-9 then return false end
	end
	return true
end
local p = {x = 0, y = 0, z = 0}
-- A stair's upper half turned as Luanti's transformNodeBox turns it:
-- facedir 1 is rotateXZBy(-90), (x, z) -> (z, -x)
local s0 = core.get_node_boxes("node_box", p, {name = "t:stair", param2 = 0})
assert(#s0 == 2 and eq(s0[2], {-0.5, 0, 0, 0.5, 0.5, 0.5}))
local s1 = core.get_node_boxes("collision_box", p, {name = "t:stair", param2 = 1})
assert(eq(s1[2], {0, 0, -0.5, 0.5, 0.5, 0.5}), table.concat(s1[2], ","))
local s2 = core.get_node_boxes("node_box", p, {name = "t:stair", param2 = 2})
assert(eq(s2[2], {-0.5, 0, -0.5, 0.5, 0.5, 0}), table.concat(s2[2], ","))
-- A torch on the floor, and on the +x wall (the side box turned 180)
assert(eq(core.get_node_boxes("node_box", p, {name = "t:torch", param2 = 1})[1],
		{-0.1, -0.5, -0.1, 0.1, 0, 0.1}))
local t2 = core.get_node_boxes("node_box", p, {name = "t:torch", param2 = 2})[1]
assert(eq(t2, {0.3, -0.3, -0.1, 0.5, 0.3, 0.1}), table.concat(t2, ","))
-- A plain node is the cube, whatever box is asked for
assert(eq(core.get_node_boxes("selection_box", p, {name = "t:stone"})[1],
		{-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}))
-- A fence reaches the fence beside it and not the air
world["1,0,0"] = {name = "t:fence", param2 = 0}
local fb = core.get_node_boxes("node_box", p, {name = "t:fence", param2 = 0})
assert(#fb == 2 and eq(fb[2], {0.125, 0, 0, 0.5, 0.2, 0.1}), #fb)
print("get_node_boxes: ok")
