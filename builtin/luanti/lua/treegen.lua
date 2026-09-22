-- Buildat: builtin/luanti/lua/treegen.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The L-system trees: core.spawn_tree(), core.spawn_tree_on_vmanip() and the
-- "lsystem" decoration, which are all one generator with three ways in.
--
-- This is Luanti's own src/mapgen/treegen.cpp written out in Lua, down to
-- the order it asks its PseudoRandom for numbers in: a tree is part of what
-- a world looks like, so the same definition at the same place has to come
-- out the same tree. The turtle's rotation is Irrlicht's own column-major
-- matrix4 with its own multiply, for the same reason.
--
-- The symbols an axiom is written in:
--
--   G  move forward one unit with the pen up
--   F  move forward drawing trunk, and leaves around it inside a branch
--   f  move forward drawing one leaf
--   T  move forward drawing trunk only
--   R  move forward placing fruit
--   A B C D   replace with the rules of that name
--   a b c d   the same, with a 90, 80, 70 and 60 percent chance
--   + -  yaw right and left by the definition's angle
--   & ^  pitch down and up
--   / *  roll right and left
--   [ ]  save and restore where the turtle is and which way it faces

local M = {}

local function identity()
	return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

-- setRotationAxisRadians(): the nine that turn, written into an identity
local function axis_rotation(angle, ax, ay, az)
	local m = identity()
	local c = math.cos(angle)
	local s = math.sin(angle)
	local t = 1.0 - c
	m[1] = t * ax * ax + c
	m[2] = t * ax * ay + s * az
	m[3] = t * ax * az - s * ay
	m[5] = t * ay * ax - s * az
	m[6] = t * ay * ay + c
	m[7] = t * ay * az + s * ax
	m[9] = t * az * ax + s * ay
	m[10] = t * az * ay - s * ax
	m[11] = t * az * az + c
	return m
end

-- a * b, column-major, which is Irrlicht's matrix4 operator*
local function mat_mul(a, b)
	local out = {}
	for j = 0, 3 do
		for i = 0, 3 do
			local v = 0
			for k = 0, 3 do
				v = v + a[i + k * 4 + 1] * b[k + j * 4 + 1]
			end
			out[i + j * 4 + 1] = v
		end
	end
	return out
end

-- transposeMatrix(): the direction the turtle is facing, which is the
-- matrix's own rows rather than its columns
local function transpose_apply(m, x, y, z)
	return m[1] * x + m[5] * y + m[9] * z + m[13],
			m[2] * x + m[6] * y + m[10] * z + m[14],
			m[3] * x + m[7] * y + m[11] * z + m[15]
end

-- C rounds a float to the nearest integer, halves away from zero
local function myround(v)
	return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5)
end

-- The axiom with the rules put in, iterations times over. The lowercase
-- rules are a chance each, and the chance is drawn even when the rule is
-- empty, which is what keeps two trees of one definition the same tree.
local function expand(def, iterations, ps)
	local axiom = def.axiom or ""
	local rules = {A = def.rules_a or "", B = def.rules_b or "",
			C = def.rules_c or "", D = def.rules_d or ""}
	local chance = {a = 9, b = 8, c = 7, d = 6}
	local upper = {a = "A", b = "B", c = "C", d = "D"}
	for _ = 1, iterations do
		local out = {}
		for i = 1, #axiom do
			local ch = string.sub(axiom, i, i)
			if rules[ch] then
				out[#out + 1] = rules[ch]
			elseif chance[ch] then
				if chance[ch] >= ps:next(1, 10) then
					out[#out + 1] = rules[upper[ch]]
				end
			else
				out[#out + 1] = ch
			end
		end
		axiom = table.concat(out)
	end
	return axiom
end

-- What a definition's nodes are called, with Luanti's own defaults for the
-- ones it does not name
local function names_of(def)
	return {
		trunk = def.trunk or "air",
		leaves = def.leaves or "air",
		leaves2 = def.leaves2 or def.leaves or "air",
		fruit = def.fruit or "air",
	}
end

-- The four placements, each with the rule Luanti's own has about what it is
-- allowed to write over. map:get(x, y, z) answers with a node name or nil
-- for a place that is not there, and map:set(x, y, z, name) writes one.
local function place_trunk(map, x, y, z, names)
	local at = map:get(x, y, z)
	if at == nil then
		return
	end
	if at ~= "air" and at ~= "ignore" and at ~= names.leaves and
			at ~= names.leaves2 and at ~= names.fruit then
		return
	end
	map:set(x, y, z, names.trunk)
end

local function leaves_name(def, names, ps)
	if ps:next(1, 100) > 100 - (def.leaves2_chance or 0) then
		return names.leaves2
	end
	return names.leaves
end

-- The shell of leaves a branch's F draws: a fifth of them are left out,
-- which is what makes a tree look grown rather than moulded
local function place_leaves(map, x, y, z, def, names, ps)
	local name = leaves_name(def, names, ps)
	local at = map:get(x, y, z)
	if at == nil or (at ~= "air" and at ~= "ignore") then
		return
	end
	local fruit_chance = def.fruit_chance or 0
	if fruit_chance > 0 then
		if ps:next(1, 100) > 100 - fruit_chance then
			map:set(x, y, z, names.fruit)
		else
			map:set(x, y, z, name)
		end
	elseif ps:next(1, 100) > 20 then
		map:set(x, y, z, name)
	end
end

local function place_single_leaf(map, x, y, z, def, names, ps)
	local name = leaves_name(def, names, ps)
	local at = map:get(x, y, z)
	if at == nil or (at ~= "air" and at ~= "ignore") then
		return
	end
	map:set(x, y, z, name)
end

local function place_fruit(map, x, y, z, names)
	local at = map:get(x, y, z)
	if at == nil or (at ~= "air" and at ~= "ignore") then
		return
	end
	map:set(x, y, z, names.fruit)
end

-- grow(map, p0, def) -> true, or false and why
--
-- The whole of make_ltree(), against whatever map is handed over.
function M.grow(map, p0, def)
	if type(def) ~= "table" then
		return false, "no tree definition"
	end
	local seed
	if def.seed ~= nil then
		seed = def.seed + 14002
	else
		seed = p0.x * 2 + p0.y * 4 + p0.z
	end
	local ps = PseudoRandom(seed)
	local iterations = math.floor(def.iterations or 2)
	if (def.random_level or 0) > 0 then
		iterations = iterations - ps:next(0, math.floor(def.random_level))
	end
	if iterations < 2 then
		iterations = 2
	end
	local angle = (def.angle or 0) * math.pi / 180
	-- Luanti's own: a degree either way, out of the same generator, so that
	-- a forest is not every tree at the same angle
	local angle_offset = (ps:next(0, 1) % 5) * math.pi / 180
	local names = names_of(def)
	local axiom = expand(def, iterations, ps)

	local rotation = axis_rotation(math.pi / 2, 0, 0, 1)
	local x, y, z = p0.x, p0.y, p0.z
	local stack_rotation = {}
	local stack_position = {}
	local thin = def.thin_branches and true or false
	local trunk_type = def.trunk_type or "single"

	-- Under a wide trunk, so that a tree on sloping ground has no gap
	if trunk_type == "double" then
		place_trunk(map, x + 1, y - 1, z, names)
		place_trunk(map, x, y - 1, z + 1, names)
		place_trunk(map, x + 1, y - 1, z + 1, names)
	elseif trunk_type == "crossed" then
		place_trunk(map, x + 1, y - 1, z, names)
		place_trunk(map, x - 1, y - 1, z, names)
		place_trunk(map, x, y - 1, z + 1, names)
		place_trunk(map, x, y - 1, z - 1, names)
	end

	local function forward()
		local dx, dy, dz = transpose_apply(rotation, 1, 0, 0)
		x, y, z = x + dx, y + dy, z + dz
	end
	local function wide_trunk()
		if trunk_type == "double" then
			place_trunk(map, x + 1, y, z, names)
			place_trunk(map, x, y, z + 1, names)
			place_trunk(map, x + 1, y, z + 1, names)
		elseif trunk_type == "crossed" then
			place_trunk(map, x + 1, y, z, names)
			place_trunk(map, x - 1, y, z, names)
			place_trunk(map, x, y, z + 1, names)
			place_trunk(map, x, y, z - 1, names)
		end
	end
	local function turn(a, ax, ay, az)
		rotation = mat_mul(rotation, axis_rotation(a, ax, ay, az))
	end

	for i = 1, #axiom do
		local ch = string.sub(axiom, i, i)
		if ch == "G" then
			forward()
		elseif ch == "T" then
			place_trunk(map, myround(x), myround(y), myround(z), names)
			if not thin then
				wide_trunk()
			end
			forward()
		elseif ch == "F" then
			place_trunk(map, myround(x), myround(y), myround(z), names)
			-- A trunk is wide at its foot whatever thin_branches says, and
			-- a branch is wide only when it does not
			if #stack_rotation == 0 or not thin then
				wide_trunk()
			end
			-- Inside a branch: the shell of leaves around this unit of it.
			-- Each leaf gets a generator of its own, seeded from this one,
			-- which is what Luanti's own by-value PseudoRandom parameter
			-- comes to.
			if #stack_rotation > 0 then
				local size = 1
				for lx = -size, size do
				for ly = -size, size do
				for lz = -size, size do
					if math.abs(lx) == size and math.abs(ly) == size and
							math.abs(lz) == size then
						local bx, by, bz = myround(x), myround(y), myround(z)
						place_leaves(map, bx + lx + 1, by + ly, bz + lz,
								def, names, PseudoRandom(ps:next()))
						place_leaves(map, bx + lx - 1, by + ly, bz + lz,
								def, names, PseudoRandom(ps:next()))
						place_leaves(map, bx + lx, by + ly, bz + lz + 1,
								def, names, PseudoRandom(ps:next()))
						place_leaves(map, bx + lx, by + ly, bz + lz - 1,
								def, names, PseudoRandom(ps:next()))
					end
				end
				end
				end
			end
			forward()
		elseif ch == "f" then
			place_single_leaf(map, myround(x), myround(y), myround(z), def,
					names, PseudoRandom(ps:next()))
			forward()
		elseif ch == "R" then
			place_fruit(map, myround(x), myround(y), myround(z), names)
			forward()
		elseif ch == "[" then
			stack_rotation[#stack_rotation + 1] = rotation
			stack_position[#stack_position + 1] = {x, y, z}
		elseif ch == "]" then
			if #stack_rotation == 0 then
				return false, "unbalanced brackets"
			end
			rotation = table.remove(stack_rotation)
			local p = table.remove(stack_position)
			x, y, z = p[1], p[2], p[3]
		elseif ch == "+" then
			turn(angle + angle_offset, 0, 0, 1)
		elseif ch == "-" then
			turn(angle + angle_offset, 0, 0, -1)
		elseif ch == "&" then
			turn(angle + angle_offset, 0, 1, 0)
		elseif ch == "^" then
			turn(angle + angle_offset, 0, -1, 0)
		elseif ch == "*" then
			turn(angle, 1, 0, 0)
		elseif ch == "/" then
			turn(angle, -1, 0, 0)
		end
	end
	return true
end

-- The map itself, as the tree generator wants it: what is written goes
-- straight in, without on_construct or anything else a set_node does -- a
-- tree is terrain, and Luanti writes one through a VoxelManip for the same
-- reason.
local MapWrite = {}
MapWrite.__index = MapWrite

function MapWrite:get(x, y, z)
	local node = core.get_node_or_nil({x = x, y = y, z = z})
	return node and node.name or nil
end

function MapWrite:set(x, y, z, name)
	if name == "air" then
		return
	end
	core.swap_node({x = x, y = y, z = z}, {name = name})
end

local VmanipWrite = {}
VmanipWrite.__index = VmanipWrite

function VmanipWrite:get(x, y, z)
	local node = self.vm:get_node_at({x = x, y = y, z = z})
	return node and node.name or nil
end

function VmanipWrite:set(x, y, z, name)
	self.vm:set_node_at({x = x, y = y, z = z}, {name = name})
end

function core.spawn_tree(pos, def)
	local ok, err = M.grow(setmetatable({}, MapWrite), pos, def)
	if not ok then
		core.log("warning", "spawn_tree(): " .. tostring(err))
	end
	return ok
end

function core.spawn_tree_on_vmanip(vm, pos, def)
	local ok, err = M.grow(setmetatable({vm = vm}, VmanipWrite), pos, def)
	if not ok then
		core.log("warning", "spawn_tree_on_vmanip(): " .. tostring(err))
	end
	return ok
end

core.__treegen = M
