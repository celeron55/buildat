-- Buildat: games/floorplanner/main/client_lua/geom.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The plan's 2D geometry, in millimetres, knowing neither Urho3D nor the
-- network: wall outlines with their joins, triangulation, and the small
-- vector helpers the editor picks with. Plan coordinates are (x, z), which
-- are the world's X and Z; seen from above, +X is right and +Z is up, so
-- "left" of a direction is its counter-clockwise side. The self-checks at
-- the end run every time the file loads.
local M = {}

-- Below this the mitre point runs off; the join is capped flat instead
M.MITRE_LIMIT = 4

local function len(x, z)
	return math.sqrt(x * x + z * z)
end
M.len = len

local function cross(ax, az, bx, bz)
	return ax * bz - az * bx
end

-- How far a wall's two faces are from its a->b line: (left, right)
function M.offsets(thickness, justify)
	if justify == 1 then
		return thickness, 0
	elseif justify == 2 then
		return 0, thickness
	end
	return thickness / 2, thickness / 2
end

-- Where lines p + s*u and q + t*v meet, or nil when parallel
local function intersect(px, pz, ux, uz, qx, qz, vx, vz)
	local d = cross(ux, uz, vx, vz)
	if math.abs(d) < 1e-9 then
		return nil
	end
	local s = cross(qx - px, qz - pz, vx, vz) / d
	return px + ux * s, pz + uz * s
end

