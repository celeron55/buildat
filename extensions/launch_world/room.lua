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

-- **Every wall carries pockets, and each answers in its own frame**
-- ([POCKETS_ROUND], user 2026-09-24). A wall has an axis it runs along
-- (u), an axis it is cut into (the normal), and a direction into the
-- stone. A pocket is described in its own wall's frame -- u0, y0, su,
-- sy, sd and the mouth -- and everything that used to be an x and a z
-- is that question asked of the pocket's wall.
--
-- front is the wall the player faces at BAY_Z, back the one behind
-- them at Z_MAX, left and right the two at X_MIN and X_MAX.
M.WALL_ORDER = {"front", "left", "right", "back"}
-- Which room axis runs along the wall; the other one is its normal
M.WALL_U = {front = "x", back = "x", left = "z", right = "z"}
-- Which way is into the stone, on the normal axis
M.WALL_IN = {front = -1, back = 1, left = -1, right = 1}

-- The plane a wall's relief is measured from: the front wall's nominal
-- surface, and SIDE_IN inside the boundary for the other three
function M.nominal_face(w)
	if w == "front" then return M.BAY_Z end
	if w == "left" then return M.X_MIN + M.SIDE_IN - 1 end
	if w == "right" then return M.X_MAX - M.SIDE_IN + 1 end
	return M.Z_MAX - M.SIDE_IN + 1
end

-- (u, y, n) in a wall's frame back to a voxel: u along the wall, n on
-- its normal axis
function M.wall_xyz(w, u, y, n)
	if M.WALL_U[w] == "x" then return u, y, n end
	return n, y, u
end
-- And the other way: the two coordinates that matter for a wall
function M.wall_un(w, x, y, z)
	if M.WALL_U[w] == "x" then return x, z end
	return z, x
end
-- How far along the wall a pocket can stand
function M.wall_span(w)
	if M.WALL_U[w] == "x" then return M.X_MIN, M.X_MAX end
	return M.Z_MIN, M.Z_MAX
end

-- The middle of a pocket along its own wall
function M.bay_u(b)
	local p = M.pockets[b + 1]
	return p.u0 + math.floor(p.su / 2)
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

-- **The other three walls exist too** (user, 2026-09-23: only the wall
-- the player faces was generated, and the rest were one flat plane of
-- stone). They are the same stone with the same slabs and insets and
-- **no pockets** -- the bays belong to the wall that has them, and these
-- are the dark mass the room's light-on-dark contrast is made of.
--
-- **Each seeded by its own name**, which is the trick the ornament
-- generator already uses, so they are not rotated copies of the front
-- wall or of each other.
--
-- A side wall's slabs are laid out along the axis it runs in -- z for
-- the two sides, x for the back -- and stand *into* the room from a
-- nominal face a little inside the boundary, so an inset has somewhere
-- to cut back to. Outside the boundary is solid stone either way.
M.SIDE_IN = 3           -- how far the nominal side face stands inward
M.side_slabs = {}
local function name_salt(name)
	local h = 0
	for i = 1, #name do
		h = (h * 31 + string.byte(name, i)) % 4294967296
	end
	return h
end
for _, name in ipairs({"left", "right", "back"}) do
	local salt = name_salt(name)
	local list = {}
	for i = 1, M.SLABS do
		local h1 = hash2(i, 1, salt % 100000 + 11)
		local h2 = hash2(i, 2, salt % 100000 + 22)
		local span = M.SLAB_MAX - M.SLAB_MIN + 1
		local su = M.SLAB_MIN + math.floor(h1 / 8) % span
		local sy = M.SLAB_THIN_MIN + math.floor(h1 / 4096) %
				(M.SLAB_THIN_MAX - M.SLAB_THIN_MIN + 1)
		-- Along the wall's own axis, in the room's coordinates; the
		-- range is the widest either axis has, and what falls outside a
		-- shorter wall simply never matches
		local u0 = M.X_MIN + h2 % (M.X_MAX - M.X_MIN - su + 1)
		local y0 = math.floor(h2 / 2048) % (M.Y_TOP - sy + 1)
		list[i] = {u0 = u0, u1 = u0 + su - 1, y0 = y0, y1 = y0 + sy - 1,
			out = M.SLAB_OUT_MIN + math.floor(h1 / 1048576) %
					(M.SLAB_OUT_MAX - M.SLAB_OUT_MIN + 1)}
	end
	M.side_slabs[name] = {list = list, salt = salt}
end

-- How far a side wall stands into the room at (u, y): the nominal face
-- plus its slabs, less its insets, and never less than nothing -- a wall
-- that receded past the boundary would open a hole into the stone
-- outside.
local side_cache = {}
function M.side_in(name, u, y)
	local key = name .. ":" .. u .. ":" .. y
	local c = side_cache[key]
	if c then return c end
	local w = M.side_slabs[name]
	local out = 0
	for i = 1, #w.list do
		local sl = w.list[i]
		if u >= sl.u0 and u <= sl.u1 and y >= sl.y0 and y <= sl.y1 and
				sl.out > out then
			out = sl.out
		end
	end
	local c3 = hash2(floor_div(u + 2, 6), floor_div(y + 1, 6),
			w.salt % 100000 + 3)
	if c3 % 16 < 2 then
		out = out - (1 + math.floor(c3 / 16) % M.INSET_IN)
	end
	local d = M.SIDE_IN + out
	if d < 0 then d = 0 end
	side_cache[key] = d
	return d
end

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

-- **Where a wall's stone ends and the room begins**, on the wall's own
-- normal axis and before any pocket is taken into account: the front
-- wall's slabs and insets, or a side wall's own relief off its
-- boundary.
function M.wall_face_raw(w, u, y)
	if w == "front" then return slab_face(u, y) end
	if w == "left" then return M.X_MIN + M.side_in("left", u, y) - 1 end
	if w == "right" then return M.X_MAX - M.side_in("right", u, y) + 1 end
	return M.Z_MAX - M.side_in("back", u, y) + 1
end

-- **A pocket gets a surround.** Where the wall beside a mouth stands
-- behind it, there is nothing for the mouth's column to be cut from and
-- the pocket opens sideways into the room instead of being a hole. So
-- the frame one voxel around a pocket comes forward to the mouth, which
-- is also what makes the ornamented columns exist.
local function pocket_surround(w, u, y, n)
	for b = 1, M.BAYS do
		local p = M.pockets[b]
		if p.wall == w and p.mouth and u >= p.u0 - 1 and
				u <= p.u0 + p.su and y >= p.y0 - 1 and
				y <= p.y0 + p.sy then
			-- Nearer the room than what the relief left here
			if (p.mouth - n) * M.WALL_IN[w] < 0 then n = p.mouth end
		end
	end
	return n
end

-- The face a wall actually presents at (u, y), pockets and all
local wall_cache = {}
function M.wall_face(w, u, y)
	local key = w .. ":" .. u .. ":" .. y
	local c = wall_cache[key]
	if c then return c end
	local n = pocket_surround(w, u, y, M.wall_face_raw(w, u, y))
	wall_cache[key] = n
	return n
end

function M.face_z(x, y)
	local key = (x + 128) * 4096 + (y + 128)
	local c = face_cache[key]
	if c then return c end
	local z = pocket_surround("front", x, y, slab_face(x, y))
	face_cache[key] = z
	return z
end

-- **The pockets, one per thing the room holds.** Called before build(),
-- with however many launch actions the tree offered.
-- **How many pockets the wall can hold** ([LAUNCH_WORLD]: nine fit
-- across 93 voxels and thirty would not, and ContentDB can install a
-- game at any time). A pocket is at most four voxels across and wants a
-- column of wall either side, so six voxels apiece is what fits between
-- the margins -- and what does not fit stands on the floor instead,
-- which is the room's own answer for everything that is not in the
-- wall. Asking for more than this is not an error: it is answered with
-- what the wall can do.
-- **Six voxels apiece**: a pocket is at most four voxels across and
-- wants a column of wall either side, and that pitch is what a wall's
-- capacity is counted in. What does not fit stands on the floor
-- instead, which is the room's answer for everything not in a wall.
M.POCKET_PITCH = 6
function M.wall_capacity(w)
	local lo, hi = M.wall_span(w)
	return math.max(1, math.floor((hi - lo - 12) / M.POCKET_PITCH))
end
-- How many the four walls hold between them. Asking for more than this
-- is not an error: it is answered with what the room can do.
function M.max_pockets()
	local n = 0
	for _, w in ipairs(M.WALL_ORDER) do
		n = n + M.wall_capacity(w)
	end
	return n
end

-- Answers how many it made, which may be fewer than it was asked for.
--
-- **The pockets are allocated in a fixed order** (user, 2026-09-24),
-- which is what makes a room with four games and a room with forty both
-- look deliberate: the wall the player faces first, **filling from its
-- middle outwards**, then the side walls, and last the wall behind the
-- player. So a small tree fills the middle of one wall and nothing
-- else, and nothing is behind the player until everything in front of
-- them is taken. **It is a sequence and not a share**: the n-th pocket
-- has a place, so growth reads as a room filling up rather than as a
-- different room.
function M.set_pockets(n)
	n = math.max(1, math.min(n, M.max_pockets()))
	M.BAYS = n
	M.pockets = {}
	local b = 0
	for _, w in ipairs(M.WALL_ORDER) do
		local lo, hi = M.wall_span(w)
		local mid = math.floor((lo + hi) / 2)
		local cap = M.wall_capacity(w)
		for k = 0, cap - 1 do
			if b >= n then break end
			-- Outwards from the middle: 0, +1, -1, +2, -2 ...
			local step = math.ceil(k / 2) * ((k % 2 == 1) and 1 or -1)
			local h = hash2(b, 7, 33)
			-- 3 usually, 2 or 4 now and then: five draws, one of each end
			local function dim(shift)
				local d = math.floor(h / shift) % 5
				if d == 0 then return 2 end
				if d == 4 then return 4 end
				return 3
			end
			local su, sy, sd = dim(1), dim(8), dim(64)
			local y0 = math.floor(h / 512) % 4
			local cu = mid + step * M.POCKET_PITCH
			M.pockets[b + 1] = {wall = w, u0 = cu - math.floor(su / 2),
				y0 = y0, su = su, sy = sy, sd = sd}
			b = b + 1
		end
	end
	-- **A pocket has one mouth, not a mouth per column.** Taking the
	-- face at each (u, y) sheared the pocket wherever a slab covered
	-- half of it, and a sheared hole does not read as a pocket. So the
	-- mouth is the face at the pocket's own middle, settled once. The
	-- face caches go with it: the faces answer the surround of these.
	for i = 1, n do
		local p = M.pockets[i]
		p.mouth = M.wall_face_raw(p.wall, p.u0 + math.floor(p.su / 2),
				p.y0 + math.floor(p.sy / 2))
	end
	face_cache = {}
	wall_cache = {}
	return n
end
M.set_pockets(M.BAYS)

