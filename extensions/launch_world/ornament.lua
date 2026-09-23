-- [LAUNCH_WORLD]: the recursive ornament generator, and the maps it feeds
-- the material library.
--
-- **One height field and one inlay mask per texture; everything else is
-- derived.** The height carries the relief -- the meander's band, the
-- socket field's holes -- and the inlay says where a second material is
-- set into the first. From those two come the albedo, the normal and
-- (later) the roughness, and the same height thresholded is what carves
-- the voxels once the room is a voxelworld, so a pattern is authored once
-- and appears both as relief on a face and as shape in the grid.
--
-- Nothing here is loaded from a file: the room's whole point is how much
-- a program can leave out, and a texture is a few hundred lines of Lua
-- against a few megabytes of PNG.
-- Its own, rather than world.lua's: a file run on its own has no
-- globals of the room's ([LAUNCH_SANDBOX]'s run_extension_file).
-- **require answers the safe interface inside the sandbox and the whole
-- extension outside it**, which is the one difference the two contexts
-- have that a file like this can see. Asked by something the safe half
-- has, because it raises on a name it does not know rather than
-- answering nil -- so `urho3d.safe` is not a question that can be put
-- to it.
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe

local M = {}

-- A generator with its own state, because the sandbox shares math.random
-- and a pattern has to be the same every session: a server's address
-- seeds its own sigil, and a slab keeps its face between runs.
-- simplified: a 32-bit xorshift, which is plenty for deciding which
-- quadrant to raise; the upgrade is nothing, since nobody is betting on
-- it.
local function rng(seed)
	local s = seed % 2147483647
	if s <= 0 then s = s + 2147483646 end
	return function(n)
		s = (s * 16807) % 2147483647
		return n and (s % n) + 1 or s / 2147483647
	end
end

-- A string's seed, so "example.org:30000" always draws the same sigil
function M.seed_of(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 33 + text:byte(i)) % 2147483647
	end
	return h
end

-- A field is a flat array of size*size numbers in 0..1, indexed from 1
-- (declared before the patterns, which all build one)
local function field(size, v)
	local f = {size = size}
	for i = 1, size * size do
		f[i] = v or 0
	end
	return f
end
M.field = field

local function at(f, x, y)
	if x < 0 or y < 0 or x >= f.size or y >= f.size then
		return 0
	end
	return f[y * f.size + x + 1]
end
M.at = at

local function put(f, x, y, v)
	if x < 0 or y < 0 or x >= f.size or y >= f.size then
		return
	end
	f[y * f.size + x + 1] = v
end

local function box(f, x0, y0, w, h, v)
	for y = y0, y0 + h - 1 do
		for x = x0, x0 + w - 1 do
			put(f, x, y, v)
		end
	end
end
M.box = box

-- **The meander**, which is the Greek key of the reference frame. One
-- unit is a square spiral drawn as a walked path; the band repeats it
-- along the texture and mirrors every other one, which is what makes it
-- read as a chain rather than as a row of stamps.
--
-- Recursive because the plan asks for it and because it is what the
-- classical version does: at depth > 1 the unit's own centre carries a
-- smaller meander, so a slab looked at closely has ornament inside its
-- ornament.
local function meander_unit(h, x0, y0, n, t, depth)
	-- t is the stroke, n the unit's side. The spiral: three sides of a
	-- square, then in by 2t and around again, until there is no room.
	local x, y, s = x0, y0, n
	local turns = 0
	while s > t * 3 and turns < 6 do
		box(h, x, y, s, t, 1)                    -- top
		box(h, x + s - t, y, t, s, 1)            -- right
		box(h, x, y + s - t, s - t * 2, t, 1)    -- bottom, short
		x = x + t * 2
		y = y + t * 2
		s = s - t * 4
		turns = turns + 1
	end
	if depth > 1 and n > t * 10 then
		meander_unit(h, x0 + n / 4, y0 + n / 4, n / 2, math.max(1, t / 2),
				depth - 1)
	end
end