-- walls: {id = {ax, az, bx, bz, thickness, justify, group}}, the ends
-- already looked up. Walls join only within one group (standing and
-- hanging walls never do) and only where they share a node:
-- a_node and b_node are the ids that say so.
-- Returns {id = {pts = {{x, z}, ...}, sides = {"right"|"left"|"core", ...}}}:
-- the outline counter-clockwise, sides[i] naming the face from pts[i] to
-- pts[i + 1].
function M.wall_outlines(walls)
	-- Every end at every node, per group
	local at = {}
	for id, w in pairs(walls) do
		local l = len(w.bx - w.ax, w.bz - w.az)
		if l > 0 then
			local ux, uz = (w.bx - w.ax) / l, (w.bz - w.az) / l
			local lo, ro = M.offsets(w.thickness, w.justify)
			for _, e in ipairs({"a", "b"}) do
				local key = (w.group or 0) .. ":" .. w[e .. "_node"]
				at[key] = at[key] or {}
				local end_ = {id = id, e = e, x = w[e .. "x"], z = w[e .. "z"]}
				if e == "a" then
					end_.ux, end_.uz = ux, uz
					-- Seen leaving the node, left is the ccw side
					end_.ccw_off, end_.cw_off = lo, ro
				else
					end_.ux, end_.uz = -ux, -uz
					end_.ccw_off, end_.cw_off = ro, lo
				end
				table.insert(at[key], end_)
			end
		end
	end

	-- Each end's two corner points: ccw_pt on its ccw face, cw_pt on its
	-- cw face, and the node itself where three or more meet, which fills
	-- the hole a T or an X leaves in the middle
	local corners = {}
	for _, ends in pairs(at) do
		for _, en in ipairs(ends) do
			en.angle = math.atan2(en.uz, en.ux)
			-- A flat cap until a neighbour says otherwise
			en.ccw_pt = {en.x - en.uz * en.ccw_off, en.z + en.ux * en.ccw_off}
			en.cw_pt = {en.x + en.uz * en.cw_off, en.z - en.ux * en.cw_off}
		end
		table.sort(ends, function(p, q) return p.angle < q.angle end)
		local n = #ends
		if n >= 2 then
			for i = 1, n do
				local p = ends[i]
				local q = ends[i % n + 1]
				-- p's ccw face meets q's cw face
				local px, pz = p.x - p.uz * p.ccw_off, p.z + p.ux * p.ccw_off
				local qx, qz = q.x + q.uz * q.cw_off, q.z - q.ux * q.cw_off
				local ix, iz = intersect(px, pz, p.ux, p.uz, qx, qz, q.ux, q.uz)
				local limit = M.MITRE_LIMIT *
						math.max(p.ccw_off, q.cw_off, 1)
				if ix and len(ix - p.x, iz - p.z) <= limit then
					p.ccw_pt = {ix, iz}
					q.cw_pt = {ix, iz}
				end
			end
		end
		for _, en in ipairs(ends) do
			corners[en.id] = corners[en.id] or {}
			corners[en.id][en.e] = {ccw = en.ccw_pt, cw = en.cw_pt,
					mid = n >= 3 and {en.x, en.z} or nil}
		end
	end

	local out = {}
	for id, w in pairs(walls) do
		local c = corners[id]
		if c and c.a and c.b then
			-- At a, ccw is left and cw is right; at b the other way round
			local pts, sides = {}, {}
			local function add(p, side)
				pts[#pts + 1] = p
				sides[#sides + 1] = side
			end
			add(c.a.cw, "right")
			add(c.b.ccw, "core")
			if c.b.mid then
				add(c.b.mid, "core")
			end
			add(c.b.cw, "left")
			add(c.a.ccw, "core")
			if c.a.mid then
				add(c.a.mid, "core")
			end
			out[id] = {pts = pts, sides = sides}
		end
	end
	return out
end

-- Twice the signed area; positive when counter-clockwise
local function area2(pts)
	local a = 0
	for i = 1, #pts do
		local p, q = pts[i], pts[i % #pts + 1]
		a = a + cross(p[1], p[2], q[1], q[2])
	end
	return a
end

function M.area(pts)
	return math.abs(area2(pts)) / 2
end

-- Ear clipping. Returns triangles as index triples into pts, each
-- counter-clockwise; nothing for a degenerate polygon.
-- simplified: O(n^3), which is nothing for a wall and fine for a room;
-- a polygon of thousands of corners would want a better one.
function M.triangulate(pts)
	local idx = {}
	for i = 1, #pts do
		idx[i] = i
	end
	if area2(pts) < 0 then
		local r = {}
		for i = #idx, 1, -1 do
			r[#r + 1] = idx[i]
		end
		idx = r
	end
	local tris = {}
	local guard = 0
	while #idx > 3 and guard < 10000 do
		guard = guard + 1
		local found = false
		for i = 1, #idx do
			local ia, ib, ic = idx[(i - 2) % #idx + 1], idx[i], idx[i % #idx + 1]
			local a, b, c = pts[ia], pts[ib], pts[ic]
			local convex = cross(b[1] - a[1], b[2] - a[2],
					c[1] - b[1], c[2] - b[2]) > 1e-9
			if convex then
				local inside = false
				for _, j in ipairs(idx) do
					if j ~= ia and j ~= ib and j ~= ic then
						local p = pts[j]
						if cross(b[1] - a[1], b[2] - a[2], p[1] - a[1], p[2] - a[2]) >= 0 and
								cross(c[1] - b[1], c[2] - b[2], p[1] - b[1], p[2] - b[2]) >= 0 and
								cross(a[1] - c[1], a[2] - c[2], p[1] - c[1], p[2] - c[2]) >= 0 then
							inside = true
							break
						end
					end
				end
				if not inside then
					tris[#tris + 1] = {ia, ib, ic}
					table.remove(idx, i)
					found = true
					break
				end
			end
		end
		if not found then
			-- Collinear leftovers: drop the flattest corner and go on
			table.remove(idx, 1)
		end
	end
	if #idx == 3 and area2({pts[idx[1]], pts[idx[2]], pts[idx[3]]}) > 1e-9 then
		tris[#tris + 1] = {idx[1], idx[2], idx[3]}
	end
	return tris
end

-- The point on segment a-b nearest to p, its parameter t in 0..1 and the
-- distance to it
function M.nearest_on_segment(px, pz, ax, az, bx, bz)
	local dx, dz = bx - ax, bz - az
	local l2 = dx * dx + dz * dz
	local t = 0
	if l2 > 0 then
		t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / l2))
	end
	local x, z = ax + dx * t, az + dz * t
	return x, z, t, len(px - x, pz - z)
end

function M.point_in_polygon(px, pz, pts)
	local inside = false
	local j = #pts
	for i = 1, #pts do
		local a, b = pts[i], pts[j]
		if (a[2] > pz) ~= (b[2] > pz) and
				px < (b[1] - a[1]) * (pz - a[2]) / (b[2] - a[2]) + a[1] then
			inside = not inside
		end
		j = i
	end
	return inside
end

function M.snap(v, step)
	return math.floor(v / step + 0.5) * step
end

-- The end point of a segment drawn from (ax, az) towards (px, pz), with its
-- angle snapped to multiples of step_deg (nil: free) and its length -- the
-- cursor's distance along that angle -- to multiples of len_step
function M.snap_direction(ax, az, px, pz, step_deg, len_step)
	local dx, dz = px - ax, pz - az
	if len(dx, dz) == 0 then
		return ax, az
	end
	local ang = math.atan2(dz, dx)
	if step_deg then
		local s = math.rad(step_deg)
		ang = math.floor(ang / s + 0.5) * s
	end
	local c, s = math.cos(ang), math.sin(ang)
	local l = math.max(len_step, M.snap(dx * c + dz * s, len_step))
	return ax + c * l, az + s * l
end

--
-- Self-checks
--
local function near(a, b, what)
	assert(math.abs(a - b) < 1e-6, what .. ": " .. a .. " is not " .. b)
end

do
	-- An L of two 100 mm centred walls: the corner is square outside and in
	local o = M.wall_outlines({
		[1] = {ax = 0, az = 0, bx = 1000, bz = 0, a_node = 1, b_node = 2,
				thickness = 100, justify = 0},
		[2] = {ax = 0, az = 0, bx = 0, bz = 1000, a_node = 1, b_node = 3,
				thickness = 100, justify = 0},
	})
	local p = o[1].pts
	-- right face at a (below the line) reaches the outer corner
	near(p[1][1], -50, "L outer x")
	near(p[1][2], -50, "L outer z")
	-- left face at a meets the other wall's face: the inner corner
	near(p[4][1], 50, "L inner x")
	near(p[4][2], 50, "L inner z")
	near(M.area(p), 1000 * 100 - 50 * 50 + 50 * 50 - 50 * 50 + 50 * 50, "L area")
	assert(#M.triangulate(p) == 2, "a wall's outline is two triangles")

	-- A T: the stem ends at the through walls' face, the node fills the rest
	local t = M.wall_outlines({
		[1] = {ax = 0, az = 0, bx = 1000, bz = 0, a_node = 1, b_node = 2,
				thickness = 100, justify = 0},
		[2] = {ax = 0, az = 0, bx = -1000, bz = 0, a_node = 1, b_node = 3,
				thickness = 100, justify = 0},
		[3] = {ax = 0, az = 0, bx = 0, bz = -1000, a_node = 1, b_node = 4,
				thickness = 100, justify = 0},
	})
	assert(#t[1].pts == 5, "a T's end carries the node")
	-- The through wall's top face runs straight over the node
	near(t[1].pts[4][2], 50, "T top face z")
	near(t[1].pts[4][1], 0, "T top face ends at the node")
	-- The stem's ends are the through walls' bottom corners
	local s = t[3].pts
	near(math.abs(s[4][1]), 50, "T stem corner x")
	near(s[4][2], -50, "T stem corner z")
	local total = M.area(t[1].pts) + M.area(t[2].pts) + M.area(t[3].pts)
	near(total, 2000 * 100 + 950 * 100, "T covers its footprint exactly once")

	-- A wall on its own is its rectangle, left-justified above the line
	local r = M.wall_outlines({[1] = {ax = 0, az = 0, bx = 2000, bz = 0,
			a_node = 1, b_node = 2, thickness = 120, justify = 1}})
	near(M.area(r[1].pts), 2000 * 120, "lone wall area")
	near(r[1].pts[1][2], 0, "left-justified: the right face is on the line")
	near(r[1].pts[3][2], 120, "left-justified: the left face is 120 up")

	-- A concave polygon triangulates to its own area
	local u = {{0, 0}, {3, 0}, {3, 3}, {2, 3}, {2, 1}, {1, 1}, {1, 3}, {0, 3}}
	local sum = 0
	for _, tri in ipairs(M.triangulate(u)) do
		sum = sum + M.area({u[tri[1]], u[tri[2]], u[tri[3]]})
	end
	near(sum, M.area(u), "U triangulated")
	near(M.area(u), 7, "U area")

	local x, z = M.snap_direction(0, 0, 1000, 800, 90, 10)
	near(x, 1000, "snap_direction projects onto the axis")
	near(z, 0, "snap_direction z")
end

return M
-- vim: set noet ts=4 sw=4:
