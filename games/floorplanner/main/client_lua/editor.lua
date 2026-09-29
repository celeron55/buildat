-- Buildat: games/floorplanner/main/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The editor: the scene built from the replica, the two cameras, the tools
-- and the panels. Walls and rooms on shared nodes ([FP_WALLS], [FP_ROOMS]),
-- boxes as definitions placed by instances ([FP_OBJECTS]).
--
-- Nothing here changes the document directly. A tool builds a batch and
-- sends it; what the server accepts comes back as fp:changes and the scene
-- is rebuilt from the replica. A drag shows its preview locally and is sent
-- when released.
local log = buildat.Logger("floorplanner")
local magic = require("buildat/extension/urho3d")
local function load(name)
	local ok, err, m = buildat.run_script_file("main/" .. name)
	if not ok or type(m) ~= "table" then
		error("floorplanner: could not load " .. name .. ": " .. tostring(err))
	end
	return m
end
local geom = load("geom.lua")
local panel = load("panel.lua")

local M = {}
local doc

local GRID_STEPS = {1, 10, 50, 100}
local ANGLE_STEPS = {false, 1, 5, 15, 45, 90}
-- How near, in pixels, the cursor snaps to a node or an edge
local SNAP_PX = 12
local DRAG_PX = 4
-- Where a copy lands from what it was copied from
local COPY_OFFSET = 500
local JUSTIFY_NAMES = {[0] = "centered", [1] = "left", [2] = "right"}
local TOOL_KEYS = {select = "V", node = "N", wall = "B", room = "R",
	box = "O", paint = "P"}

local S = {
	view = "2d",
	tool = "select",
	grid = 2,       -- index into GRID_STEPS
	angle = 4,      -- index into ANGLE_STEPS: the angle snap
	-- New walls
	thickness = 100,
	justify = 0,
	height = 0,
	hang = 0,
	room_walls = true, -- a room drawn gets walls on its edges
	-- New boxes
	box = {w = 600, h = 750, d = 600, align = 0, offset = 0},
	material = nil, -- the palette entry picked
	-- The cursor, in window pixels
	mx = 0, my = 0,
	shift = false,
	-- The 2D camera: centre in mm, and how many mm tall the view is
	cx = 0, cz = 0, span = 12000,
	-- The 3D camera, in metres and degrees
	pos = {x = -4, y = 6, z = -6},
	yaw = 35, pitch = 40,
	looking = false,
	-- Tool state
	draw = nil,     -- the wall tool's chain: {x, z, ref}
	corners = nil,  -- the room tool's corners so far: {{x, z, ref}, ...}
	typed = "",     -- a length being typed while drawing
	press = nil,    -- a mouse press that may become a drag
	drag = nil,     -- {kind = "node"|"move"|"box"|"footprint", ...}
	-- The select tool's selection: id -> kind ("instance", "wall", "room",
	-- "node"), and the one the panel shows
	sel = {},
	primary = nil,
	nodes = {},     -- the node tool's selection: id -> true
	dirty = true,
	-- Real ids of this session's placeholders, as batch results give them
	real = {},
}

--
-- The scene
--
local scene = magic.Scene()
-- Held by the module: a scene nothing refers to is collected, and the
-- viewport drawing it is left with a dangling pointer
M.scene = scene
scene:CreateComponent("Octree")
local debug = scene:CreateComponent("DebugRenderer")

local zone = scene:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(magic.Vector3(-1000, -1000, -1000),
		magic.Vector3(1000, 1000, 1000))
zone.ambientColor = magic.Color(0.55, 0.55, 0.58)
zone.fogColor = magic.Color(0.55, 0.62, 0.72)
zone.fogStart = 150
zone.fogEnd = 400

local sun_node = scene:CreateChild("Sun")
sun_node.direction = magic.Vector3(-0.45, -1.0, 0.3)
local sun = sun_node:CreateComponent("Light")
sun.lightType = magic.LIGHT_DIRECTIONAL
sun.brightness = 0.75
local fill_node = scene:CreateChild("Fill")
fill_node.direction = magic.Vector3(0.5, -0.6, -0.7)
local fill = fill_node:CreateComponent("Light")
fill.lightType = magic.LIGHT_DIRECTIONAL
fill.brightness = 0.3

-- From the resource cache, which holds them: a Material made in Lua is
-- freed under a geometry still using it
local lit_material = magic.cache:GetResource("Material", "main/lit_vcol.xml")
local flat_material = magic.cache:GetResource("Material", "main/flat_vcol.xml")

-- The world is in metres; the plan in millimetres
local function W(mm)
	return mm / 1000
end

local function rgb_color(rgb, f)
	f = f or 1
	return magic.Color(math.floor(rgb / 65536) % 256 / 255 * f,
			math.floor(rgb / 256) % 256 / 255 * f, rgb % 256 / 255 * f)
end

-- A triangle facing n: Urho3D's front faces are clockwise as seen, which in
-- its left-handed space is cross(b - a, c - a) pointing at the viewer
local function tri(g, a, b, c, n, col)
	local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
	local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
	local cx = uy * vz - uz * vy
	local cy = uz * vx - ux * vz
	local cz = ux * vy - uy * vx
	if cx * n.x + cy * n.y + cz * n.z < 0 then
		b, c = c, b
	end
	for _, v in ipairs({a, b, c}) do
		g:DefineVertex(v)
		g:DefineNormal(n)
		g:DefineColor(col)
	end
end

-- A flat polygon at height y (mm) facing n, as one geometry
local function flat_polygon(g, pts, y, n, col)
	for _, t in ipairs(geom.triangulate(pts)) do
		local a, b, c = pts[t[1]], pts[t[2]], pts[t[3]]
		tri(g, magic.Vector3(W(a[1]), W(y), W(a[2])),
				magic.Vector3(W(b[1]), W(y), W(b[2])),
				magic.Vector3(W(c[1]), W(y), W(c[2])), n, col)
	end
end

-- A box of half sizes hx, hy, hz (metres) about the origin
local function box_geometry(g, hx, hy, hz, col)
	local function V(x, y, z)
		return magic.Vector3(x * hx, y * hy, z * hz)
	end
	for _, f in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0},
			{0, 0, 1}, {0, 0, -1}}) do
		local n = magic.Vector3(f[1], f[2], f[3])
		-- Two axes across the face
		local u = f[1] ~= 0 and {0, 1, 0} or {1, 0, 0}
		local v = f[3] ~= 0 and {0, 1, 0} or {0, 0, 1}
		if f[2] ~= 0 then
			u, v = {1, 0, 0}, {0, 0, 1}
		end
		local function C(a, b)
			return V(f[1] + u[1] * a + v[1] * b, f[2] + u[2] * a + v[2] * b,
					f[3] + u[3] * a + v[3] * b)
		end
		tri(g, C(-1, -1), C(1, -1), C(1, 1), n, col)
		tri(g, C(-1, -1), C(1, 1), C(-1, 1), n, col)
	end
end

local UP, DOWN = magic.Vector3(0, 1, 0), magic.Vector3(0, -1, 0)

local ground_node = scene:CreateChild("Ground")
do
	local g = ground_node:CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	local r = 200000
	flat_polygon(g, {{-r, -r}, {r, -r}, {r, r}, {-r, r}}, 0, UP,
			magic.Color(0.6, 0.6, 0.58))
	g:Commit()
	g:SetMaterial(0, lit_material)
end

local walls_node = scene:CreateChild("Walls")
local caps_node = scene:CreateChild("Caps")
-- The ceilings and what is aligned to them, hidden from above
local overhead_node = scene:CreateChild("Overhead")

-- The cameras
local cam2d_node = scene:CreateChild("Camera2D")
local cam2d = cam2d_node:CreateComponent("Camera")
cam2d.orthographic = true
cam2d.nearClip = 0.001
cam2d.farClip = 100
cam2d_node.rotation = magic.Quaternion(90, 0, 0)

local cam3d_node = scene:CreateChild("Camera3D")
local cam3d = cam3d_node:CreateComponent("Camera")
cam3d.nearClip = 0.05
cam3d.farClip = 500
cam3d.fov = 60

local vp2d = magic.Viewport:new(scene, cam2d)
local vp3d = magic.Viewport:new(scene, cam3d)

--
-- The document, as the editor reads it
--
local function settings()
	return doc.settings().ints
end

local function node_pos(id)
	local d = S.drag
	if d and d.moved then
		if d.kind == "node" and d.id == id then
			return d.x, d.z
		elseif d.kind == "move" and d.nodes[id] then
			local n = doc.ents[id].ints
			return n.x + d.dx, n.z + d.dz
		end
	end
	local n = doc.ents[id]
	if not n then
		return 0, 0
	end
	return n.ints.x, n.ints.z
end

local function palette_rgb(id)
	local e = id and id ~= 0 and doc.ents[id]
	if e and e.type == "palette" then
		return e.ints.color
	end
	return 0xb0b0b0
end

-- The walls with their ends looked up, their outlines, the rooms with
-- their corners counter-clockwise, and the instances placed; rebuild()
-- fills them
local outlines = {}
local wall_data = {}
local room_data = {}
local inst_data = {}
-- The scene nodes rebuild() made, for the next one to remove
local built = {}

local function wall_span(w)
	local ceiling = settings().ceiling
	local h = w.height > 0 and math.min(w.height, ceiling) or ceiling
	if w.hang == 1 then
		return ceiling - h, ceiling
	end
	return 0, h
end

-- The wall between two nodes, and whether it runs u -> v
local function wall_between(u, v)
	for id, w in pairs(wall_data) do
		if w.a_node == u and w.b_node == v then
			return id, true
		elseif w.a_node == v and w.b_node == u then
			return id, false
		end
	end
	return nil
end

local function room_ceiling(e)
	return e.ints.ceiling > 0 and e.ints.ceiling or settings().ceiling
end