-- size: the texture's side. band: how tall the ornamented strip is, as a
-- share of it -- the rest is plain face, which is what a slab mostly is.
function M.meander(size, opts)
	opts = opts or {}
	local h = field(size)
	local inlay = field(size)
	local units = opts.units or 4
	local n = math.floor(size / units)
	local t = math.max(1, math.floor(n / 7))
	local band_y = math.floor(size * (opts.band_y or 0.30))
	for u = 0, units - 1 do
		meander_unit(h, u * n, band_y, n, t, opts.depth or 2)
	end
	-- The band's own edges: two rules above and below it, which is what
	-- separates ornament from face in every classical frieze
	box(h, 0, band_y - t * 2, size, t, 1)
	box(h, 0, band_y + n + t, size, t, 1)
	-- The inlay is the band itself: a second material set into the stone,
	-- which is where the room's purple goes ([LAUNCH_WORLD]'s colour
	-- roles: structure and ornament, never state)
	box(inlay, 0, band_y - t * 2, size, n + t * 4, 1)
	return h, inlay
end

-- **The socket field**: the perforated blocks of the reference frame,
-- and the one pattern that is a grid rather than a path. Recursive by
-- subdivision -- a cell either takes a socket or splits into four, so
-- the field has more than one scale in it without a second algorithm.
local function socket_cell(h, inlay, x0, y0, n, r, depth)
	if depth > 0 and n > 12 and r() < 0.45 then
		local m = math.floor(n / 2)
		for _, q in ipairs({{0, 0}, {m, 0}, {0, m}, {m, m}}) do
			socket_cell(h, inlay, x0 + q[1], y0 + q[2], m, r, depth - 1)
		end
		return
	end
	local pad = math.max(1, math.floor(n / 5))
	local s = n - pad * 2
	if s < 2 then
		return
	end
	-- The socket is a recess, so it is low where the face is high
	box(h, x0 + pad, y0 + pad, s, s, 0)
	box(inlay, x0 + pad, y0 + pad, s, s, 1)
	-- ...with a lip around it, which is what catches a raking light
	local lip = math.max(1, math.floor(pad / 2))
	box(h, x0 + pad - lip, y0 + pad - lip, s + lip * 2, lip, 1)
	box(h, x0 + pad - lip, y0 + pad + s, s + lip * 2, lip, 1)
	box(h, x0 + pad - lip, y0 + pad, lip, s, 1)
	box(h, x0 + pad + s, y0 + pad, lip, s, 1)
end

function M.sockets(size, opts)
	opts = opts or {}
	local h = field(size, 0.55)
	local inlay = field(size)
	local r = rng(opts.seed or 12345)
	local cells = opts.cells or 4
	local n = math.floor(size / cells)
	for cy = 0, cells - 1 do
		for cx = 0, cells - 1 do
			socket_cell(h, inlay, cx * n, cy * n, n, r, opts.depth or 2)
		end
	end
	return h, inlay
end

-- **A sigil**, which is what a server gets instead of a logo: its
-- address seeds a recursive subdivision, so the pattern is its own, the
-- same every session, and no asset anywhere. Mirrored twice, because a
-- mark reads as a mark when it is symmetric and as noise when it is not.
function M.sigil(size, seed, depth)
	local h = field(size)
	local inlay = field(size)
	local r = rng(seed)
	local half = math.floor(size / 2)
	local function carve(x0, y0, n, d)
		if n < 3 then
			return
		end
		if d <= 0 or r() < 0.30 then
			box(h, x0, y0, n, n, 1)
			if r() < 0.5 then
				box(inlay, x0, y0, n, n, 1)
			end
			return
		end
		local m = math.floor(n / 2)
		for _, q in ipairs({{0, 0}, {m, 0}, {0, m}, {m, m}}) do
			if r() < 0.62 then
				carve(x0 + q[1], y0 + q[2], m, d - 1)
			end
		end
	end
	carve(0, 0, half, depth or 4)
	-- The two mirrors
	for y = 0, half - 1 do
		for x = 0, half - 1 do
			local v, iv = at(h, x, y), at(inlay, x, y)
			put(h, size - 1 - x, y, v);        put(inlay, size - 1 - x, y, iv)
			put(h, x, size - 1 - y, v);        put(inlay, x, size - 1 - y, iv)
			put(h, size - 1 - x, size - 1 - y, v)
			put(inlay, size - 1 - x, size - 1 - y, iv)
		end
	end
	return h, inlay
end

