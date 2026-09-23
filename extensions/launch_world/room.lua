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
-- on a flat plane: slabs protruding at random amounts, orbs in pockets
-- cut into the mass, and rectangles inset to various depths until some
-- read black. Its nominal surface is BAY_Z; everything else is measured
-- from there.
-- **The opening overhead** ([LAUNCH_WORLD]: "a big square opening or
-- emitter overhead, about 16 to 20 voxels above the floor"). It was a
-- light with no geometry, so a mirror had nothing to reflect but the
-- soft pool it cast -- the user, 2026-09-23: the reflective spheres
-- should show a sharp bright square at the ceiling.
M.OPEN_X0, M.OPEN_X1 = -9, 9
M.OPEN_Z0, M.OPEN_Z1 = -4, 12

M.BAY_Z = -18
M.INSET_IN = 4          -- the deepest an inset goes
M.BAYS = 6
M.BAY_SPACING = 14
-- **Sixty slabs** (user, 2026-09-23: double the amount). The reference
-- frame's parts list said about thirty and this plan's open question
-- said thirty stands until it was said otherwise. It has been said.
M.SLABS = 60
-- **A slab is horizontal** (user, 2026-09-23: the slabs read vertical
-- and they are meant to read horizontal). The plan gives **x and z** as
-- 4 to 10 voxels and says nothing about y, and the master plan says
-- what y is: "slabs almost half a metre thick -- one voxel at the
-- grid". So a slab is **wide across the wall, thin in height, and deep
-- out of it** -- a shelf, a lintel -- and not a block.
--
-- Read as "x and y are 4 to 10" it was square or upright, which is what
-- the eye saw; and with that shape a deep protrusion read as a heap of
-- boxes, which is why the relief had been tuned down to 1 to 4. A thin
-- slab standing 4 to 10 out is a different thing entirely.
M.SLAB_MIN, M.SLAB_MAX = 4, 10            -- across, in voxels
-- **One tall, for now** (user, 2026-09-23), which is the master plan's
-- "almost half a metre thick -- one voxel at the grid" taken at its
-- word. The range stays so that two is a constant away; whatever it
-- holds must stay under the narrowest slab's width, or a slab can come
-- out square and read as the upright thing it is not meant to be.
M.SLAB_THIN_MIN, M.SLAB_THIN_MAX = 1, 1   -- and how thick it is
M.SLAB_OUT_MIN, M.SLAB_OUT_MAX = 3, 8     -- and how far it stands out

-- The middle of a pocket across the wall
function M.bay_x(b)
	local p = M.pockets[b + 1]
	return p.x0 + math.floor(p.sx / 2)
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

-- **The slabs, as a list rather than as a grid.** A grid of cells gave
-- every slab the cell's own size, and the plan wants x and y varying
-- from 4 to 10 voxels with no rhythm at all; thirty rectangles placed by
-- the hash do that and are what the reference's parts list counts.
--
-- A slab's depth into the wall is not in the list because it cannot be
-- seen: the mass behind the nominal surface is the same stone, so what a
-- slab is, to the eye, is the rectangle it covers and how far it stands
-- out of it.
M.slabs = {}
for i = 1, M.SLABS do
	local h1 = hash2(i, 1, 11)
	local h2 = hash2(i, 2, 22)
	local span = M.SLAB_MAX - M.SLAB_MIN + 1
	local sx = M.SLAB_MIN + math.floor(h1 / 8) % span
	local sy = M.SLAB_THIN_MIN + math.floor(h1 / 4096) %
			(M.SLAB_THIN_MAX - M.SLAB_THIN_MIN + 1)
	local x0 = M.X_MIN + h2 % (M.X_MAX - M.X_MIN - sx + 1)
	local y0 = math.floor(h2 / 2048) % (M.Y_TOP - sy + 1)
	M.slabs[i] = {x0 = x0, x1 = x0 + sx - 1, y0 = y0, y1 = y0 + sy - 1,
		out = M.SLAB_OUT_MIN + math.floor(h1 / 1048576) %
				(M.SLAB_OUT_MAX - M.SLAB_OUT_MIN + 1)}
end
M.SLAB_OUT = M.SLAB_OUT_MAX     -- the furthest any slab comes out

-- **The pockets, in the numbers the user gave 2026-09-23.** A pocket's
-- floor is at Y 0 to 3 and no higher, because the player reaches into
-- these; it is usually 3x3x3 with a 2 or a 4 turning up in any dimension.
--
-- **How many there are is how many things there are to put in them**,
-- which is why M.set_pockets() below is a function and not a table: the
-- room's contents are the tree's launch actions, and world.lua says how
-- many it found. The default is here so that this file runs on its own.
M.pockets = {}

-- The middle of a pocket, which is where its orb hangs
function M.bay_y(b)
	local p = M.pockets[b + 1]
	return p.y0 + math.floor(p.sy / 2)
end

-- **How far the wall's face stands at (x, y).** The slabs above, and
-- rectangles cut back into whatever is left -- which is where the wall's
-- interest comes from, rather than from putting different things on it.
local face_cache = {}
local slab_face
function slab_face(x, y)
	local out = 0
	for i = 1, #M.slabs do
		local s = M.slabs[i]
		if x >= s.x0 and x <= s.x1 and y >= s.y0 and y <= s.y1 and
				s.out > out then
			out = s.out
		end
	end
	-- Insets: rectangles cut back, rare and deep, some of them deep
	-- enough to read black once the overhead light is the only thing
	-- reaching them
	local c3 = hash2(floor_div(x + 2, 6), floor_div(y + 1, 6), 3)
	if c3 % 16 < 2 then
		out = out - (1 + math.floor(c3 / 16) % M.INSET_IN)
	end
	return M.BAY_Z + out
end

function M.face_z(x, y)
	local key = (x + 128) * 4096 + (y + 128)
	local c = face_cache[key]
	if c then return c end
	local z = slab_face(x, y)
	-- **A pocket gets a surround.** Where the wall beside a mouth stands
	-- behind it, there is nothing for the mouth's column to be cut from
	-- and the pocket opens sideways into the room instead of being a
	-- hole. So the frame one voxel around a pocket comes forward to the
	-- mouth, which is also what makes the ornamented columns exist.
	for b = 1, M.BAYS do
		local p = M.pockets[b]
		if p.mouth and x >= p.x0 - 1 and x <= p.x0 + p.sx and
				y >= p.y0 - 1 and y <= p.y0 + p.sy and z < p.mouth then
			z = p.mouth
		end
	end
	face_cache[key] = z
	return z
end

-- **The pockets, one per thing the room holds.** Called before build(),
-- with however many launch actions the tree offered.
function M.set_pockets(n)
	M.BAYS = n
	M.pockets = {}
	-- Spread across the wall with a margin at each end, so the outermost
	-- pocket is not cut by the corner
	local span = (M.X_MAX - M.X_MIN - 12) / n
	for b = 0, n - 1 do
		local h = hash2(b, 7, 33)
		-- 3 usually, 2 or 4 now and then: five draws, one of each end
		local function dim(shift)
			local d = math.floor(h / shift) % 5
			if d == 0 then return 2 end
			if d == 4 then return 4 end
			return 3
		end
		local sx, sy, sz = dim(1), dim(8), dim(64)
		local y0 = math.floor(h / 512) % 4
		local cx = math.floor(M.X_MIN + 6 + (b + 0.5) * span)
		M.pockets[b + 1] = {x0 = cx - math.floor(sx / 2), y0 = y0,
			sx = sx, sy = sy, sz = sz}
	end
	-- **A pocket has one mouth, not a mouth per column.** Taking the
	-- face at each (x, y) sheared the pocket wherever a slab covered
	-- half of it, and a sheared hole does not read as a pocket. So the
	-- mouth is the face at the pocket's own middle, settled once. The
	-- face cache goes with it: face_z() answers the surround of these.
	for b = 1, n do
		local p = M.pockets[b]
		p.mouth = slab_face(p.x0 + math.floor(p.sx / 2),
				p.y0 + math.floor(p.sy / 2))
	end
	face_cache = {}
	return M.pockets
end
M.set_pockets(M.BAYS)

-- Whether (x, y, z) is inside a pocket, and whether it is one of the side
-- columns that carry the ornament
function M.in_pocket(x, y, z)
	for b = 1, M.BAYS do
		local p = M.pockets[b]
		if x >= p.x0 and x < p.x0 + p.sx and
				y >= p.y0 and y < p.y0 + p.sy then
			local mouth = p.mouth
			if z <= mouth and z > mouth - p.sz then
				-- The voxel down each side of the mouth is its column
				return true, (x == p.x0 or x == p.x0 + p.sx - 1)
			end
		end
	end
	return false, false
end

-- The ids the data bytes are, filled in by world.lua once the registry is
-- built. One table so the description below reads as it did in C.
M.id = {air = 0, stone = 0, dark = 0, floor_light = 0, floor_dark = 0,
	column = 0, placed = 0, frieze = 0}

-- **The player's diff against the generated room** ([LAUNCH_WORLD] step
-- 8): the room is a function of (x, y, z) and this is the only thing
-- that is not, which is what makes it the whole save. A key is here when
-- the player put a voxel there, and false when they dug one of their own
-- out again -- there being nothing else they can dig.
M.placed = {}
function M.key(x, y, z)
	return x .. "," .. y .. "," .. z
end

-- What is at a voxel. The build and the dissolve's own restore both read
-- this, so there is one description of the room and not two.
function M.voxel_at(x, y, z)
	local id = M.id
	if M.placed[M.key(x, y, z)] then
		return id.placed
	end
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
	local face = (y >= 0 and y <= M.Y_TOP) and M.face_z(x, y) or nil
	if face and z <= face then
		if M.in_pocket(x, y, z) then return id.air end
		-- A voxel beside a pocket's mouth is one of its columns
		local a, ac = M.in_pocket(x - 1, y, z)
		if a and ac then return id.column end
		local b, bc = M.in_pocket(x + 1, y, z)
		if b and bc then return id.column end
		-- **The slab's own edge wears the frieze.** A slab is one voxel
		-- tall, so the strip a player sees is its outermost voxel, and
		-- that is where the ornament goes; the mass behind it is plain
		-- stone. A voxel is that edge when it is the front of a face
		-- that stands proud of the wall's nominal surface.
		if z == face and face > M.BAY_Z then return id.frieze end
		return id.stone
	end
	if y > M.Y_TOP then
		-- The square is cut right through: what is above the room is
		-- outside it
		if x >= M.OPEN_X0 and x <= M.OPEN_X1 and
				z >= M.OPEN_Z0 and z <= M.OPEN_Z1 then
			return id.air
		end
		return id.stone
	end
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
		column = 6, frieze = 7, placed = 8}
	assert(M.face_z(3, 4) == M.face_z(3, 4), "the wall is the same twice")
	local out_min, out_max = 99, -99
	for x = M.X_MIN, M.X_MAX do
		for y = 0, M.Y_TOP do
			local o = M.face_z(x, y) - M.BAY_Z
			if o < out_min then out_min = o end
			if o > out_max then out_max = o end
		end
	end
	assert(out_max >= M.SLAB_OUT_MIN and out_max <= M.SLAB_OUT_MAX,
			"slabs stand out: " .. out_max)
	assert(out_min < 0 and out_min >= -M.INSET_IN - M.SLAB_OUT_MAX,
			"insets cut in: " .. out_min)
	assert(#M.slabs == M.SLABS, "thirty slabs")
	for i = 1, #M.slabs do
		local s = M.slabs[i]
		local sx, sy = s.x1 - s.x0 + 1, s.y1 - s.y0 + 1
		assert(sx >= M.SLAB_MIN and sx <= M.SLAB_MAX,
				"slab " .. i .. " is " .. sx .. " across")
		assert(sy >= M.SLAB_THIN_MIN and sy <= M.SLAB_THIN_MAX,
				"slab " .. i .. " is " .. sy .. " thick")
		assert(sx > sy, "slab " .. i .. " is wider than it is thick")
		assert(s.x0 >= M.X_MIN and s.x1 <= M.X_MAX and s.y0 >= 0 and
				s.y1 <= M.Y_TOP, "slab " .. i .. " is on the wall")
	end
	for b = 1, M.BAYS do
		local p = M.pockets[b]
		assert(p.y0 >= 0 and p.y0 <= 3, "a pocket's floor is at Y 0 to 3")
		for _, d in ipairs({p.sx, p.sy, p.sz}) do
			assert(d >= 2 and d <= 4, "a pocket is 2 to 4 voxels")
		end
		local x, y = M.bay_x(b - 1), M.bay_y(b - 1)
		local z = p.mouth - 1
		assert(M.voxel_at(x, y, z) == M.id.air, "bay " .. b .. " has a pocket")
		assert(M.voxel_at(p.x0 - 1, y, z) == M.id.column and
				M.voxel_at(p.x0 + p.sx, y, z) == M.id.column,
				"bay " .. b .. " has an ornamented column down each side")
	end
	do
		-- Somewhere on the wall a slab stands proud, and its outermost
		-- voxel is the frieze while the one behind it is not
		local found = false
		for x = M.X_MIN, M.X_MAX do
			for y = 0, M.Y_TOP do
				local f = M.face_z(x, y)
				if f > M.BAY_Z and not M.in_pocket(x, y, f) then
					assert(M.voxel_at(x, y, f) == M.id.frieze,
							"a slab's edge wears the frieze")
					assert(M.voxel_at(x, y, f - 1) == M.id.stone,
							"and the stone behind it does not")
					found = true
					break
				end
			end
			if found then break end
		end
		assert(found, "some slab stands proud of the wall")
	end
	assert(M.voxel_at(0, M.Y_TOP + 2, 4) == M.id.air,
			"the opening is cut through the ceiling")
	assert(M.voxel_at(M.OPEN_X1 + 2, M.Y_TOP + 2, 4) == M.id.stone,
			"and the ceiling beside it is not")
	assert(M.voxel_at(0, -1, 0) ~= M.voxel_at(2, -1, 0), "the floor checkers")
	assert(M.voxel_at(0, -1, 0) == M.voxel_at(1, -1, 1) or
			M.voxel_at(0, -1, 0) == M.voxel_at(0, -1, 1),
			"a checker square is two voxels")
	local rows = M.build()
	assert(#rows == M.H * M.D, "one row a (y, z): " .. #rows)
	-- The pockets follow the count they are given, and they still fit
	M.set_pockets(11)
	assert(#M.pockets == 11, "eleven things, eleven pockets")
	for b = 1, 11 do
		local p = M.pockets[b]
		assert(p.x0 - 1 >= M.X_MIN and p.x0 + p.sx <= M.X_MAX,
				"pocket " .. b .. " and its columns are on the wall")
	end
	M.set_pockets(M.BAYS)
	assert(#rows[1] == M.W, "a row is the room across: " .. #rows[1])
	assert(M.row_index(M.OY, M.OZ) == 1, "the first row is the first row")
	return true
end

if ... == nil then
	assert(M.self_check())
	print("room.lua: ok, " .. M.W .. "x" .. M.H .. "x" .. M.D .. " voxels")
end

return M