-- Whether (x, y, z) is inside a pocket, and whether it is one of the side
-- columns that carry the ornament
function M.in_pocket(x, y, z)
	for b = 1, M.BAYS do
		local p = M.pockets[b]
		local u, n = M.wall_un(p.wall, x, y, z)
		if u >= p.u0 and u < p.u0 + p.su and
				y >= p.y0 and y < p.y0 + p.sy then
			local d = (n - p.mouth) * M.WALL_IN[p.wall]
			if d >= 0 and d < p.sd then
				-- The voxel down each side of the mouth is its column,
				-- and the wall says which way "beside" runs
				return true, (u == p.u0 or u == p.u0 + p.su - 1), p.wall
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
local NEIGHBOURS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
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
	-- A voxel inside a wall's mass: air where a pocket is cut, the
	-- ornamented column beside a mouth, the frieze on a proud face.
	-- One answer for the four walls, each asked in its own frame.
	local function wall_voxel(w, face)
		if M.in_pocket(x, y, z) then return id.air end
		-- A voxel beside a pocket's mouth is one of its columns,
		-- "beside" being along the wall the pocket is cut into -- which
		-- is not always the wall whose mass this voxel is in: the front
		-- wall is one mass at every x in front of it and claims the
		-- corner a side wall's pocket is cut into.
		for _, d in ipairs(NEIGHBOURS) do
			local a, ac, aw = M.in_pocket(x + d[1], y, z + d[2])
			if a and ac and ((M.WALL_U[aw] == "x") == (d[1] ~= 0)) then
				return id.column
			end
		end
		-- **The slab's own edge wears the frieze.** A slab is one voxel
		-- tall, so the strip a player sees is its outermost voxel, and
		-- that is where the ornament goes; the mass behind it is plain
		-- stone. A voxel is that edge when it is the front of a face
		-- that stands proud of the wall's nominal surface.
		local _, n = M.wall_un(w, x, y, z)
		if n == face and
				(face - M.nominal_face(w)) * M.WALL_IN[w] < 0 then
			return id.frieze
		end
		return id.stone
	end

	local face = (y >= 0 and y <= M.Y_TOP) and M.face_z(x, y) or nil
	if face and z <= face then
		local v = wall_voxel("front", face)
		if v then return v end
	end
	-- **The three walls that are not the one with the pockets**: mass
	-- standing in from each boundary by its own relief. Decided after
	-- the pocket wall, which wins where they meet at a corner -- its
	-- frieze and its columns are what the room is read by.
	if y >= 0 and y <= M.Y_TOP then
		-- **Their slabs wear the frieze too** (user, 2026-09-24: the
		-- other walls' slabs have no ornament on their sides). The rule
		-- is the pocket wall's: the outermost voxel of a face that
		-- stands proud of the wall's nominal plane is the strip a
		-- player sees, and that is where the ornament goes. `side_in`
		-- is SIDE_IN plus the slab, less an inset, so a face is proud
		-- when it stands further in than the nominal SIDE_IN.
		-- **And they carry pockets too** ([POCKETS_ROUND]): a wall is a
		-- mass up to the face its relief leaves, with pockets cut into
		-- it and their columns beside them, whichever wall it is.
		for _, w in ipairs({"left", "right", "back"}) do
			local u, n = M.wall_un(w, x, y, z)
			local face = M.wall_face(w, u, y)
			-- Inside the mass: from the boundary to the face
			if (n - face) * M.WALL_IN[w] >= 0 then
				local v = wall_voxel(w, face)
				if v then return v end
			end
		end
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
		for _, d in ipairs({p.su, p.sy, p.sd}) do
			assert(d >= 2 and d <= 4, "a pocket is 2 to 4 voxels")
		end
		-- A voxel one in from the mouth is inside the pocket, and the
		-- one beside each edge of the mouth is its ornamented column --
		-- asked in the pocket's own wall's frame
		local u, y = M.bay_u(b - 1), M.bay_y(b - 1)
		local n = p.mouth + M.WALL_IN[p.wall]
		local x, yy, z = M.wall_xyz(p.wall, u, y, n)
		assert(M.voxel_at(x, yy, z) == M.id.air,
				"bay " .. b .. " (" .. p.wall .. ") has a pocket")
		local ax, ay, az = M.wall_xyz(p.wall, p.u0 - 1, y, n)
		local bx, by, bz = M.wall_xyz(p.wall, p.u0 + p.su, y, n)
		assert(M.voxel_at(ax, ay, az) == M.id.column and
				M.voxel_at(bx, by, bz) == M.id.column,
				"bay " .. b .. " (" .. p.wall ..
				") has an ornamented column down each side")
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
	do
		-- **And the other three walls wear it as well** (user,
		-- 2026-09-24: their slabs had no ornament on their sides). The
		-- left wall's face is SIDE_IN plus its slab, so the voxel at
		-- the face of a proud one is the frieze and the voxel behind it
		-- is stone.
		-- Past the pocket wall's own face: that wall is one mass at
		-- every z in front of it and wins where they meet
		local found = false
		for z = M.Z_MIN + 1, M.Z_MAX - 1 do
			for y = 0, M.Y_TOP do
				local into = M.side_in("left", z, y)
				local x = M.X_MIN + into - 1
				if into > M.SIDE_IN and z > M.face_z(x, y) then
					assert(M.voxel_at(x, y, z) == M.id.frieze,
							"a side wall's slab wears the frieze")
					assert(M.voxel_at(x - 1, y, z) == M.id.stone,
							"and the stone behind it does not")
					found = true
					break
				end
			end
			if found then break end
		end
		assert(found, "some slab of a side wall stands proud")
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
	local function pockets_fit(made)
		for b = 1, made do
			local p = M.pockets[b]
			local lo, hi = M.wall_span(p.wall)
			assert(p.u0 - 1 >= lo and p.u0 + p.su <= hi,
					"pocket " .. b .. " and its columns are on the " ..
					p.wall .. " wall")
			for c = 1, b - 1 do
				local q = M.pockets[c]
				if q.wall == p.wall then
					assert(p.u0 + p.su <= q.u0 - 1 or
							q.u0 + q.su <= p.u0 - 1,
							"pocket " .. b .. " overlaps pocket " .. c)
				end
			end
		end
	end
	M.set_pockets(11)
	assert(#M.pockets == 11, "eleven things, eleven pockets")
	pockets_fit(11)
	-- **The order is the wall the player faces, from its middle
	-- outwards** ([POCKETS_ROUND]): a small tree fills the middle of
	-- one wall and nothing else, and nothing is behind the player until
	-- everything in front of them is taken
	do
		M.set_pockets(3)
		for b = 1, 3 do
			assert(M.pockets[b].wall == "front",
					"three pockets are all on the faced wall")
		end
		local lo, hi = M.wall_span("front")
		local mid = math.floor((lo + hi) / 2)
		assert(math.abs(M.bay_u(0) - mid) <= 2,
				"the first pocket is in the middle of the faced wall")
		local made = M.set_pockets(M.max_pockets())
		local seen = {}
		for b = 1, made do seen[M.pockets[b].wall] = true end
		for _, w in ipairs(M.WALL_ORDER) do
			assert(seen[w], "a full room has pockets on the " .. w .. " wall")
		end
		assert(M.pockets[made].wall == "back",
				"the wall behind the player fills last")
	end
	-- **A pocket on any wall is a pocket**: cut into the stone, with an
	-- ornamented column down each side of its mouth, wherever the
	-- allocation put it -- including the corners, where the front
	-- wall's mass claims the voxels a side wall's pocket is cut into
	do
		local made = M.set_pockets(30)
		for b = 1, made do
			local p = M.pockets[b]
			local u, y = M.bay_u(b - 1), M.bay_y(b - 1)
			local n = p.mouth + M.WALL_IN[p.wall]
			local x, yy, z = M.wall_xyz(p.wall, u, y, n)
			assert(M.voxel_at(x, yy, z) == M.id.air,
					"pocket " .. b .. " (" .. p.wall .. ") is a hole")
			local ax, ay, az = M.wall_xyz(p.wall, p.u0 - 1, y, n)
			local bx, byy, bz = M.wall_xyz(p.wall, p.u0 + p.su, y, n)
			assert(M.voxel_at(ax, ay, az) == M.id.column and
					M.voxel_at(bx, byy, bz) == M.id.column,
					"pocket " .. b .. " (" .. p.wall ..
					") has a column down each side")
		end
	end
	-- **More things than the walls can hold** is answered, not broken:
	-- the pockets that are made still fit and do not overlap, and the
	-- count says how many the room may put in its walls
	do
		local made = M.set_pockets(200)
		assert(made == M.max_pockets(), "the walls say what they hold")
		pockets_fit(made)
	end
	M.set_pockets(M.BAYS)
	-- **The other three walls have relief of their own**, and are not
	-- copies of each other: each one's depth has to vary along it, and
	-- the three have to disagree somewhere
	local depths = {}
	for _, name in ipairs({"left", "right", "back"}) do
		local lo, hi = nil, nil
		for u = M.X_MIN, M.X_MAX do
			local d = M.side_in(name, u, 4)
			lo = (lo == nil or d < lo) and d or lo
			hi = (hi == nil or d > hi) and d or hi
		end
		assert(hi > lo, "the " .. name .. " wall is flat")
		depths[name] = hi .. ":" .. lo
	end
	assert(depths.left ~= depths.right or depths.left ~= depths.back,
			"the three walls are the same wall")
	assert(#rows[1] == M.W, "a row is the room across: " .. #rows[1])
	assert(M.row_index(M.OY, M.OZ) == 1, "the first row is the first row")
	return true
end

if ... == nil then
	assert(M.self_check())
	-- **A sandbox has no print** ([LAUNCH_SANDBOX]: the room loads its
	-- own files through a verb now, which runs them in the sandbox), and
	-- the line is for a person running this under plain `lua` anyway
	if print then
		print("room.lua: ok, " .. M.W .. "x" .. M.H .. "x" .. M.D ..
				" voxels")
	end
end

return M