local function build_room_data()
	room_data = {}
	for _, e in ipairs(doc.of_type("room")) do
		local pts, ids = {}, {}
		for _, n in ipairs(e.lists.nodes) do
			local x, z = node_pos(n)
			pts[#pts + 1] = {x, z}
			ids[#ids + 1] = n
		end
		if not geom.is_ccw(pts) then
			local rp, ri = {}, {}
			for i = #pts, 1, -1 do
				rp[#rp + 1] = pts[i]
				ri[#ri + 1] = ids[i]
			end
			pts, ids = rp, ri
		end
		-- The net floor: each edge moved in to the face of the wall on it
		local offsets = {}
		for i = 1, #ids do
			local wid, forward = wall_between(ids[i], ids[i % #ids + 1])
			offsets[i] = 0
			if wid then
				local w = wall_data[wid]
				local lo, ro = geom.offsets(w.thickness, w.justify)
				-- The room is left of its counter-clockwise edges
				offsets[i] = forward and lo or ro
			end
		end
		local inner = geom.inset(pts, offsets)
		room_data[e.id] = {pts = pts, ids = ids, inner = inner,
				gross = geom.area(pts), net = geom.area(inner)}
	end
end

-- The smallest room the point is in
local function room_at(x, z)
	local best, ba = nil, math.huge
	for id, r in pairs(room_data) do
		if r.gross < ba and geom.point_in_polygon(x, z, r.pts) then
			best, ba = id, r.gross
		end
	end
	return best
end

-- An instance placed: its centre, rotation and extents in mm. The 90
-- degree pitch and roll swap the definition's axes; the yaw turns the
-- footprint, which is ex by ez in the yawed frame.
local function build_inst_data()
	inst_data = {}
	local d = S.drag
	for _, e in ipairs(doc.of_type("instance")) do
		local i = e.ints
		local def = doc.ents[i.def]
		if def then
			local p = def.ints
			local pitch, roll = i.pitch * 90, i.roll * 90
			local ex, ey, ez = geom.rot(p.w, p.h, p.d, pitch, 0, roll)
			ex, ey, ez = math.abs(ex), math.abs(ey), math.abs(ez)
			local x, z = i.x, i.z
			if d and d.moved and d.kind == "move" and d.inst[e.id] then
				x, z = x + d.dx, z + d.dz
			end
			local y
			if i.align == 1 then
				y = settings().ceiling - i.offset - ey / 2
			else
				y = i.offset + ey / 2
			end
			local yaw = i.yaw / 1000
			local foot = {}
			for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
				local fx, _, fz = geom.rot(c[1] * ex / 2, 0, c[2] * ez / 2, 0,
						yaw, 0)
				foot[k] = {x + fx, z + fz}
			end
			if not geom.is_ccw(foot) then
				foot = {foot[4], foot[3], foot[2], foot[1]}
			end
			inst_data[e.id] = {x = x, y = y, z = z, yaw = yaw, pitch = pitch,
					roll = roll, ex = ex, ey = ey, ez = ez, y0 = y - ey / 2,
					y1 = y + ey / 2, def = i.def, foot = foot}
		end
	end
end

local function instances_of(def)
	local n = 0
	for _, e in ipairs(doc.of_type("instance")) do
		if e.ints.def == def then
			n = n + 1
		end
	end
	return n
end

-- simplified: everything is rebuilt on any change, which at a few hundred
-- walls is milliseconds; the upgrade is rebuilding only what is at the
-- nodes that moved
local function rebuild()
	wall_data = {}
	for _, e in ipairs(doc.of_type("wall")) do
		local w = e.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		wall_data[e.id] = {ax = ax, az = az, bx = bx, bz = bz,
				a_node = w.a, b_node = w.b, thickness = w.thickness,
				justify = w.justify, group = w.hang}
	end
	outlines = geom.wall_outlines(wall_data)
	build_room_data()
	build_inst_data()
	for _, n in ipairs(built) do
		n:Remove()
	end
	built = {}
	local cut = settings().cut
	local function geometry(parent)
		local node = parent:CreateChild("")
		built[#built + 1] = node
		local g = node:CreateComponent("CustomGeometry")
		g:SetNumGeometries(1)
		g:BeginGeometry(0, magic.TRIANGLE_LIST)
		return g, node
	end
	local function commit(g, material)
		g:Commit()
		g:SetMaterial(0, material)
	end
	-- What the plan view shows where the cut goes through something: dark
	-- where it is cut, lighter for what is below the cut
	local function cap(pts, y0, y1, cut_col, low_col)
		if y0 < cut then
			local cg = geometry(caps_node)
			flat_polygon(cg, pts, math.min(y1, cut) - 3, UP, y1 >= cut and
					cut_col or low_col)
			commit(cg, flat_material)
		end
	end

	for id, o in pairs(outlines) do
		local w = doc.ents[id].ints
		local y0, y1 = wall_span(w)
		local cols = {
			left = rgb_color(palette_rgb(w.mat_left)),
			right = rgb_color(palette_rgb(w.mat_right)),
			core = rgb_color(palette_rgb(w.mat_core ~= 0 and w.mat_core or
					w.mat_left)),
		}
		local g = geometry(walls_node)
		local pts = o.pts
		flat_polygon(g, pts, y1, UP, cols.core)
		if y0 > 0 then
			flat_polygon(g, pts, y0, DOWN, cols.core)
		end
		local function v(p, y)
			return magic.Vector3(W(p[1]), W(y), W(p[2]))
		end
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local dx, dz = q[1] - p[1], q[2] - p[2]
			local l = geom.len(dx, dz)
			if l > 0.01 then
				-- Outward of a counter-clockwise outline is to the right
				local n = magic.Vector3(dz / l, 0, -dx / l)
				local col = cols[o.sides[i]]
				tri(g, v(p, y0), v(q, y0), v(q, y1), n, col)
				tri(g, v(p, y0), v(q, y1), v(p, y1), n, col)
			end
		end
		commit(g, lit_material)
		cap(pts, y0, y1, magic.Color(0.16, 0.16, 0.18),
				magic.Color(0.55, 0.55, 0.58))
	end

	for id, r in pairs(room_data) do
		local e = doc.ents[id]
		if #r.pts >= 3 then
			local g = geometry(walls_node)
			flat_polygon(g, r.pts, 2, UP, rgb_color(palette_rgb(e.ints.mat_floor)))
			commit(g, lit_material)
			local cg = geometry(overhead_node)
			flat_polygon(cg, r.pts, room_ceiling(e), DOWN,
					rgb_color(palette_rgb(e.ints.mat_ceiling)))
			commit(cg, lit_material)
		end
	end

	for id, it in pairs(inst_data) do
		local def = doc.ents[it.def].ints
		local e = doc.ents[id].ints
		local g, node = geometry(e.align == 1 and overhead_node or walls_node)
		node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
		node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
		local rgb = palette_rgb(def.mat)
		box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(def.d) / 2,
				rgb_color(rgb))
		commit(g, lit_material)
		cap(it.foot, it.y0, it.y1, rgb_color(rgb, 0.7), rgb_color(rgb, 0.9))
	end
	caps_node.enabled = S.view == "2d"
	S.dirty = false
end

--
-- Screen and plan
--
local function screen_size()
	return magic.graphics.width, magic.graphics.height
end

-- Millimetres per pixel in the plan view
local function mm_per_px()
	local _, h = screen_size()
	return S.span / h
end

-- The ray under the cursor: origin and direction in world metres
local function cursor_ray()
	local w, h = screen_size()
	if S.view == "2d" then
		local x = S.cx + (S.mx / w - 0.5) * S.span * w / h
		local z = S.cz - (S.my / h - 0.5) * S.span
		return {x = W(x), y = 100, z = W(z)}, {x = 0, y = -1, z = 0}
	end
	local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
	local f = {x = math.sin(yaw) * math.cos(pitch), y = -math.sin(pitch),
			z = math.cos(yaw) * math.cos(pitch)}
	local r = {x = math.cos(yaw), y = 0, z = -math.sin(yaw)}
	local u = {x = math.sin(yaw) * math.sin(pitch), y = math.cos(pitch),
			z = math.cos(yaw) * math.sin(pitch)}
	local tan = math.tan(math.rad(cam3d.fov) / 2)
	local nx = (2 * S.mx / w - 1) * tan * w / h
	local ny = (1 - 2 * S.my / h) * tan
	if S.looking then
		nx, ny = 0, 0
	end
	local d = {x = f.x + r.x * nx + u.x * ny, y = f.y + r.y * nx + u.y * ny,
			z = f.z + r.z * nx + u.z * ny}
	return S.pos, d
end

-- Where the ray meets the horizontal plane at y mm: x, z in mm and the
-- ray's parameter; nil when it does not
local function ray_at_height(y)
	local o, d = cursor_ray()
	if math.abs(d.y) < 1e-9 then
		return nil
	end
	local t = (W(y) - o.y) / d.y
	if t <= 0 then
		return nil
	end
	return (o.x + d.x * t) * 1000, (o.z + d.z * t) * 1000, t
end

-- Where the cursor is on the floor, in mm; nil when looking above it
local function cursor_floor()
	local x, z = ray_at_height(0)
	return x, z
end

-- How far a pixel is on the floor where the cursor is, for snap radii
local function snap_radius()
	if S.view == "2d" then
		return SNAP_PX * mm_per_px()
	end
	local x, z = cursor_floor()
	if not x then
		return 100
	end
	local dist = geom.len(x / 1000 - S.pos.x, z / 1000 - S.pos.z)
	dist = math.sqrt(dist * dist + S.pos.y * S.pos.y)
	local _, h = screen_size()
	return SNAP_PX * dist * 1000 * 2 * math.tan(math.rad(cam3d.fov) / 2) / h
end

local function grid_step()
	return GRID_STEPS[S.grid]
end

local function angle_step()
	return ANGLE_STEPS[S.angle] or 1
end

-- The node nearest to (x, z) within r, skipping those in `except`
local function nearest_node(x, z, r, except)
	local best, bd = nil, r
	for _, n in ipairs(doc.of_type("node")) do
		if not (except and except[n.id]) then
			local nx, nz = node_pos(n.id)
			local d = geom.len(nx - x, nz - z)
			if d <= bd then
				best, bd = n.id, d
			end
		end
	end
	return best
end

-- Every edge a point can land on: the walls, and the rooms' edges that have
-- no wall. {u, v, wall = id or nil}
local function edges()
	local out = {}
	for id, w in pairs(wall_data) do
		out[#out + 1] = {u = w.a_node, v = w.b_node, wall = id}
	end
	for _, r in pairs(room_data) do
		for i = 1, #r.ids do
			local u, v = r.ids[i], r.ids[i % #r.ids + 1]
			if not wall_between(u, v) then
				out[#out + 1] = {u = u, v = v}
			end
		end
	end
	return out
end

-- The edge nearest to (x, z) within r: the edge, the point on it and its
-- distance along it from u
local function nearest_edge(x, z, r, except)
	local best, bx, bz, bt = nil, 0, 0, 0
	local bd = r
	for _, e in ipairs(edges()) do
		if not (except and (except[e.u] or except[e.v])) then
			local ux, uz = node_pos(e.u)
			local vx, vz = node_pos(e.v)
			local px, pz, t, d = geom.nearest_on_segment(x, z, ux, uz, vx, vz)
			if d <= bd and t > 0 and t < 1 then
				best, bx, bz, bd = e, px, pz, d
				bt = t * geom.len(vx - ux, vz - uz)
			end
		end
	end
	return best, bx, bz, bt
end

-- Where the cursor's ray enters an instance's box, or nil
local function ray_instance(it, o, d)
	local ox, oy, oz = geom.unrot(o.x - W(it.x), o.y - W(it.y), o.z - W(it.z),
			it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	local def = doc.ents[it.def].ints
	local tmin, tmax = 0, math.huge
	for _, a in ipairs({{ox, dx, W(def.w) / 2}, {oy, dy, W(def.h) / 2},
			{oz, dz, W(def.d) / 2}}) do
		if math.abs(a[2]) < 1e-12 then
			if math.abs(a[1]) > a[3] then
				return nil
			end
		else
			local t1, t2 = (-a[3] - a[1]) / a[2], (a[3] - a[1]) / a[2]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin
end

-- What is under the cursor for painting and selecting: an instance, a
-- wall and which of its faces, or a room's floor or ceiling.
-- {kind = "instance"|"wall"|"floor"|"ceiling", id, side}
local function pick_surface()
	if S.view == "2d" then
		local x, z = cursor_floor()
		-- The topmost instance under the cursor, as seen from above
		local best, top = nil, -math.huge
		for id, it in pairs(inst_data) do
			if it.y1 > top and geom.point_in_polygon(x, z, it.foot) then
				best, top = id, it.y1
			end
		end
		if best then
			return {kind = "instance", id = best}
		end
		for id, o in pairs(outlines) do
			if geom.point_in_polygon(x, z, o.pts) then
				local w = wall_data[id]
				local side = (w.bx - w.ax) * (z - w.az) -
						(w.bz - w.az) * (x - w.ax) > 0 and "left" or "right"
				return {kind = "wall", id = id, side = side}
			end
		end
		local r = room_at(x, z)
		return r and {kind = "floor", id = r} or nil
	end
	local o, d = cursor_ray()
	local best, best_t = nil, math.huge
	for id, it in pairs(inst_data) do
		local overhead = doc.ents[id].ints.align == 1
		if not overhead or overhead_node.enabled then
			local t = ray_instance(it, o, d)
			if t and t < best_t then
				best, best_t = {kind = "instance", id = id}, t
			end
		end
	end
	for id, ol in pairs(outlines) do
		local y0, y1 = wall_span(doc.ents[id].ints)
		y0, y1 = W(y0), W(y1)
		local pts = ol.pts
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local px, pz, qx, qz = W(p[1]), W(p[2]), W(q[1]), W(q[2])
			-- The face's plane is vertical through p-q
			local nx, nz = qz - pz, -(qx - px)
			local denom = d.x * nx + d.z * nz
			if math.abs(denom) > 1e-9 then
				local t = ((px - o.x) * nx + (pz - o.z) * nz) / denom
				if t > 0 and t < best_t then
					local hx, hy, hz = o.x + d.x * t, o.y + d.y * t, o.z + d.z * t
					local _, _, _, dist = geom.nearest_on_segment(hx, hz,
							px, pz, qx, qz)
					if dist < 1e-4 and hy >= y0 and hy <= y1 then
						best, best_t = {kind = "wall", id = id,
								side = ol.sides[i]}, t
					end
				end
			end
		end
		local hx, hz, t = ray_at_height(y1 * 1000)
		if hx and t < best_t and geom.point_in_polygon(hx, hz, pts) then
			best, best_t = {kind = "wall", id = id, side = "core"}, t
		end
	end
	for id, r in pairs(room_data) do
		local surfaces = {{"floor", 2}}
		if overhead_node.enabled then
			surfaces[2] = {"ceiling", room_ceiling(doc.ents[id])}
		end
		for _, s in ipairs(surfaces) do
			local hx, hz, t = ray_at_height(s[2])
			if hx and t < best_t and geom.point_in_polygon(hx, hz, r.pts) then
				best, best_t = {kind = s[1], id = id}, t
			end
		end
	end
	return best
end

-- Where a point the cursor gives lands: on a node, on an edge, or on the
-- grid. from: the point a segment is drawn from, for the angle snap.
-- Returns x, z and what it landed on: {node = id} or {edge = e, t = mm}.
local function snapped_point(from, except)
	local x, z = cursor_floor()
	if not x then
		return nil
	end
	local r = snap_radius()
	local n = nearest_node(x, z, r, except)
	if n then
		local nx, nz = node_pos(n)
		return nx, nz, {node = n}
	end
	local e, _, _, et = nearest_edge(x, z, r, except)
	if e then
		-- Along the edge, the distance from its u end is what snaps
		local ux, uz = node_pos(e.u)
		local vx, vz = node_pos(e.v)
		local l = geom.len(vx - ux, vz - uz)
		local t = math.max(1, math.min(l - 1, geom.snap(et, grid_step())))
		return math.floor(ux + (vx - ux) * t / l + 0.5),
				math.floor(uz + (vz - uz) * t / l + 0.5), {edge = e, t = t}
	end
	if from then
		local step = S.shift and ANGLE_STEPS[S.angle] or 90
		local ex, ez = geom.snap_direction(from.x, from.z, x, z,
				step or nil, grid_step())
		return math.floor(ex + 0.5), math.floor(ez + 0.5), {}
	end
	return geom.snap(x, grid_step()), geom.snap(z, grid_step()), {}
end

-- The gaps from an instance's footprint to the nearest wall face along its
-- own four axes: {{dir = {ux, uz}, half = mm, gap = mm}, ...}; gap is nil
-- where no wall is that way
local function wall_gaps(id)
	local it = inst_data[id]
	local out = {}
	for k, a in ipairs({{1, 0, it.ex}, {-1, 0, it.ex}, {0, 1, it.ez},
			{0, -1, it.ez}}) do
		local ux, _, uz = geom.rot(a[1], 0, a[2], 0, it.yaw, 0)
		local best = nil
		for _, o in pairs(outlines) do
			local pts = o.pts
			for i = 1, #pts do
				local p, q = pts[i], pts[i % #pts + 1]
				local t = geom.ray_segment(it.x, it.z, ux, uz, p[1], p[2],
						q[1], q[2])
				if t and t > a[3] / 2 and (not best or t < best) then
					best = t
				end
			end
		end
		out[k] = {dir = {ux, uz}, half = a[3] / 2,
				gap = best and best - a[3] / 2}
	end
	return out
end

--
-- Batches
--
-- A batch being built: its ops, and the room corner lists it has changed so
-- far, which go out as one set per room at the end
local function new_batch()
	return {ops = {}, lists = {}, split = {}, pairs = {}}
end

-- The two node ids of an edge, in either order, as one key
local function pair_key(u, v)
	return math.min(u, v) .. ":" .. math.max(u, v)
end

local function add_op(b, op, ent)
	b.ops[#b.ops + 1] = {op = op, ent = ent}
end

local function room_list(b, id)
	if not b.lists[id] then
		local l = {}
		for i, n in ipairs(doc.ents[id].lists.nodes) do
			l[i] = n
		end
		b.lists[id] = l
	end
	return b.lists[id]
end

local function finish_batch(b)
	for id, l in pairs(b.lists) do
		if doc.ents[id] then
			add_op(b, "set", {id = id, lists = {nodes = l}})
		end
	end
	return b.ops
end

local function real_id(id)
	if id and id < 0 then
		return S.real[id]
	end
	return id
end

local function send(ops, done)
	doc.send(ops, function(err, placeholders)
		for ph, id in pairs(placeholders) do
			S.real[ph] = id
		end
		if err ~= "" then
			doc.notice("Refused: " .. err)
		end
		if done then
			done(err)
		end
	end)
end

local function wall_fields(w)
	return {thickness = w.thickness, justify = w.justify, height = w.height,
			hang = w.hang, mat_left = w.mat_left, mat_right = w.mat_right,
			mat_core = w.mat_core}
end

-- The ops that give a point a node: an existing one, a new one on an edge,
-- or a new one. A new node on an edge splits the wall on it and joins
-- every room with that edge, so neighbours keep sharing their corners.
-- Returns the node's id (maybe a placeholder), or nil when it cannot.
local function node_for(b, x, z, ref)
	if ref and ref.node then
		return real_id(ref.node)
	end
	local ph = doc.placeholder()
	add_op(b, "create", {id = ph, type = "node",
			ints = {x = math.floor(x + 0.5), z = math.floor(z + 0.5)}})
	local e = ref and ref.edge
	if not e then
		return ph
	end
	if e.wall and doc.ents[e.wall] then
		if b.split[e.wall] then
			-- The second split of one wall in a batch would work from the
			-- first's stale end
			return nil
		end
		b.split[e.wall] = true
		-- The wall keeps a->node and a copy of it takes node->b
		local w = doc.ents[e.wall].ints
		add_op(b, "set", {id = e.wall, ints = {b = ph}})
		local f = wall_fields(w)
		f.a, f.b = ph, w.b
		add_op(b, "create", {id = doc.placeholder(), type = "wall", ints = f})
		b.pairs[pair_key(w.a, ph)] = true
		b.pairs[pair_key(ph, w.b)] = true
	end
	for _, room in ipairs(doc.of_type("room")) do
		local l = room_list(b, room.id)
		for i = 1, #l do
			local j = i % #l + 1
			if (l[i] == e.u and l[j] == e.v) or (l[i] == e.v and l[j] == e.u) then
				table.insert(l, i + 1, ph)
				break
			end
		end
	end
	return ph
end

local function default_material()
	if S.material and doc.ents[S.material] then
		return S.material
	end
	local p = doc.of_type("palette")[1]
	return p and p.id or 0
end

-- The material a new wall face gets: the most common among the faces
-- already facing the room it faces, else the one picked
local function face_material(x, z)
	local room = room_at(x, z)
	if not room then
		return default_material()
	end
	local count, best, bn = {}, nil, 0
	for id, w in pairs(wall_data) do
		local l = geom.len(w.bx - w.ax, w.bz - w.az)
		if l > 0 then
			local mx, mz = (w.ax + w.bx) / 2, (w.az + w.bz) / 2
			local nx, nz = -(w.bz - w.az) / l, (w.bx - w.ax) / l
			local e = doc.ents[id].ints
			local d = w.thickness + 20
			for _, side in ipairs({{1, e.mat_left}, {-1, e.mat_right}}) do
				if side[2] ~= 0 and room_at(mx + nx * d * side[1],
						mz + nz * d * side[1]) == room then
					count[side[2]] = (count[side[2]] or 0) + 1
					if count[side[2]] > bn then
						best, bn = side[2], count[side[2]]
					end
				end
			end
		end
	end
	return best or default_material()
end

-- A new wall's ops between two node ids at the given points
local function wall_op(b, a, ax, az, bnode, bx, bz)
	local l = geom.len(bx - ax, bz - az)
	local nx, nz = -(bz - az) / l, (bx - ax) / l
	local mx, mz = (ax + bx) / 2, (az + bz) / 2
	local d = S.thickness + 20
	add_op(b, "create", {id = doc.placeholder(), type = "wall", ints = {
			a = a, b = bnode, thickness = S.thickness, justify = S.justify,
			height = S.height, hang = S.hang,
			mat_left = face_material(mx + nx * d, mz + nz * d),
			mat_right = face_material(mx - nx * d, mz - nz * d)}})
end

local function add_wall(from, x, z, ref)
	local fe, te = from.ref and from.ref.edge, ref and ref.edge
	if fe and te and fe.u == te.u and fe.v == te.v then
		doc.notice("Both ends on one edge: nothing to draw")
		return false
	end
	if from.ref and ref and from.ref.node and from.ref.node == ref.node then
		return false
	end
	if geom.len(x - from.x, z - from.z) < 1 then
		return false
	end
	local b = new_batch()
	local a = node_for(b, from.x, from.z, from.ref)
	local bn = node_for(b, x, z, ref)
	if not a or not bn then
		return false
	end
	wall_op(b, a, from.x, from.z, bn, x, z)
	send(finish_batch(b))
	-- The chain goes on from the end, which is now a node
	S.draw = {x = x, z = z, ref = {node = bn}}
	return true
end

-- The room tool's corners, as a room and (if asked) walls on its edges
local function add_room(corners)
	if #corners < 3 then
		return
	end
	local b = new_batch()
	local ids = {}
	for i, c in ipairs(corners) do
		ids[i] = node_for(b, c.x, c.z, c.ref)
		if not ids[i] then
			doc.notice("Two corners on one wall: split it first")
			return
		end
	end
	local ph = doc.placeholder()
	local mat = default_material()
	add_op(b, "create", {id = ph, type = "room", ints = {mat_floor = mat,
			mat_ceiling = mat}, strs = {name = "room " ..
			(#doc.of_type("room") + 1)}, lists = {nodes = ids}})
	if S.room_walls then
		for i = 1, #ids do
			local j = i % #ids + 1
			local exists = b.pairs[pair_key(ids[i], ids[j])] or
					(ids[i] > 0 and ids[j] > 0 and wall_between(ids[i], ids[j]))
			if not exists then
				wall_op(b, ids[i], corners[i].x, corners[i].z, ids[j],
						corners[j].x, corners[j].z)
			end
		end
	end
	send(finish_batch(b))
end

-- A box drawn: a definition of that size and an instance of it
local function add_box(x, z, w, d)
	local def = doc.placeholder()
	send({
		{op = "create", ent = {id = def, type = "definition", ints = {kind = 0,
				w = w, h = S.box.h, d = d, mat = default_material()}}},
		{op = "create", ent = {id = doc.placeholder(), type = "instance",
				ints = {def = def, x = math.floor(x + 0.5),
				z = math.floor(z + 0.5), align = S.box.align,
				offset = S.box.offset}}},
	})
end

local function copy_fields(p)
	local f = {}
	for k, v in pairs(p) do
		f[k] = v
	end
	return f
end

-- Copies of the selected instances next to them: linked ones share the
-- definition, the others get a copy of it
local function copy_selected(linked)
	local ops, new = {}, {}
	for id, kind in pairs(S.sel) do
		if kind == "instance" then
			local i = copy_fields(doc.ents[id].ints)
			if not linked then
				local def = doc.placeholder()
				ops[#ops + 1] = {op = "create", ent = {id = def,
						type = "definition", ints = copy_fields(
						doc.ents[i.def].ints)}}
				i.def = def
			end
			i.x = i.x + COPY_OFFSET
			i.z = i.z - COPY_OFFSET
			local ph = doc.placeholder()
			new[#new + 1] = ph
			ops[#ops + 1] = {op = "create", ent = {id = ph, type = "instance",
					ints = i}}
		end
	end
	if #ops == 0 then
		doc.notice("Copies are of objects; select one")
		return
	end
	send(ops, function(err)
		if err == "" then
			-- The copies are what is selected now
			S.sel = {}
			for _, ph in ipairs(new) do
				S.sel[S.real[ph]] = "instance"
				S.primary = S.real[ph]
			end
			M.refresh_panels()
		end
	end)
end

local function unlink(id)
	local i = doc.ents[id].ints
	local def = doc.placeholder()
	send({
		{op = "create", ent = {id = def, type = "definition",
				ints = copy_fields(doc.ents[i.def].ints)}},
		{op = "set", ent = {id = id, ints = {def = def}}},
	})
end

-- Node `from` merged into node `into`: what referred to one refers to the
-- other, and what that makes degenerate goes
local function merge_ops(from, into)
	local b = new_batch()
	local ends = {}
	for id, w in pairs(wall_data) do
		local a, bb = w.a_node, w.b_node
		if a == from then a = into end
		if bb == from then bb = into end
		local key = pair_key(a, bb)
		if a == bb or ends[key] then
			add_op(b, "delete", {id = id})
		elseif a ~= w.a_node or bb ~= w.b_node then
			add_op(b, "set", {id = id, ints = {a = a, b = bb}})
		end
		if a ~= bb then
			ends[key] = true
		end
	end
	for _, room in ipairs(doc.of_type("room")) do
		local l = room.lists.nodes
		local has_from, has_into = false, false
		for _, n in ipairs(l) do
			has_from = has_from or n == from
			has_into = has_into or n == into
		end
		if has_from then
			local nl = {}
			for _, n in ipairs(l) do
				if n ~= from then
					nl[#nl + 1] = n
				elseif not has_into then
					nl[#nl + 1] = into
				end
			end
			if #nl < 3 then
				add_op(b, "delete", {id = room.id})
			else
				add_op(b, "set", {id = room.id, lists = {nodes = nl}})
			end
		end
	end
	add_op(b, "delete", {id = from})
	return b.ops
end

local function unused_nodes(ops, gone_walls)
	local candidates = {}
	for id in pairs(gone_walls) do
		local w = doc.ents[id].ints
		candidates[w.a] = true
		candidates[w.b] = true
	end
	for n in pairs(candidates) do
		local used = false
		for id, w in pairs(wall_data) do
			if not gone_walls[id] and (w.a_node == n or w.b_node == n) then
				used = true
			end
		end
		for _, room in ipairs(doc.of_type("room")) do
			for _, rn in ipairs(room.lists.nodes) do
				used = used or rn == n
			end
		end
		if not used then
			ops[#ops + 1] = {op = "delete", ent = {id = n}}
		end
	end
end

local function delete_nodes(ops, ids)
	for id in pairs(ids) do
		if doc.ents[id] then
			ops[#ops + 1] = {op = "delete", ent = {id = id}}
		end
	end
	-- A room left with corners but no floor goes too; the server only
	-- knows to remove one left with fewer than three
	for _, room in ipairs(doc.of_type("room")) do
		local pts = {}
		for _, n in ipairs(room.lists.nodes) do
			if not ids[n] then
				pts[#pts + 1] = {node_pos(n)}
			end
		end
		if #pts >= 3 and #pts < #room.lists.nodes and
				geom.area(pts) < 10000 then
			ops[#ops + 1] = {op = "delete", ent = {id = room.id}}
		end
	end
end

local function delete_selected()
	local ops = {}
	if S.tool == "node" then
		delete_nodes(ops, S.nodes)
		S.nodes = {}
	else
		local walls, nodes, defs = {}, {}, {}
		for id, kind in pairs(S.sel) do
			if doc.ents[id] then
				if kind == "node" then
					nodes[id] = true
				else
					ops[#ops + 1] = {op = "delete", ent = {id = id}}
				end
				if kind == "wall" then
					walls[id] = true
				elseif kind == "instance" then
					local def = doc.ents[id].ints.def
					defs[def] = (defs[def] or 0) + 1
				end
			end
		end
		delete_nodes(ops, nodes)
		-- Their nodes go with the walls where nothing else holds them, and
		-- a definition with its last instance
		unused_nodes(ops, walls)
		for def, n in pairs(defs) do
			if instances_of(def) == n then
				ops[#ops + 1] = {op = "delete", ent = {id = def}}
			end
		end
		S.sel = {}
		S.primary = nil
	end
	if #ops > 0 then
		send(ops)
	end
end

-- What a selection moves: instances by their position, walls and rooms by
-- their nodes
local function moved_by(sel)
	local inst, nodes = {}, {}
	for id, kind in pairs(sel) do
		local e = doc.ents[id]
		if e then
			if kind == "instance" then
				inst[id] = true
			elseif kind == "node" then
				nodes[id] = true
			elseif kind == "wall" then
				nodes[e.ints.a] = true
				nodes[e.ints.b] = true
			elseif kind == "room" then
				for _, n in ipairs(e.lists.nodes) do
					nodes[n] = true
				end
			end
		end
	end
	return inst, nodes
end

-- The selection turned by deg about its centre, counter-clockwise as seen
-- from above: positions about the centre, and each instance's own yaw.
-- A turn asked for while one is on its way waits for it, since it is
-- computed from where the first leaves things.
local rotate_selection
local turning, turn_queued = false, 0
local function send_turn(deg)
	local inst, nodes = moved_by(S.sel)
	local sx, sz, n = 0, 0, 0
	for id in pairs(inst) do
		sx, sz, n = sx + inst_data[id].x, sz + inst_data[id].z, n + 1
	end
	for id in pairs(nodes) do
		local x, z = node_pos(id)
		sx, sz, n = sx + x, sz + z, n + 1
	end
	if n == 0 then
		return
	end
	sx, sz = sx / n, sz / n
	local c, s = math.cos(math.rad(deg)), math.sin(math.rad(deg))
	local function turn(x, z)
		local dx, dz = x - sx, z - sz
		return math.floor(sx + dx * c - dz * s + 0.5),
				math.floor(sz + dx * s + dz * c + 0.5)
	end
	local ops = {}
	for id in pairs(inst) do
		local i = doc.ents[id].ints
		local x, z = turn(i.x, i.z)
		-- Yaw grows turning right, which from above is clockwise
		local yaw = (i.yaw - math.floor(deg * 1000 + 0.5)) % 360000
		ops[#ops + 1] = {op = "set", ent = {id = id, ints = {x = x, z = z,
				yaw = yaw}}}
	end
	for id in pairs(nodes) do
		local p = doc.ents[id].ints
		local x, z = turn(p.x, p.z)
		ops[#ops + 1] = {op = "set", ent = {id = id, ints = {x = x, z = z}}}
	end
	turning = true
	send(ops, function()
		turning = false
		if turn_queued ~= 0 then
			local q = turn_queued
			turn_queued = 0
			rotate_selection(q)
		end
	end)
end

rotate_selection = function(deg)
	if turning then
		turn_queued = turn_queued + deg
	else
		send_turn(deg)
	end
end

-- The palette entry picked, on everything selected
local function apply_material()
	local mat = default_material()
	local ops = {}
	for id, kind in pairs(S.sel) do
		local e = doc.ents[id]
		if e and kind == "instance" then
			ops[#ops + 1] = {op = "set", ent = {id = e.ints.def,
					ints = {mat = mat}}}
		elseif e and kind == "wall" then
			ops[#ops + 1] = {op = "set", ent = {id = id,
					ints = {mat_left = mat, mat_right = mat}}}
		elseif e and kind == "room" then
			ops[#ops + 1] = {op = "set", ent = {id = id,
					ints = {mat_floor = mat}}}
		end
	end
	send(ops)
end

--
-- The panels
--
local toolbar, props, palette_win
local label_nodes = {}

local refresh_panels

local function set_view(v)
	S.view = v
	magic.set_preferred_viewports({v == "2d" and vp2d or vp3d})
	caps_node.enabled = v == "2d"
	refresh_panels()
end

local function set_tool(t)
	S.tool = t
	S.draw = nil
	S.corners = nil
	S.typed = ""
	refresh_panels()
end

local function build_toolbar()
	if toolbar then
		toolbar:Remove()
	end
	toolbar = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 8, true)
	panel.button(toolbar, S.view == "2d" and "2D" or "3D",
			function() set_view(S.view == "2d" and "3d" or "2d") end, false, 40)
	for _, t in ipairs({{"select", "Select"}, {"node", "Nodes"},
			{"wall", "Wall"}, {"room", "Room"}, {"box", "Box"},
			{"paint", "Paint"}}) do
		panel.button(toolbar, t[2] .. " (" .. TOOL_KEYS[t[1]] .. ")",
				function() set_tool(t[1]) end, S.tool == t[1])
	end
	local g = grid_step()
	panel.button(toolbar, "Grid " .. (g < 10 and g .. " mm" or
			(g / 10) .. " cm") .. " (G)", function()
		S.grid = S.grid % #GRID_STEPS + 1
		refresh_panels()
	end)
	local a = ANGLE_STEPS[S.angle]
	panel.button(toolbar, "Angle " .. (a and a .. " deg" or "free") ..
			" (H)", function()
		S.angle = S.angle % #ANGLE_STEPS + 1
		refresh_panels()
	end)
end

local function m2(mm2)
	return string.format("%.2f m2", mm2 / 1e6)
end

local function sel_count()
	local n = 0
	for _ in pairs(S.sel) do
		n = n + 1
	end
	return n
end

local function build_props()
	if props then
		props:Remove()
	end
	props = panel.window(magic.HA_RIGHT, magic.VA_TOP, -8, 8)
	local sel = S.primary and S.sel[S.primary] and doc.ents[S.primary]
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints,
				strs = fields.strs}}})
	end
	local function num(text)
		local v = tonumber(text)
		return v and math.floor(v + 0.5)
	end
	local function int_field(id, label, name, value)
		panel.field(props, label, value, function(t)
			local v = num(t)
			if v then set(id, {ints = {[name] = v}}) end
		end)
	end
	local count = sel_count()
	if S.tool == "node" then
		local n = 0
		for _ in pairs(S.nodes) do
			n = n + 1
		end
		panel.label(props, n .. " nodes selected")
		panel.label(props, "Drag one to move them all;")
		panel.label(props, "drop one on another to merge")
		if n > 0 then
			panel.button(props, "Delete (Del)", delete_selected)
		end
	elseif count > 1 then
		panel.label(props, count .. " selected")
		panel.button(props, "Turn left (Z)", function()
			rotate_selection(angle_step())
		end)
		panel.button(props, "Turn right (X)", function()
			rotate_selection(-angle_step())
		end)
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clones (Ctrl+L)", function()
			copy_selected(true)
		end)
		panel.button(props, "Apply the palette entry", apply_material)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "instance" then
		local i = sel.ints
		local def = doc.ents[i.def]
		local p = def.ints
		local links = instances_of(i.def)
		panel.label(props, "Box " .. sel.id .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Width mm", "w", p.w)
		int_field(i.def, "Height mm", "h", p.h)
		int_field(i.def, "Depth mm", "d", p.d)
		int_field(sel.id, "X mm", "x", i.x)
		int_field(sel.id, "Z mm", "z", i.z)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		int_field(sel.id, "Offset mm", "offset", i.offset)
		panel.button(props, i.align == 1 and "From the ceiling down" or
				"From the floor up", function()
			set(sel.id, {ints = {align = 1 - i.align}})
		end)
		local r = panel.row(props)
		panel.button(r, "Pitch +90", function()
			set(sel.id, {ints = {pitch = (i.pitch + 1) % 4}})
		end)
		panel.button(r, "Roll +90", function()
			set(sel.id, {ints = {roll = (i.roll + 1) % 4}})
		end)
		-- The gaps to the walls, typed to move the box
		if inst_data[sel.id] then
			for k, g in ipairs(wall_gaps(sel.id)) do
				if g.gap then
					panel.field(props, "Gap " .. ({"+X", "-X", "+Z", "-Z"})[k] ..
							" mm", math.floor(g.gap + 0.5), function(t)
						local v = tonumber(t)
						if v then
							local m = g.gap - v
							set(sel.id, {ints = {
									x = math.floor(i.x + g.dir[1] * m + 0.5),
									z = math.floor(i.z + g.dir[2] * m + 0.5)}})
						end
					end)
				end
			end
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Apply the palette entry", apply_material)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "wall" then
		local w = sel.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		local l = geom.len(bx - ax, bz - az)
		panel.label(props, "Wall " .. sel.id)
		panel.field(props, "Length mm", math.floor(l + 0.5), function(t)
			local v = num(t)
			if v and v > 0 and l > 0 then
				set(w.b, {ints = {x = math.floor(ax + (bx - ax) * v / l + 0.5),
						z = math.floor(az + (bz - az) * v / l + 0.5)}})
			end
		end)
		int_field(sel.id, "Thickness mm", "thickness", w.thickness)
		int_field(sel.id, "Height mm", "height", w.height)
		panel.label(props, "(height 0: to the ceiling)")
		panel.button(props, "Justify: " .. JUSTIFY_NAMES[w.justify], function()
			set(sel.id, {ints = {justify = (w.justify + 1) % 3}})
		end)
		panel.button(props, w.hang == 1 and "Hangs from the ceiling" or
				"Stands on the floor", function()
			set(sel.id, {ints = {hang = 1 - w.hang}})
		end)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "room" then
		local r = room_data[sel.id]
		panel.label(props, "Room " .. sel.id)
		panel.field(props, "Name", sel.strs.name, function(t)
			set(sel.id, {strs = {name = t}})
		end, 120)
		int_field(sel.id, "Ceiling mm", "ceiling", sel.ints.ceiling)
		panel.label(props, "(ceiling 0: the plan's)")
		if r then
			panel.label(props, "Floor " .. m2(r.net) .. " net")
			panel.label(props, m2(r.gross) .. " to the wall lines")
		end
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "node" then
		panel.label(props, "Node " .. sel.id)
		int_field(sel.id, "X mm", "x", sel.ints.x)
		int_field(sel.id, "Z mm", "z", sel.ints.z)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif S.tool == "box" then
		panel.label(props, "New boxes: drag the footprint")
		for _, f in ipairs({{"Width mm", "w"}, {"Height mm", "h"},
				{"Depth mm", "d"}, {"Offset mm", "offset"}}) do
			panel.field(props, f[1], S.box[f[2]], function(t)
				local v = num(t)
				if v and (v > 0 or f[2] == "offset") then S.box[f[2]] = v end
			end)
		end
		panel.button(props, S.box.align == 1 and "From the ceiling down" or
				"From the floor up", function()
			S.box.align = 1 - S.box.align
			refresh_panels()
		end)
	else
		panel.label(props, "New walls")
		panel.field(props, "Thickness mm", S.thickness, function(t)
			local v = num(t)
			if v and v > 0 then S.thickness = v end
		end)
		panel.field(props, "Height mm", S.height, function(t)
			local v = num(t)
			if v and v >= 0 then S.height = v end
		end)
		panel.button(props, "Justify: " .. JUSTIFY_NAMES[S.justify], function()
			S.justify = (S.justify + 1) % 3
			refresh_panels()
		end)
		panel.button(props, S.hang == 1 and "Hang from the ceiling" or
				"Stand on the floor", function()
			S.hang = 1 - S.hang
			refresh_panels()
		end)
		panel.button(props, S.room_walls and "Rooms get walls" or
				"Rooms get no walls", function()
			S.room_walls = not S.room_walls
			refresh_panels()
		end)
		local st = settings()
		local sid = doc.settings().id
		panel.label(props, "Plan")
		int_field(sid, "Ceiling mm", "ceiling", st.ceiling)
		int_field(sid, "Plan cut mm", "cut", st.cut)
	end
	if not doc.can("edit") then
		panel.label(props, "Viewing only: no edit privilege",
				magic.Color(1, 0.6, 0.4))
	end
end

local function build_palette()
	if palette_win then
		palette_win:Remove()
	end
	palette_win = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 50)
	panel.label(palette_win, "Palette")
	local cur = default_material()
	local entries = doc.of_type("palette")
	for _, p in ipairs(entries) do
		local r = panel.row(palette_win)
		panel.swatch(r, p.ints.color, function()
			S.material = p.id
			refresh_panels()
		end, p.id == cur)
		panel.label(r, p.strs.name, p.id == cur and
				magic.Color(1.0, 0.85, 0.3) or nil)
	end
	local e = doc.ents[cur]
	if e then
		panel.field(palette_win, "Name", e.strs.name, function(t)
			send({{op = "set", ent = {id = cur, strs = {name = t}}}})
		end, 120)
		panel.field(palette_win, "Colour", string.format("%06x", e.ints.color),
				function(t)
			local v = tonumber(t, 16)
			if v then
				send({{op = "set", ent = {id = cur, ints = {color = v}}}})
			end
		end, 120)
	end
	panel.button(palette_win, "New entry", function()
		local ph = doc.placeholder()
		local c = e and e.ints.color or 0xe8e4dc
		send({{op = "create", ent = {id = ph, type = "palette",
				ints = {color = c}, strs = {name = "material " ..
				(#entries + 1)}}}}, function(err)
			if err == "" then
				S.material = S.real[ph]
				refresh_panels()
			end
		end)
	end)
end

refresh_panels = function()
	-- A field being typed in is not pulled from under the typing; the
	-- rebuild waits for the next change after it
	if doc.typing() then
		S.panels_stale = true
		return
	end
	S.panels_stale = false
	build_toolbar()
	build_props()
	build_palette()
end
M.refresh_panels = function() refresh_panels() end

local function over_ui()
	local s = magic.ui.scale
	return panel.over({toolbar, props, palette_win}, S.mx / s, S.my / s)
end

--
-- Input
--
local function begin_press(button)
	if button ~= magic.MOUSEB_LEFT or over_ui() then
		return
	end
	local x, z = cursor_floor()
	S.press = {mx = S.mx, my = S.my, x = x, z = z}
	if S.tool == "select" then
		-- An object under the cursor wins; then a node near it, then the
		-- wall or room it is on
		local s = pick_surface()
		if s and s.kind == "instance" then
			S.press.target = {kind = "instance", id = s.id}
			return
		end
		local n = x and nearest_node(x, z, snap_radius())
		if n then
			S.press.target = {kind = "node", id = n}
		elseif s then
			S.press.target = {kind = s.kind == "wall" and "wall" or "room",
					id = s.id}
		end
	elseif S.tool == "node" then
		local n = x and nearest_node(x, z, snap_radius())
		if n then
			S.press.target = {kind = "node", id = n}
		end
	end
end

local function start_drag()
	local t = S.press.target
	if S.tool == "box" then
		local x, z = snapped_point(nil)
		if x then
			S.drag = {kind = "footprint", x0 = x, z0 = z, x1 = x, z1 = z}
		end
		return
	end
	if (S.tool == "node" or S.tool == "select") and not t then
		-- A box over what to select
		S.drag = {kind = "box"}
		return
	end
	if not t or not doc.can("edit") then
		return
	end
	if S.tool == "node" then
		if S.nodes[t.id] and next(S.nodes, next(S.nodes)) then
			local nodes = {}
			for id in pairs(S.nodes) do
				nodes[id] = true
			end
			S.drag = {kind = "move", inst = {}, nodes = nodes, dx = 0, dz = 0,
					moved = true}
		else
			S.nodes = {[t.id] = true}
			S.drag = {kind = "node", id = t.id, moved = true,
					x = doc.ents[t.id].ints.x, z = doc.ents[t.id].ints.z}
		end
		return
	end
	-- The select tool: what is pressed joins the selection unless it is in
	-- it already, and the drag moves all of it; a lone node drags alone
	if not S.sel[t.id] then
		if not S.shift then
			S.sel = {}
		end
		S.sel[t.id] = t.kind
	end
	S.primary = t.id
	if t.kind == "node" and sel_count() == 1 then
		S.drag = {kind = "node", id = t.id, moved = true,
				x = doc.ents[t.id].ints.x, z = doc.ents[t.id].ints.z}
	else
		local inst, nodes = moved_by(S.sel)
		S.drag = {kind = "move", inst = inst, nodes = nodes, dx = 0, dz = 0,
				moved = true}
	end
end

local function update_drag()
	local d = S.drag
	if d.kind == "box" then
		return
	end
	if d.kind == "footprint" then
		local x, z = snapped_point(nil)
		if x then
			d.x1, d.z1 = x, z
		end
		return
	end
	if d.kind == "node" then
		local x, z, ref = snapped_point(nil, {[d.id] = true})
		if x then
			d.x, d.z, d.onto = x, z, ref.node
		end
	else
		local x, z = cursor_floor()
		if x and S.press.x then
			local g = grid_step()
			d.dx = geom.snap(x - S.press.x, g)
			d.dz = geom.snap(z - S.press.z, g)
		end
	end
	S.dirty = true
end

-- The screen point of a plan point, in pixels
local function to_screen(x, z)
	local cam = S.view == "2d" and cam2d or cam3d
	local p = cam:WorldToScreenPoint(magic.Vector3(W(x), 0, W(z)))
	local w, h = screen_size()
	return p.x * w, p.y * h
end

-- simplified: a drag is sent when it is released, so others see it land
-- rather than move; streaming it goes with the drag locks in [FP_UNDO]
local function end_drag()
	local d = S.drag
	S.drag = nil
	S.dirty = true
	if d.kind == "box" then
		local x0, x1 = math.min(S.press.mx, S.mx), math.max(S.press.mx, S.mx)
		local y0, y1 = math.min(S.press.my, S.my), math.max(S.press.my, S.my)
		local function inside(x, z)
			local sx, sy = to_screen(x, z)
			return sx >= x0 and sx <= x1 and sy >= y0 and sy <= y1
		end
		if S.tool == "node" then
			if not S.shift then
				S.nodes = {}
			end
			for _, n in ipairs(doc.of_type("node")) do
				if inside(n.ints.x, n.ints.z) then
					S.nodes[n.id] = true
				end
			end
		else
			if not S.shift then
				S.sel = {}
			end
			for id, it in pairs(inst_data) do
				if inside(it.x, it.z) then
					S.sel[id] = "instance"
					S.primary = id
				end
			end
			for id, w in pairs(wall_data) do
				if inside(w.ax, w.az) and inside(w.bx, w.bz) then
					S.sel[id] = "wall"
					S.primary = id
				end
			end
			for id, r in pairs(room_data) do
				local all = true
				for _, p in ipairs(r.pts) do
					all = all and inside(p[1], p[2])
				end
				if all then
					S.sel[id] = "room"
					S.primary = id
				end
			end
		end
		refresh_panels()
	elseif d.kind == "footprint" then
		local w, dd = math.abs(d.x1 - d.x0), math.abs(d.z1 - d.z0)
		if w >= 1 and dd >= 1 and doc.can("edit") then
			add_box((d.x0 + d.x1) / 2, (d.z0 + d.z1) / 2, w, dd)
		end
	elseif d.kind == "node" then
		if d.onto then
			send(merge_ops(d.id, d.onto))
			S.nodes = {}
		else
			send({{op = "set", ent = {id = d.id, ints = {x = d.x, z = d.z}}}})
		end
	elseif d.dx ~= 0 or d.dz ~= 0 then
		local ops = {}
		for n in pairs(d.nodes) do
			local p = doc.ents[n] and doc.ents[n].ints
			if p then
				ops[#ops + 1] = {op = "set", ent = {id = n,
						ints = {x = p.x + d.dx, z = p.z + d.dz}}}
			end
		end
		for id in pairs(d.inst) do
			local i = doc.ents[id] and doc.ents[id].ints
			if i then
				ops[#ops + 1] = {op = "set", ent = {id = id,
						ints = {x = i.x + d.dx, z = i.z + d.dz}}}
			end
		end
		send(ops)
	end
end

local function click()
	local t = S.press.target
	if S.tool == "select" then
		if not S.shift then
			S.sel = {}
			S.primary = nil
		end
		if t then
			if S.sel[t.id] and S.shift then
				S.sel[t.id] = nil
			else
				S.sel[t.id] = t.kind
				S.primary = t.id
			end
		end
		refresh_panels()
	elseif S.tool == "node" then
		if not S.shift then
			S.nodes = {}
		end
		if t and t.kind == "node" then
			S.nodes[t.id] = not S.nodes[t.id] or nil
		end
		refresh_panels()
	elseif S.tool == "box" then
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local x, z = snapped_point(nil)
		if x then
			add_box(x, z, S.box.w, S.box.d)
		end
	elseif S.tool == "wall" or S.tool == "room" then
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local from = S.tool == "wall" and S.draw or
				(S.corners and S.corners[#S.corners])
		local x, z, ref = snapped_point(from)
		if not x then
			return
		end
		S.typed = ""
		if S.tool == "room" then
			S.corners = S.corners or {}
			local first = S.corners[1]
			if first and #S.corners >= 3 and
					geom.len(x - first.x, z - first.z) <= snap_radius() then
				add_room(S.corners)
				S.corners = nil
			else
				S.corners[#S.corners + 1] = {x = x, z = z, ref = ref}
			end
		elseif S.draw then
			if S.draw.ref and S.draw.ref.node and not real_id(S.draw.ref.node) then
				-- The last segment's node has not come back yet
				return
			end
			add_wall(S.draw, x, z, ref)
		else
			S.draw = {x = x, z = z, ref = ref}
		end
	elseif S.tool == "paint" then
		local s = pick_surface()
		if s and doc.can("edit") then
			if s.kind == "instance" then
				send({{op = "set", ent = {id = doc.ents[s.id].ints.def,
						ints = {mat = default_material()}}}})
				return
			end
			local f = s.kind == "floor" and "mat_floor" or
					s.kind == "ceiling" and "mat_ceiling" or
					s.side == "left" and "mat_left" or
					s.side == "right" and "mat_right" or "mat_core"
			send({{op = "set", ent = {id = s.id,
					ints = {[f] = default_material()}}}})
		end
	end
end

function M.mouse_down(button)
	if button == magic.MOUSEB_RIGHT then
		if S.draw or S.corners then
			S.draw = nil
			S.corners = nil
			S.typed = ""
			return
		end
		if S.view == "3d" then
			S.looking = true
			magic.input:SetMouseMode(magic.MM_RELATIVE)
		end
		return
	end
	if button == magic.MOUSEB_MIDDLE then
		S.panning = true
		return
	end
	begin_press(button)
end

function M.mouse_up(button)
	if button == magic.MOUSEB_RIGHT then
		if S.looking then
			S.looking = false
			magic.input:SetMouseMode(magic.MM_ABSOLUTE)
		end
		return
	end
	if button == magic.MOUSEB_MIDDLE then
		S.panning = false
		return
	end
	if button ~= magic.MOUSEB_LEFT or not S.press then
		return
	end
	if S.drag then
		end_drag()
	else
		click()
	end
	S.press = nil
end

function M.mouse_move(x, y, dx, dy)
	if S.looking then
		S.yaw = S.yaw + dx * 0.15
		S.pitch = math.max(-89, math.min(89, S.pitch + dy * 0.15))
		return
	end
	S.mx, S.my = x, y
	if S.panning and S.view == "2d" then
		local k = mm_per_px()
		S.cx = S.cx - dx * k
		S.cz = S.cz + dy * k
	end
	if S.press and not S.drag and geom.len(x - S.press.mx, y - S.press.my) >
			DRAG_PX then
		start_drag()
	end
	if S.drag then
		update_drag()
	end
end

function M.mouse_wheel(wheel)
	if over_ui() then
		return
	end
	if S.view == "2d" then
		-- Zoom about the cursor: the point under it stays under it
		local x0, z0 = cursor_floor()
		S.span = math.max(500, math.min(200000, S.span * (wheel > 0 and 0.8
				or 1.25)))
		local x1, z1 = cursor_floor()
		S.cx, S.cz = S.cx + x0 - x1, S.cz + z0 - z1
	else
		local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
		local k = wheel > 0 and 1 or -1
		S.pos = {x = S.pos.x + math.sin(yaw) * math.cos(pitch) * k,
				y = S.pos.y - math.sin(pitch) * k,
				z = S.pos.z + math.cos(yaw) * math.cos(pitch) * k}
	end
end

-- A length typed while drawing: Enter draws the segment that long, in the
-- direction the cursor gives
local function commit_typed()
	local v = tonumber(S.typed)
	S.typed = ""
	local from = S.draw or (S.corners and S.corners[#S.corners])
	if not v or v <= 0 or not from then
		return
	end
	local x, z = snapped_point(from)
	if not x then
		return
	end
	local dx, dz = x - from.x, z - from.z
	local l = geom.len(dx, dz)
	if l == 0 then
		return
	end
	x = math.floor(from.x + dx / l * v + 0.5)
	z = math.floor(from.z + dz / l * v + 0.5)
	if S.draw then
		add_wall(S.draw, x, z, {})
	else
		S.corners[#S.corners + 1] = {x = x, z = z, ref = {}}
	end
end

function M.key_down(key, event_data)
	local ctrl = event_data and event_data:GetInt("Qualifiers") % 4 >= 2
	if S.draw or S.corners then
		local digit = key >= magic.KEY_0 and key <= magic.KEY_9
		if digit then
			S.typed = S.typed .. tostring(key - magic.KEY_0)
			return
		elseif key == magic.KEY_BACKSPACE then
			S.typed = S.typed:sub(1, -2)
			return
		elseif key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
			if S.typed == "" and S.corners and #S.corners >= 3 then
				add_room(S.corners)
				S.corners = nil
			else
				commit_typed()
			end
			return
		end
	end
	if ctrl then
		if key == magic.KEY_D then
			copy_selected(false)
		elseif key == magic.KEY_L then
			copy_selected(true)
		end
		return
	end
	if key == magic.KEY_ESCAPE then
		if S.draw or S.corners then
			S.draw = nil
			S.corners = nil
			S.typed = ""
		elseif next(S.sel) or next(S.nodes) then
			S.sel = {}
			S.primary = nil
			S.nodes = {}
			refresh_panels()
		elseif S.tool ~= "select" then
			set_tool("select")
		end
	elseif key == magic.KEY_TAB then
		set_view(S.view == "2d" and "3d" or "2d")
	elseif key == magic.KEY_Z then
		rotate_selection(angle_step())
	elseif key == magic.KEY_X then
		rotate_selection(-angle_step())
	elseif key == magic.KEY_V then
		set_tool("select")
	elseif key == magic.KEY_N then
		set_tool("node")
	elseif key == magic.KEY_B then
		set_tool("wall")
	elseif key == magic.KEY_R then
		set_tool("room")
	elseif key == magic.KEY_O then
		set_tool("box")
	elseif key == magic.KEY_P then
		set_tool("paint")
	elseif key == magic.KEY_G then
		S.grid = S.grid % #GRID_STEPS + 1
		refresh_panels()
	elseif key == magic.KEY_H then
		S.angle = S.angle % #ANGLE_STEPS + 1
		refresh_panels()
	elseif key == magic.KEY_DELETE then
		delete_selected()
	end
end

--
-- Every frame
--
local function move_camera(dt)
	local input = magic.input
	S.shift = input:GetKeyDown(magic.KEY_LSHIFT) or
			input:GetKeyDown(magic.KEY_RSHIFT)
	if doc.typing() or input:GetKeyDown(magic.KEY_LCTRL) and S.view == "2d" then
		return
	end
	local f, r, u = 0, 0, 0
	if input:GetKeyDown(magic.KEY_W) then f = f + 1 end
	if input:GetKeyDown(magic.KEY_S) then f = f - 1 end
	if input:GetKeyDown(magic.KEY_D) then r = r + 1 end
	if input:GetKeyDown(magic.KEY_A) then r = r - 1 end
	if S.view == "2d" then
		local k = S.span * dt
		S.cx = S.cx + r * k
		S.cz = S.cz + f * k
		return
	end
	if input:GetKeyDown(magic.KEY_SPACE) then u = u + 1 end
	if input:GetKeyDown(magic.KEY_C) then u = u - 1 end
	local speed = (input:GetKeyDown(magic.KEY_LCTRL) and 12 or 4) * dt
	local yaw = math.rad(S.yaw)
	S.pos = {x = S.pos.x + (math.sin(yaw) * f + math.cos(yaw) * r) * speed,
			y = S.pos.y + u * speed,
			z = S.pos.z + (math.cos(yaw) * f - math.sin(yaw) * r) * speed}
end

local function place_cameras()
	local w, h = screen_size()
	cam2d.orthoSize = W(S.span)
	cam2d.aspectRatio = w / h
	cam2d_node.position = magic.Vector3(W(S.cx), W(settings().cut), W(S.cz))
	cam3d.aspectRatio = w / h
	cam3d_node.position = magic.Vector3(S.pos.x, S.pos.y, S.pos.z)
	cam3d_node.rotation = magic.Quaternion(S.pitch, S.yaw, 0)
	-- The ceilings and what hangs from them are seen from inside the
	-- rooms, and are out of the way of a camera above them
	-- simplified: against the plan's ceiling, not each room's own
	overhead_node.enabled = S.view == "3d" and
			S.pos.y * 1000 < settings().ceiling
end

-- A text over a place in the world, for this frame
local label_i = 0
local function world_label(x_mm, y_mm, z_mm, text)
	label_i = label_i + 1
	local t = label_nodes[label_i]
	if not t then
		t = magic.ui.root:CreateChild("Text")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 13)
		t:SetTextEffect(magic.TE_SHADOW)
		label_nodes[label_i] = t
	end
	local cam = S.view == "2d" and cam2d or cam3d
	local p = cam:WorldToScreenPoint(magic.Vector3(W(x_mm), W(y_mm), W(z_mm)))
	t:SetText(text)
	t.visible = true
	t:SetPosition(math.floor(p.x * magic.ui.root.width) + 8,
			math.floor(p.y * magic.ui.root.height) - 18)
end

local function mm_text(v)
	return string.format("%d mm", math.floor(v + 0.5))
end

local function draw_overlay()
	local y = S.view == "2d" and W(settings().cut) - 0.001 or 0.004
	local function P(x, z, yy)
		return magic.Vector3(W(x), yy or y, W(z))
	end
	local function line(ax, az, bx, bz, col)
		debug:AddLine(P(ax, az), P(bx, bz), col, false)
	end
	local function dashed(pts, col)
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local l = geom.len(q[1] - p[1], q[2] - p[2])
			local n = math.max(1, math.floor(l / (6 * mm_per_px())))
			for j = 0, n - 1, 2 do
				line(p[1] + (q[1] - p[1]) * j / n, p[2] + (q[2] - p[2]) * j / n,
						p[1] + (q[1] - p[1]) * (j + 1) / n,
						p[2] + (q[2] - p[2]) * (j + 1) / n, col)
			end
		end
	end
	local function outline(pts, col, ys)
		for _, yy in ipairs(ys or {y}) do
			for i = 1, #pts do
				local p, q = pts[i], pts[i % #pts + 1]
				debug:AddLine(P(p[1], p[2], yy), P(q[1], q[2], yy), col, false)
			end
		end
	end
	local dark = magic.Color(0.2, 0.2, 0.25)
	-- The grid, in the plan view: the snap step where it is at least 8
	-- pixels, coarser where it is not, and every metre darker
	if S.view == "2d" then
		local k = mm_per_px()
		local step = grid_step()
		while step / k < 8 do
			step = step * 10
		end
		local w, h = screen_size()
		local x0, x1 = S.cx - S.span * w / h / 2, S.cx + S.span * w / h / 2
		local z0, z1 = S.cz - S.span / 2, S.cz + S.span / 2
		local fine = magic.Color(0.62, 0.62, 0.62)
		local major = magic.Color(0.45, 0.45, 0.48)
		local gy = 0.004
		for gx = math.floor(x0 / step) * step, x1, step do
			debug:AddLine(P(gx, z0, gy), P(gx, z1, gy),
					gx % 1000 == 0 and major or fine, true)
		end
		for gz = math.floor(z0 / step) * step, z1, step do
			debug:AddLine(P(x0, gz, gy), P(x1, gz, gy),
					gz % 1000 == 0 and major or fine, true)
		end
		-- The rooms' names and areas
		for id, r in pairs(room_data) do
			local cx, cz = geom.centroid(r.pts)
			world_label(cx, 0, cz, doc.ents[id].strs.name .. "\n" .. m2(r.net))
		end
		-- What is above the cut, dashed; the objects below it outlined
		local cut = settings().cut
		for id, o in pairs(outlines) do
			if wall_span(doc.ents[id].ints) >= cut then
				dashed(o.pts, dark)
			end
		end
		for _, it in pairs(inst_data) do
			if it.y0 >= cut then
				dashed(it.foot, dark)
			else
				outline(it.foot, dark)
			end
		end
	end
	local accent = magic.Color(1.0, 0.6, 0.1)
	for id, kind in pairs(S.sel) do
		if kind == "wall" and outlines[id] then
			local y0, y1 = wall_span(doc.ents[id].ints)
			outline(outlines[id].pts, accent, S.view == "3d" and
					{W(y0) + 0.004, W(y1) + 0.004} or nil)
			local w = wall_data[id]
			world_label((w.ax + w.bx) / 2, 0, (w.az + w.bz) / 2,
					mm_text(geom.len(w.bx - w.ax, w.bz - w.az)))
		elseif kind == "room" and room_data[id] then
			outline(room_data[id].pts, accent)
			outline(room_data[id].inner, magic.Color(0.2, 0.6, 1.0))
		elseif kind == "instance" and inst_data[id] then
			local it = inst_data[id]
			outline(it.foot, accent, S.view == "3d" and
					{W(it.y0) + 0.004, W(it.y1) + 0.004} or nil)
		end
	end
	-- The primary object's gaps to the walls
	if S.primary and S.sel[S.primary] == "instance" and inst_data[S.primary] and
			not S.drag then
		local it = inst_data[S.primary]
		for _, g in ipairs(wall_gaps(S.primary)) do
			if g.gap and g.gap > 0 then
				local ax, az = it.x + g.dir[1] * g.half, it.z + g.dir[2] * g.half
				local bx, bz = ax + g.dir[1] * g.gap, az + g.dir[2] * g.gap
				line(ax, az, bx, bz, magic.Color(0.2, 0.6, 1.0))
				world_label((ax + bx) / 2, 0, (az + bz) / 2, mm_text(g.gap))
			end
		end
	end
	-- Nodes, for the tools that pick them
	if S.tool == "select" or S.tool == "node" then
		local size = S.view == "2d" and W(6 * mm_per_px()) or 0.08
		for _, n in ipairs(doc.of_type("node")) do
			local x, z = node_pos(n.id)
			local on = S.sel[n.id] or S.nodes[n.id]
			debug:AddCross(P(x, z), size, on and accent or
					magic.Color(0.1, 0.3, 0.8), S.view == "3d")
		end
	end
	-- The box being dragged out, and a box's footprint being drawn
	local d = S.drag
	if d and d.kind == "box" and S.view == "2d" then
		local w, h = screen_size()
		local function pz(px, py)
			return S.cx + (px / w - 0.5) * S.span * w / h,
					S.cz - (py / h - 0.5) * S.span
		end
		local ax, az = pz(S.press.mx, S.press.my)
		local bx, bz = pz(S.mx, S.my)
		outline({{ax, az}, {bx, az}, {bx, bz}, {ax, bz}}, accent)
	elseif d and d.kind == "footprint" then
		outline({{d.x0, d.z0}, {d.x1, d.z0}, {d.x1, d.z1}, {d.x0, d.z1}},
				accent)
		world_label(d.x1, 0, d.z1, mm_text(math.abs(d.x1 - d.x0)) .. " x " ..
				mm_text(math.abs(d.z1 - d.z0)))
	end
	-- What the wall and room tools would do on a click
	if (S.tool == "wall" or S.tool == "room") and not over_ui() then
		local from = S.draw or (S.corners and S.corners[#S.corners])
		local x, z, ref = snapped_point(from)
		if x then
			local col = ref.node and magic.Color(0.1, 0.8, 0.2) or ref.edge and
					magic.Color(0.9, 0.3, 0.9) or accent
			local size = S.view == "2d" and W(8 * mm_per_px()) or 0.12
			debug:AddCross(P(x, z), size, col, false)
			if S.corners then
				for i = 2, #S.corners do
					line(S.corners[i - 1].x, S.corners[i - 1].z,
							S.corners[i].x, S.corners[i].z, accent)
				end
				line(S.corners[1].x, S.corners[1].z, x, z,
						magic.Color(0.9, 0.6, 0.3, 0.5))
			end
			if from then
				line(from.x, from.z, x, z, accent)
				local l = geom.len(x - from.x, z - from.z)
				world_label(x, 0, z, S.typed ~= "" and S.typed .. "_ mm" or
						mm_text(l))
			end
		end
	end
end

function M.update(dt)
	move_camera(dt)
	place_cameras()
	if S.dirty then
		rebuild()
	end
	if S.panels_stale and not doc.typing() then
		refresh_panels()
	end
	label_i = 0
	draw_overlay()
	for i = label_i + 1, #label_nodes do
		label_nodes[i].visible = false
	end
end

function M.start(d)
	doc = d
	S.material = nil
	doc.listeners[#doc.listeners + 1] = function(changed, deleted)
		for id in pairs(S.sel) do
			if not doc.ents[id] then
				S.sel[id] = nil
			end
		end
		if S.primary and not S.sel[S.primary] then
			S.primary = next(S.sel)
		end
		for id in pairs(S.nodes) do
			if not doc.ents[id] then
				S.nodes[id] = nil
			end
		end
		-- The panel reads the instances' placement and gaps
		rebuild()
		refresh_panels()
	end
	doc.privs_changed = refresh_panels
	magic.SubscribeToEvent("MouseButtonDown", function(_, data)
		M.mouse_down(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseButtonUp", function(_, data)
		M.mouse_up(data:GetInt("Button"))
	end)
	magic.SubscribeToEvent("MouseMove", function(_, data)
		M.mouse_move(data:GetInt("X"), data:GetInt("Y"), data:GetInt("DX"),
				data:GetInt("DY"))
	end)
	magic.SubscribeToEvent("MouseWheel", function(_, data)
		M.mouse_wheel(data:GetInt("Wheel"))
	end)
	set_view("2d")
	log:info("Editor started")
end

return M
-- vim: set noet ts=4 sw=4:
