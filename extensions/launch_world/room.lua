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
-- **Centred in the room** (user, 2026-09-25), which is the interior
-- between the wall faces: x from X_MIN + SIDE_IN - 1 to X_MAX - SIDE_IN
-- + 1, centred on 0, and z from the pocket wall's BAY_Z to the back
-- wall's face, centred on 12. It hung eight voxels toward the pocket
-- wall before, so from the standing place it read as a bright square
-- ahead rather than as the room's own opening.
M.OPEN_X0, M.OPEN_X1 = -9, 9
M.OPEN_Z0, M.OPEN_Z1 = 4, 20

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

-- **One wall** ([LAUNCH_WORLD] stage 2, sections 4 and 5: the three
-- other walls are cut). A pocket is still described in its wall's frame
-- -- u along it, n on its normal, and which way is into the stone -- so
-- the questions below keep their shape; there is one wall to ask them
-- of. The room's other three sides are the plain stone boundary.
M.WALL_ORDER = {"front"}
-- Which room axis runs along the wall; the other one is its normal
M.WALL_U = {front = "x"}
-- Which way is into the stone, on the normal axis
M.WALL_IN = {front = -1}

-- The plane the wall's relief is measured from
function M.nominal_face(w)
	return M.BAY_Z
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
-- **Not over the formation** ([LAUNCH_WORLD] stage 2): the games stand
-- in rows on a flat face, so a slab or an inset inside the formation's
-- rectangle (and a voxel round it) is left out -- whether random relief
-- around a regular formation reads as calm or as noise is stage 3's.
-- The rectangle is set by set_pockets(); until then there is none.
M.form = nil

-- **The architecture, as an options round** ([LAUNCH_WORLD] stage 3, the
-- architecture; local/options_for_LOBBY_arch/): one knob in world.lua,
-- BUILDAT_LAUNCH_ARCH=<name>, each a whole wall rather than a slider, so
-- the user's pick is a one-word default. "tomb" is the wall as stage 2
-- left it and stays the default until the pick.
--   random    the hashed slabs, at the proof's density
--   insets    the hashed rectangles cut back
--   margin    voxels round the formation kept clear of both
--   edges     the random relief only where the wall is left and right of
--             the formation's frame, the middle bare
--   frame     a cornice over the top row, a plinth under the bottom one
--             and a pilaster of stacked slabs either side, standing out
--   shelves   a ledge one voxel proud under every row of pockets, the
--             frieze along it: the ornament as the rows' own line
--   ornament  the frieze on proud faces and the columns down a mouth;
--             false is the same stone everywhere
M.ARCHES = {
	tomb = {random = true, insets = true, margin = 1, ornament = true},
	-- Random relief around a regular framing, nothing random inside it
	calm = {random = true, insets = true, margin = 5, frame = true,
		shelves = true, ornament = true},
	-- The same framing in plain stone: the ornament is none of it
	plain = {random = true, insets = true, margin = 5, frame = true,
		shelves = true, ornament = false},
	-- The wall plain stone, its relief only at the two edges
	bare = {random = true, edges = true, margin = 6, ornament = true},
	-- **The round again, by axis** (user, 2026-10-03: the four above
	-- showed almost no difference): tomb with one thing pushed far
	-- enough to be told apart in a thumbnail, for the user to say which
	-- axes matter. `size` sets room constants (defaults in DEFAULT_SIZE)
	--   deep    the relief's depth: slabs 10 to 18 out, not 3 to 8
	deep = {random = true, insets = true, margin = 1, ornament = true,
		size = {SLAB_OUT_MIN = 10, SLAB_OUT_MAX = 18}},
	--   rhythm  the relief's rhythm: every slab 8 wide on a 12-voxel grid
	--           and every fourth course, none random in place or size
	rhythm = {random = true, insets = false, margin = 1, ornament = true,
		rhythm = true},
	--   tall    the room's height: the ceiling at 44, not 26
	tall = {random = true, insets = true, margin = 1, ornament = true,
		size = {MIN_Y_TOP = 44}},
	--   wide    the room's width: 145 voxels across, not 93
	wide = {random = true, insets = true, margin = 1, ornament = true,
		size = {X_MIN = -72, X_MAX = 72}},
}
-- What an arch's `size` may set, as the room is without one: taken at
-- the first set_arch(), as some are set further down this file
local DEFAULT_SIZE = nil
M.ARCH, M.arch = "tomb", M.ARCHES.tomb
-- Answers the name it took, "tomb" for one there is none by. Before
-- set_pockets() and before anything reads the room's size
function M.set_arch(name)
	if not M.ARCHES[name] then name = "tomb" end
	M.ARCH, M.arch = name, M.ARCHES[name]
	DEFAULT_SIZE = DEFAULT_SIZE or {SLAB_OUT_MIN = M.SLAB_OUT_MIN,
		SLAB_OUT_MAX = M.SLAB_OUT_MAX, MIN_Y_TOP = M.MIN_Y_TOP,
		X_MIN = M.X_MIN, X_MAX = M.X_MAX}
	for k, v in pairs(DEFAULT_SIZE) do
		M[k] = (M.arch.size or {})[k] or v
	end
	M.OX = M.X_MIN - 1
	M.W = M.X_MAX - M.X_MIN + 3
	return name
end
local function in_form(x0, x1, y0, y1)
	local f = M.form
	local m = M.arch.margin or 1
	return f ~= nil and x1 >= f.x0 - m and x0 <= f.x1 + m and
			y1 >= f.y0 - m and y0 <= f.y1 + m
end
-- Whether a slab would stand in the middle a bare wall keeps clear: the
-- formation's columns, top to bottom
local function in_middle(x0, x1)
	local f = M.form
	local m = M.arch.margin or 1
	return f ~= nil and x1 >= f.x0 - m and x0 <= f.x1 + m
end
-- **As many as the wall is tall**: sixty to the proof's 27 voxels, the
-- same density on a wall that grows with its rows
local function make_slabs()
	M.slabs = {}
	local n = math.floor(M.SLABS * (M.Y_TOP + 1) / 27)
	for i = 1, n do
		local h1 = hash2(i, 1, 11)
		local h2 = hash2(i, 2, 22)
		local span = M.SLAB_MAX - M.SLAB_MIN + 1
		local sx = M.SLAB_MIN + math.floor(h1 / 8) % span
		local sy = M.SLAB_THIN_MIN + math.floor(h1 / 4096) %
				(M.SLAB_THIN_MAX - M.SLAB_THIN_MIN + 1)
		local x0 = M.X_MIN + h2 % (M.X_MAX - M.X_MIN - sx + 1)
		local y0 = math.floor(h2 / 2048) % (M.Y_TOP - sy + 1)
		if M.arch.rhythm then
			sx, sy = 8, 1
			x0 = M.X_MIN + 2 + 12 * (h2 % math.floor((M.X_MAX - M.X_MIN - 10) / 12))
			y0 = 4 * (math.floor(h2 / 2048) % math.floor(M.Y_TOP / 4 + 1))
			h1 = 3 * 1048576 -- one depth: 6 out
		end
		if M.arch.random and not in_form(x0, x0 + sx - 1, y0, y0 + sy - 1)
				and not (M.arch.edges and in_middle(x0, x0 + sx - 1)) then
			M.slabs[#M.slabs + 1] = {x0 = x0, x1 = x0 + sx - 1, y0 = y0,
				y1 = y0 + sy - 1,
				out = M.SLAB_OUT_MIN + math.floor(h1 / 1048576) %
						(M.SLAB_OUT_MAX - M.SLAB_OUT_MIN + 1)}
		end
	end
	-- **The framing** (calm, plain): built slabs, aligned to the
	-- formation, so the regular thing on the wall has a regular edge.
	-- They are drawn as any slab is: proud, the frieze on their front.
	local f = M.form
	if f and M.arch.frame then
		local function add(x0, x1, y, out)
			if y >= 0 and y <= M.Y_TOP then
				M.slabs[#M.slabs + 1] = {x0 = x0, x1 = x1, y0 = y,
					y1 = y, out = out, built = true}
			end
		end
		-- A cornice over the top row and a plinth under the bottom one
		add(f.x0 - 3, f.x1 + 3, f.y1 + 2, 3)
		add(f.x0 - 3, f.x1 + 3, f.y0 - 1, 2)
		-- A pilaster either side, one stacked slab a voxel of height
		for y = f.y0, f.y1 + 1 do
			add(f.x0 - 3, f.x0 - 2, y, 2)
			add(f.x1 + 2, f.x1 + 3, y, 2)
		end
	end
	if f and M.arch.shelves then
		-- A ledge under every row, across the formation: the row's own
		-- line, and where the frieze reads as a band
		for r = 1, (M.rows or 0) do
			local p = M.pockets[(r - 1) * M.cols + 1]
			if p then
				M.slabs[#M.slabs + 1] = {x0 = f.x0, x1 = f.x1,
					y0 = p.y0 - 1, y1 = p.y0 - 1, out = 1, built = true}
			end
		end
	end
end
make_slabs()
M.SLAB_OUT = M.SLAB_OUT_MAX     -- the furthest any slab comes out

-- **The pockets, one size, in a formation** ([LAUNCH_WORLD] stage 2,
-- section 5): 3 by 3 by 3 on a regular pitch, so the names beside them
-- line up into columns.
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
	if M.arch.insets and c3 % 16 < 2 and not in_form(x, x, y, y) then
		out = out - (1 + math.floor(c3 / 16) % M.INSET_IN)
	end
	return M.BAY_Z + out
end

-- **Where a wall's stone ends and the room begins**, on the wall's own
-- normal axis and before any pocket is taken into account: the front
-- wall's slabs and insets, or a side wall's own relief off its
-- boundary.
function M.wall_face_raw(w, u, y)
	return slab_face(u, y)
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

-- **The formation** ([LAUNCH_WORLD] stage 2, sections 3 to 5): the games
-- in the launch API's order, in rows read left to right and top to
-- bottom, the way a menu is read. A name stands beside every sphere, to
-- its right, so a column is a sphere and the room its name needs.
--
-- **No height limit**: as many rows as the games need, and the wall,
-- the ceiling and the room's height follow (Y_TOP below). The width is
-- the proof's room's, 93 voxels, which holds six columns at most; more wants a
-- wider room, a constant away.
-- First picks, in voxels, to be read at the wall station once
-- playtested:
-- Five, because a name's room on the screen is the screen's width over
-- the columns whatever the pitch: at six a fifteen-letter name ran into
-- the next sphere at the wall station's distance
M.COLS = 5           -- spheres to a row
M.COL_PITCH = 13     -- a sphere and its name
M.ROW_PITCH = 5      -- a pocket and two voxels of wall
M.FORM_BASE = 3      -- the bottom row's pocket floor, over the floor
M.POCKET = 3         -- one size: across, up and deep
M.TOP_MARGIN = 7     -- wall over the top row
M.MIN_Y_TOP = 26     -- the proof's height, which a small tree keeps
M.POCKET_PITCH = M.COL_PITCH

-- How many columns the room's width holds, the names included
function M.max_cols()
	return math.max(1, math.floor((M.X_MAX - M.X_MIN - 8) / M.COL_PITCH))
end
-- No limit: rows are added as needed
function M.max_pockets()
	return 100000
end

-- Answers how many it made, which is how many it was asked for. Each
-- pocket knows its row (1 at the top) and column (1 at the left).
function M.set_pockets(n)
	n = math.max(1, n)
	M.BAYS = n
	M.pockets = {}
	local cols = math.min(M.COLS, M.max_cols(), n)
	local rows = math.ceil(n / cols)
	-- Centred on the room with the names' room counted: a column is a
	-- pocket and the name beside it, a pitch in all. **The screen's
	-- right is -x** (the camera looks down -z, and Urho3D is
	-- left-handed), so the first column is at the highest x and its
	-- name is on its lower-x side
	local span = cols * M.COL_PITCH
	local left = -math.floor(span / 2)
	for b = 0, n - 1 do
		local row, col = math.floor(b / cols), b % cols
		M.pockets[b + 1] = {wall = "front",
			u0 = left + span - M.POCKET - col * M.COL_PITCH,
			y0 = M.FORM_BASE + (rows - 1 - row) * M.ROW_PITCH,
			su = M.POCKET, sy = M.POCKET, sd = M.POCKET,
			row = row + 1, col = col + 1}
	end
	M.rows, M.cols = rows, cols
	M.form = {x0 = left - 1, x1 = left + span - 1, y0 = M.FORM_BASE - 1,
		y1 = M.FORM_BASE + (rows - 1) * M.ROW_PITCH + M.POCKET}
	-- **The room is as tall as the formation wants**, and what is built
	-- off the height is measured again
	M.Y_TOP = math.max(M.MIN_Y_TOP, M.form.y1 + M.TOP_MARGIN)
	M.H = M.Y_TOP - M.FLOOR_BOTTOM + 3
	make_slabs()
	face_cache = {}
	wall_cache = {}
	-- **A pocket has one mouth**: the face at its middle, settled once;
	-- the formation's face is flat, so every mouth is the nominal plane
	for i = 1, n do
		local p = M.pockets[i]
		p.mouth = M.wall_face_raw(p.wall, p.u0 + math.floor(p.su / 2),
				p.y0 + math.floor(p.sy / 2))
	end
	face_cache = {}
	wall_cache = {}
	return n
end

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
				return M.arch.ornament and id.column or id.stone
			end
		end
		-- **The slab's own edge wears the frieze.** A slab is one voxel
		-- tall, so the strip a player sees is its outermost voxel, and
		-- that is where the ornament goes; the mass behind it is plain
		-- stone. A voxel is that edge when it is the front of a face
		-- that stands proud of the wall's nominal surface.
		local _, n = M.wall_un(w, x, y, z)
		if n == face and M.arch.ornament and
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
-- The formation for the default count, so that this file runs alone; it
-- sets the room's height, which the block above is measured with
M.set_pockets(M.BAYS)

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
	M.set_pockets(11)
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
	for i = 1, #M.slabs do
		local s = M.slabs[i]
		local sx, sy = s.x1 - s.x0 + 1, s.y1 - s.y0 + 1
		assert(s.built or sx >= M.SLAB_MIN and sx <= M.SLAB_MAX,
				"slab " .. i .. " is " .. sx .. " across")
		assert(sy >= M.SLAB_THIN_MIN and sy <= M.SLAB_THIN_MAX,
				"slab " .. i .. " is " .. sy .. " thick")
		assert(sx > sy, "slab " .. i .. " is wider than it is thick")
		assert(s.x0 >= M.X_MIN and s.x1 <= M.X_MAX and s.y0 >= 0 and
				s.y1 <= M.Y_TOP, "slab " .. i .. " is on the wall")
	end
	-- **The formation**: rows of five read left to right and top down,
	-- every pocket one size, on one pitch, on a flat face, each a hole
	-- with an ornamented column down each side of its mouth
	local function formation_ok(n)
		local made = M.set_pockets(n)
		assert(made == n, n .. " things, " .. made .. " pockets")
		assert(M.rows == math.ceil(n / M.cols), "as many rows as needed")
		for b = 1, n do
			local p = M.pockets[b]
			assert(p.su == M.POCKET and p.sy == M.POCKET and
					p.sd == M.POCKET, "one size of pocket")
			assert(p.mouth == M.BAY_Z, "pocket " .. b .. " is on the face")
			assert(p.u0 - 1 >= M.X_MIN and p.u0 + p.su <= M.X_MAX,
					"pocket " .. b .. " is on the wall")
			assert(p.y0 + p.sy <= M.Y_TOP, "pocket " .. b .. " is under the ceiling")
			if b > 1 then
				local q = M.pockets[b - 1]
				if p.row == q.row then
					assert(q.u0 - p.u0 == M.COL_PITCH and p.y0 == q.y0,
							"a row on one pitch, toward -x")
				else
					assert(p.row == q.row + 1 and p.col == 1 and
							q.y0 - p.y0 == M.ROW_PITCH,
							"the next row is below, from the left")
				end
			end
			local u, y = M.bay_u(b - 1), M.bay_y(b - 1)
			local nn = p.mouth + M.WALL_IN[p.wall]
			local x, yy, z = M.wall_xyz(p.wall, u, y, nn)
			assert(M.voxel_at(x, yy, z) == M.id.air,
					"pocket " .. b .. " is a hole")
			local ax, ay, az = M.wall_xyz(p.wall, p.u0 - 1, y, nn)
			local bx, by, bz = M.wall_xyz(p.wall, p.u0 + p.su, y, nn)
			assert(M.voxel_at(ax, ay, az) == M.id.column and
					M.voxel_at(bx, by, bz) == M.id.column,
					"pocket " .. b .. " has a column down each side")
		end
		-- No slab or inset inside the formation's rectangle
		local f = M.form
		for x = f.x0, f.x1 do
			for y = f.y0, f.y1 do
				if not M.in_pocket(x, y, M.BAY_Z) then
					assert(M.face_z(x, y) == M.BAY_Z,
							"the formation's face is flat at " .. x .. "," .. y)
				end
			end
		end
	end
	formation_ok(1)
	formation_ok(5)
	formation_ok(6)
	formation_ok(30)
	-- **No height limit**: sixty games stand in twelve rows, and the
	-- room is as tall as that
	formation_ok(60)
	assert(M.rows == 12 and M.Y_TOP >= M.form.y1 + M.TOP_MARGIN,
			"the wall grows with its rows")
	local tall = M.Y_TOP
	M.set_pockets(5)
	assert(M.Y_TOP == M.MIN_Y_TOP and M.Y_TOP < tall,
			"and a small tree keeps the proof's height")
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
	-- **The three other walls are cut**: from the pocket wall to the
	-- boundary the room is open, at every side
	assert(M.voxel_at(M.X_MIN, 5, 10) == M.id.air and
			M.voxel_at(M.X_MAX, 5, 10) == M.id.air and
			M.voxel_at(0, 5, M.Z_MAX) == M.id.air,
			"no wall but the pocket wall")
	assert(M.voxel_at(M.X_MIN - 1, 5, 10) == M.id.stone,
			"and the boundary is stone")
	assert(M.voxel_at(0, M.Y_TOP + 2, 4) == M.id.air,
			"the opening is cut through the ceiling")
	assert(M.voxel_at(M.OPEN_X1 + 2, M.Y_TOP + 2, 4) == M.id.stone,
			"and the ceiling beside it is not")
	assert(M.voxel_at(0, -1, 0) ~= M.voxel_at(2, -1, 0), "the floor checkers")
	assert(M.voxel_at(0, -1, 0) == M.voxel_at(1, -1, 1) or
			M.voxel_at(0, -1, 0) == M.voxel_at(0, -1, 1),
			"a checker square is two voxels")
	-- **The architectures** (stage 3's round): each builds, and each is
	-- what its line in M.ARCHES says
	for name in pairs(M.ARCHES) do
		assert(M.set_arch(name) == name, "the arch " .. name)
		M.set_pockets(11)
		local f = M.form
		local p = M.pockets[1]
		local shelf = M.face_z(f.x0 + 1, p.y0 - 1)
		if M.arch.shelves then
			assert(shelf == M.BAY_Z + 1, name .. ": a ledge under the row")
			assert(M.voxel_at(f.x0 + 1, p.y0 - 1, shelf) ==
					(M.arch.ornament and M.id.frieze or M.id.stone),
					name .. ": the ledge's front")
		end
		if M.arch.frame then
			assert(M.face_z(f.x0, f.y1 + 2) == M.BAY_Z + 3,
					name .. ": a cornice over the top row")
		end
		if not M.arch.ornament then
			for x = f.x0 - 4, f.x1 + 4 do
				for y = 0, M.Y_TOP do
					local v = M.voxel_at(x, y, M.face_z(x, y))
					assert(v ~= M.id.frieze and v ~= M.id.column,
							name .. ": no ornament")
				end
			end
		end
		for k, v in pairs(M.arch.size or {}) do
			assert(M[k] == v, name .. ": " .. k)
		end
		if M.arch.rhythm then
			for _, sl in ipairs(M.slabs) do
				assert(sl.x1 - sl.x0 == 7 and (sl.x0 - M.X_MIN - 2) % 12 == 0 and
						sl.y0 % 4 == 0, name .. ": a slab on the grid")
			end
		end
		if M.arch.edges then
			for x = f.x0 - 5, f.x1 + 5 do
				for y = 0, M.Y_TOP do
					if not M.in_pocket(x, y, M.BAY_Z) then
						assert(M.face_z(x, y) == M.BAY_Z,
								name .. ": flat between the edges")
					end
				end
			end
		end
	end
	M.set_arch("tomb")
	assert(M.X_MIN == -46 and M.W == 95 and M.MIN_Y_TOP == 26,
			"tomb puts the size back")
	M.set_pockets(11)
	local rows = M.build()
	assert(#rows == M.H * M.D, "one row a (y, z): " .. #rows)
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