-- **A mark for an orb**: the same recursion as a sigil, but kept to the
-- middle of the texture and mirrored left-to-right only, so that on
-- Sphere.mdl's spherical UVs it reads as one mark on one face rather
-- than a pattern wrapped round the ball. White is the orb's own light;
-- the mark is the hole cut in it.
--
-- simplified: generated from the name rather than taken from the
-- launchable's own icon (`M.launch = {title, icon, run}`), because this
-- room has no launchables in it yet. The upgrade is drawing the icon
-- into the same middle region, which changes nothing else.
function M.mark(size, seed)
	local f = field(size, 1)
	local r = rng(seed)
	local m0, m1 = math.floor(size * 0.30), math.floor(size * 0.70)
	local n = m1 - m0
	local function carve(x0, y0, w, d)
		if w < 3 then
			return
		end
		if d <= 0 or r() < 0.34 then
			box(f, x0, y0, w, w, 0)
			return
		end
		local h = math.floor(w / 2)
		for _, q in ipairs({{0, 0}, {h, 0}, {0, h}, {h, h}}) do
			if r() < 0.66 then
				carve(x0 + q[1], y0 + q[2], h, d - 1)
			end
		end
	end
	carve(m0, m0, math.floor(n / 2), 3)
	-- One mirror, so it is a mark and not noise
	for y = m0, m1 - 1 do
		for x = m0, m0 + math.floor(n / 2) - 1 do
			put(f, m1 - 1 - (x - m0), y, at(f, x, y))
		end
	end
	return f
end

-- **The wall's own material** (user, 2026-09-22): a matte finished,
-- clean cut stone surface with large patches of mineral variation. Not
-- rough and not carved -- the "knobby" of the first reading is the
-- coursing of the cut blocks, not a bumpy texture. So the height field
-- is flat but for the block seams, and the only real variation is slow,
-- large-scale mineral blotching in the albedo.
--
-- It is meant to be seen across many voxels at once, which is what
-- uv_scale is for ([WORLD_UV]): at one repeat per voxel a patch larger
-- than 45 cm cannot exist and the biggest surface in the room reads as
-- a grid of identical stamps.
--
-- simplified: the blotches are one octave of value noise. Two or three
-- would break up the remaining regularity; one is enough to tell
-- whether the wall reads as stone, which is what it is for now.
local function value_noise(size, cells, r)
	-- A coarse grid of random values, read back bilinearly: slow, large
	-- patches rather than texel noise
	local g = {}
	for i = 0, (cells + 1) * (cells + 1) - 1 do
		g[i] = r()
	end
	local function at_cell(cx, cy)
		return g[(cy % (cells + 1)) * (cells + 1) + (cx % (cells + 1))]
	end
	local f = field(size)
	local step = size / cells
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local fx, fy = x / step, y / step
			local x0, y0 = math.floor(fx), math.floor(fy)
			local tx, ty = fx - x0, fy - y0
			-- Smoothstep, so the patches have no grid in their edges
			tx = tx * tx * (3 - 2 * tx)
			ty = ty * ty * (3 - 2 * ty)
			local a = at_cell(x0, y0) + (at_cell(x0 + 1, y0) -
					at_cell(x0, y0)) * tx
			local b = at_cell(x0, y0 + 1) + (at_cell(x0 + 1, y0 + 1) -
					at_cell(x0, y0 + 1)) * tx
			put(f, x, y, a + (b - a) * ty)
		end
	end
	return f
end

function M.wall(size, seed, opts)
	opts = opts or {}
	local r = rng(seed)
	-- The coursing: horizontal beds every course_h texels, and the
	-- vertical joints offset by half a block course to course, which is
	-- what dressed stone does and what keeps the seams from lining up
	local h = field(size, 0.72)
	local course = opts.course or math.floor(size / 6)
	local block = opts.block or math.floor(size / 3)
	for y = 0, size - 1 do
		local row = math.floor(y / course)
		local bed = (y % course) == 0
		for x = 0, size - 1 do
			local jx = (x + (row % 2) * math.floor(block / 2)) % block
			if bed or jx == 0 then
				-- A seam is a narrow recess, which is all the relief
				-- this surface has
				put(h, x, y, 0.30)
			end
		end
	end
	-- The mineral patches, in the albedo only: the inlay mask carries
	-- them and maps() tints by it
	local blotch = value_noise(size, opts.cells or 4, r)
	local inlay = field(size)
	for i = 1, size * size do
		-- A patch is where the noise is high, with a soft edge so it
		-- reads as mineral rather than as a stain
		local v = blotch[i]
		inlay[i] = v > 0.58 and math.min(1, (v - 0.58) * 3.2) or 0
	end
	return h, inlay
end

-- The maps, derived and not authored.
--
-- simplified: the relief goes into the **albedo** as a shade as well as
-- into the normal map. Urho3D's shipped Box.mdl and Sphere.mdl carry no
-- vertex tangents, so a normal map alone would do nothing on them; the
-- baked shade is what makes the ornament visible either way. The upgrade
-- is tangents on the models the room actually uses, at which point the
-- shade can come out.
-- simplified: no roughness map -- the material's own Roughness uniform
-- stands for the whole face. The upgrade is a spec map with roughness in
-- its red channel, which is where Urho3D's PBR shaders read it.
function M.maps(magic, h, inlay, opts)
	opts = opts or {}
	local size = h.size
	local base = opts.base or magic.Color(0.30, 0.30, 0.33, 1)
	local tint = opts.inlay or magic.Color(0.34, 0.16, 0.42, 1)
	local relief = opts.relief or 0.45
	local diff = magic.Image:new()
	assert(diff:SetSize(size, size, 3), "Image:SetSize")
	local norm = magic.Image:new()
	assert(norm:SetSize(size, size, 3), "Image:SetSize")
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			-- The normal, by Sobel on the height
			local nx = (at(h, x - 1, y) - at(h, x + 1, y)) * (opts.strength or 3)
			local ny = (at(h, x, y - 1) - at(h, x, y + 1)) * (opts.strength or 3)
			local l = math.sqrt(nx * nx + ny * ny + 1)
			norm:SetPixel(x, y, magic.Color(nx / l * 0.5 + 0.5,
					ny / l * 0.5 + 0.5, 1 / l * 0.5 + 0.5, 1))
			-- The albedo: the base, tinted where the inlay is, shaded by
			-- the relief as if lit from the upper left
			local c = at(inlay, x, y) > 0.5 and tint or base
			local s = 1 - relief + relief * (0.5 + 0.5 * (nx - ny) / l +
					0.35 * at(h, x, y))
			diff:SetPixel(x, y, magic.Color(c.r * s, c.g * s, c.b * s, 1))
		end
	end
	return diff, norm
end

-- The generator's own check, run at boot and said in one line: these
-- are patterns, so what can be asserted is that each one is a pattern --
-- that it covers a sane share of its field, that the sigil is symmetric
-- because it is mirrored twice, and that the socket field has both a
-- face and a recess in it. A generator that quietly returns a flat field
-- would pass an eye on a dark slab and fail here.
function M.self_check(size)
	size = size or 128
	local function coverage(f)
		local n = 0
		for i = 1, f.size * f.size do
			if f[i] > 0.5 then n = n + 1 end
		end
		return n / (f.size * f.size)
	end
	local mh = M.meander(size, {units = 3, depth = 2})
	local mc = coverage(mh)
	assert(mc > 0.03 and mc < 0.45,
			"the meander covers " .. mc .. " of its field")
	local sh = M.sockets(size, {cells = 3, depth = 2, seed = 7})
	local sc = coverage(sh)
	assert(sc > 0.15 and sc < 0.95,
			"the socket field covers " .. sc)
	-- Both a face and a recess: a socket is low where the face is high
	local low = false
	for i = 1, sh.size * sh.size do
		if sh[i] < 0.1 then low = true break end
	end
	assert(low, "the socket field has recesses")
	local gh = M.sigil(size, M.seed_of("buildat.example.org:30000"), 4)
	local off = 0
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			if M.at(gh, x, y) ~= M.at(gh, size - 1 - x, y) then
				off = off + 1
			end
		end
	end
	assert(off == 0, "the sigil is mirrored, " .. off .. " texels differ")
	-- And a different address is a different sigil, which is the whole
	-- point of seeding it with one
	local other = M.sigil(size, M.seed_of("elsewhere.net:30000"), 4)
	local same = 0
	for i = 1, size * size do
		if gh[i] == other[i] then same = same + 1 end
	end
	assert(same < size * size * 0.95,
			"two addresses draw two sigils, " .. same .. " texels shared")
	return string.format("ornament ok: meander %.0f%% of its field, " ..
			"sockets %.0f%%, the sigil mirrored and %.0f%% unlike another " ..
			"address's", mc * 100, sc * 100, 100 - same / (size * size) * 100)
end

return M
