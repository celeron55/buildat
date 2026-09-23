-- extensions/launch_world/room.lua
--
-- **The room, on the 45 cm grid**, described here and nowhere else. One
-- unit of the scene is one voxel; world.lua is written in metres and
-- multiplies on the way in.
--
-- This was `games/launch_world/main/main.cpp` until the room became an
-- extension ([LAUNCH_WORLD]: a launcher is not a game, and starting one
-- is `ctx.launch` on the launcher's own trusted side). The costs the plan
-- named come with it: no voxelworld means no skylight flood and no baked
-- AO, so the wall's relief rests on the real lights; and the dissolve is
-- a Lua array and a re-mesh rather than voxel removal on a server.
local M = {}

-- In voxels, inclusive. The floor is the layers under y = 0, so that the
-- metre-zero of world.lua is the floor's top.
M.FLOOR_TOP = -1
M.FLOOR_BOTTOM = -3
M.X_MIN, M.X_MAX = -46, 46
M.Z_MIN, M.Z_MAX = -30, 44
M.Y_TOP = 26

-- **The wall, as the reference actually has it.** Not a balcony per orb
-- on a flat plane: slabs protruding at random amounts, orbs in generous
-- pockets cut into the mass, and rectangles inset to various depths until
-- some read black. Its nominal surface is BAY_Z; everything else is
-- measured from there.
M.BAY_Z = -18
M.SLAB_OUT = 4          -- the furthest a slab comes out
M.INSET_IN = 4          -- the deepest an inset goes
M.BAYS = 6
M.BAY_SPACING = 14
M.SLAB_H = 3
-- A pocket is about twice the orb across in every direction: the orb is
-- 1.7 units, which is under four voxels, so eight is twice it
M.POCKET = 8
M.POCKET_DEPTH = 8
M.BAY_TIER = {2, 4, 1, 3, 5, 2}   -- 0-based bay index, as it always was

function M.bay_x(b) return (b - 2) * M.BAY_SPACING - 7 end
function M.bay_tier(b) return M.BAY_TIER[b + 1] end
-- The middle of a pocket, which is where its orb hangs
function M.bay_y(b)
	return M.bay_tier(b) * M.SLAB_H + math.floor(M.SLAB_H / 2) + 4
end

-- Lua 5.1 has no bitwise operators and its numbers are doubles, so the
-- hash below does its own xor and keeps every product inside the 53 bits
-- a double is exact in. It is called once a wall cell, not once a voxel.
local function bit_xor(a, b)
	local r, bitv = 0, 1
	for _ = 1, 32 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + bitv end
		a, b, bitv = (a - x) / 2, (b - y) / 2, bitv * 2
	end
	return r
end

-- a * b mod 2^32, split so neither half overflows a double's exact range
local function mul32(a, b)
	local lo = a % 65536
	local hi = (a - lo) / 65536
	return (lo * b + (hi * b % 65536) * 65536) % 4294967296
end

-- A hash with no state, so the wall is the same every boot and the layout
-- stays the landmark the player navigates by
local function hash2(a, b, salt)
	local h = bit_xor(bit_xor(mul32(a % 4294967296, 73856093),
			mul32(b % 4294967296, 19349663)), mul32(salt, 83492791))
	h = bit_xor(h, math.floor(h / 8192))
	h = mul32(h, 1540483477)
	h = bit_xor(h, math.floor(h / 32768))
	return h
end

local function floor_div(a, b)
	return math.floor(a / b)
end

-- **How far the wall's face stands at (x, y).** Two grids of different
-- periods are taken together so the slabs do not fall on a rhythm, and a
-- third cuts rectangles back into whatever is left -- which is where the
-- wall's interest comes from, rather than from putting different things
-- on it.
local face_cache = {}
function M.face_z(x, y)
	local key = (x + 128) * 4096 + (y + 128)
	local c = face_cache[key]
	if c then return c end
	local out = 0
	-- Slabs: cells of 9 and 13 voxels, most of them flush, a quarter
	-- standing out by one to three. Two periods so the standing ones do
	-- not fall on a rhythm; tuned down from "every cell, by up to four"
	-- which read as rubble rather than as a wall (2026-09-23).
	local a = hash2(floor_div(x, 9), floor_div(y, 9), 1)
	local b = hash2(floor_div(x + 4, 13), floor_div(y + 6, 13), 2)
	if a % 8 < 2 then
		out = 1 + math.floor(a / 16) % 3
	end
	if b % 8 < 2 then
		local bo = 1 + math.floor(b / 16) % 2
		if bo > out then out = bo end
	end
	-- Insets: rectangles cut back, rare and deep, some of them deep
	-- enough to read black once the overhead light is the only thing
	-- reaching them
	local c3 = hash2(floor_div(x + 2, 6), floor_div(y + 1, 6), 3)
	if c3 % 16 < 2 then
		out = out - (1 + math.floor(c3 / 16) % M.INSET_IN)
	end
	local z = M.BAY_Z + out
	face_cache[key] = z
	return z
end

-- Whether (x, y, z) is inside a pocket, and whether it is one of the side
-- columns that carry the ornament
function M.in_pocket(x, y, z)
	for b = 0, M.BAYS - 1 do
		local cx, cy = M.bay_x(b), M.bay_y(b)
		if x >= cx - M.POCKET / 2 and x <= cx + M.POCKET / 2 and
				y >= cy - M.POCKET / 2 and y <= cy + M.POCKET / 2 then
			local mouth = M.face_z(x, y)
			if z <= mouth and z >= mouth - M.POCKET_DEPTH then
				-- The two voxels down each side of the mouth are the columns
				return true, (x <= cx - M.POCKET / 2 + 1 or
						x >= cx + M.POCKET / 2 - 1)
			end
		end
	end
	return false, false
end

-- The ids the data bytes are, filled in by world.lua once the registry is
-- built. One table so the description below reads as it did in C.
M.id = {air = 0, stone = 0, dark = 0, floor_light = 0, floor_dark = 0,
	column = 0}

-- What is at a voxel. The build and the dissolve's own restore both read
-- this, so there is one description of the room and not two.
function M.voxel_at(x, y, z)
	local id = M.id
	local outside = x < M.X_MIN or x > M.X_MAX or z < M.Z_MIN or z > M.Z_MAX
	if y <= M.FLOOR_TOP and y >= M.FLOOR_BOTTOM and not outside then
		-- Two voxels a square: at 45 cm one voxel a square is a fine
		-- check that reads as noise down the room
		local u = math.floor(x / 2) + math.floor(z / 2)
		if u % 2 == 0 then return id.floor_light end
		return id.floor_dark
	end
	if y < M.FLOOR_BOTTOM then return id.dark end
	if outside then return id.stone end
	-- **The wall**: one mass whose face stands wherever face_z() says,
	-- with pockets cut into it. The same material lines a pocket -- it is
	-- a hole in the wall and not a differently finished box -- and the
	-- ornament is on the side columns of its mouth and nowhere else.
	if y >= 0 and y <= M.Y_TOP and z <= M.face_z(x, y) then
		if M.in_pocket(x, y, z) then return id.air end
		-- A voxel beside a pocket's mouth is one of its columns
		local a, ac = M.in_pocket(x - 1, y, z)
		if a and ac then return id.column end
		local b, bc = M.in_pocket(x + 1, y, z)
		if b and bc then return id.column end
		return id.stone
	end
	if y > M.Y_TOP then return id.stone end
	return id.air
end

-- The block the mesher is given: one voxel of mass all round the room, so
-- the room is closed and its outermost faces have something to cull
-- against.
M.OX, M.OY, M.OZ = M.X_MIN - 1, M.FLOOR_BOTTOM - 1, M.Z_MIN - 1
M.W = M.X_MAX - M.X_MIN + 3
M.H = M.Y_TOP - M.FLOOR_BOTTOM + 3
M.D = M.Z_MAX - M.Z_MIN + 3

-- The room as the byte-per-voxel block set_8bit_voxel_geometry wants, x
-- fastest and z slowest. Returned as an array of rows so the dissolve can
-- rewrite a box of it without rebuilding the string from nothing.
function M.build()
	local rows = {}
	local n = 0
	for z = M.OZ, M.OZ + M.D - 1 do
		for y = M.OY, M.OY + M.H - 1 do
			local row = {}
			for x = M.OX, M.OX + M.W - 1 do
				row[#row + 1] = string.char(M.voxel_at(x, y, z))
			end
			n = n + 1
			rows[n] = table.concat(row)
		end
	end
	return rows
end

-- The row a (y, z) is, for rewriting one
function M.row_index(y, z)
	return (z - M.OZ) * M.H + (y - M.OY) + 1
end

-- The one runnable check this file leaves behind: the description is a
-- function of (x, y, z) and the room it describes is the room the rest of
-- the code assumes. Run it with `lua extensions/launch_world/room.lua`.
function M.self_check()
	M.id = {air = 1, stone = 2, dark = 3, floor_light = 4, floor_dark = 5,
		column = 6}
	assert(M.face_z(3, 4) == M.face_z(3, 4), "the wall is the same twice")
	local out_min, out_max = 99, -99
	for x = M.X_MIN, M.X_MAX do
		for y = 0, M.Y_TOP do
			local o = M.face_z(x, y) - M.BAY_Z
			if o < out_min then out_min = o end
			if o > out_max then out_max = o end
		end
	end
	assert(out_max > 0 and out_max <= M.SLAB_OUT, "slabs stand out: " .. out_max)
	assert(out_min < 0 and out_min >= -M.INSET_IN, "insets cut in: " .. out_min)
	for b = 0, M.BAYS - 1 do
		local x, y = M.bay_x(b), M.bay_y(b)
		local z = M.face_z(x, y) - 2
		assert(M.voxel_at(x, y, z) == M.id.air, "bay " .. b .. " has a pocket")
		local edge = x - M.POCKET / 2 - 1
		assert(M.voxel_at(edge, y, z) == M.id.column,
				"bay " .. b .. " has an ornamented column beside its mouth")
	end
	assert(M.voxel_at(0, -1, 0) ~= M.voxel_at(2, -1, 0), "the floor checkers")
	assert(M.voxel_at(0, -1, 0) == M.voxel_at(1, -1, 1) or
			M.voxel_at(0, -1, 0) == M.voxel_at(0, -1, 1),
			"a checker square is two voxels")
	local rows = M.build()
	assert(#rows == M.H * M.D, "one row a (y, z): " .. #rows)
	assert(#rows[1] == M.W, "a row is the room across: " .. #rows[1])
	assert(M.row_index(M.OY, M.OZ) == 1, "the first row is the first row")
	return true
end

if ... == nil then
	assert(M.self_check())
	print("room.lua: ok, " .. M.W .. "x" .. M.H .. "x" .. M.D .. " voxels")
end

return M
