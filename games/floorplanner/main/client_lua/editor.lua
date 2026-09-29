-- Buildat: games/floorplanner/main/client_lua/editor.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The editor: the scene built from the replica, the two cameras, the tools
-- and the panels. [FP_WALLS]: nodes and walls, drawn in 2D or 3D.
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
-- How near, in pixels, the cursor snaps to a node or a wall
local SNAP_PX = 12
local DRAG_PX = 4
local JUSTIFY_NAMES = {[0] = "centered", [1] = "left", [2] = "right"}

local S = {
	view = "2d",
	tool = "select",
	grid = 2,       -- index into GRID_STEPS
	angle = 4,      -- index into ANGLE_STEPS: the angle snap with shift
	-- New walls
	thickness = 100,
	justify = 0,
	height = 0,
	hang = 0,
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
	typed = "",     -- a length being typed while drawing
	press = nil,    -- a mouse press that may become a drag
	drag = nil,     -- {kind = "node"|"wall", ...}
	selected = nil, -- {kind = "node"|"wall", id}
	hover = nil,
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

local ground_node = scene:CreateChild("Ground")
do
	local g = ground_node:CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	local r = 200
	local col = magic.Color(0.6, 0.6, 0.58)
	local up = magic.Vector3(0, 1, 0)
	local a, b = magic.Vector3(-r, 0, -r), magic.Vector3(r, 0, -r)
	local c, d = magic.Vector3(r, 0, r), magic.Vector3(-r, 0, r)
	tri(g, a, b, c, up, col)
	tri(g, a, c, d, up, col)
	g:Commit()
	g:SetMaterial(0, lit_material)
end

local walls_node = scene:CreateChild("Walls")
local caps_node = scene:CreateChild("Caps")

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
		elseif d.kind == "wall" and (d.a == id or d.b == id) then
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

-- The walls with their ends looked up, and their outlines
local outlines = {}
local wall_data = {}
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

-- simplified: every wall is rebuilt on any change, which at a few hundred
-- walls is milliseconds; the upgrade is rebuilding only the walls at the
-- nodes that moved and their neighbours
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
	for _, n in ipairs(built) do
		n:Remove()
	end
	built = {}
	local cut = settings().cut
	for id, o in pairs(outlines) do
		local w = doc.ents[id].ints
		local y0, y1 = wall_span(w)
		local cols = {
			left = rgb_color(palette_rgb(w.mat_left)),
			right = rgb_color(palette_rgb(w.mat_right)),
			core = rgb_color(palette_rgb(w.mat_core ~= 0 and w.mat_core or
					w.mat_left)),
		}
		local node = walls_node:CreateChild("wall")
		built[#built + 1] = node
		local g = node:CreateComponent("CustomGeometry")
		g:SetNumGeometries(1)
		g:BeginGeometry(0, magic.TRIANGLE_LIST)
		local pts = o.pts
		local tris = geom.triangulate(pts)
		local function v(p, y)
			return magic.Vector3(W(p[1]), W(y), W(p[2]))
		end
		local up, down = magic.Vector3(0, 1, 0), magic.Vector3(0, -1, 0)
		for _, t in ipairs(tris) do
			tri(g, v(pts[t[1]], y1), v(pts[t[2]], y1), v(pts[t[3]], y1), up,
					cols.core)
			if y0 > 0 then
				tri(g, v(pts[t[1]], y0), v(pts[t[2]], y0), v(pts[t[3]], y0),
						down, cols.core)
			end
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
		g:Commit()
		g:SetMaterial(0, lit_material)

		-- What the plan view shows where the cut goes through a wall: dark
		-- where it is cut, lighter for a wall below the cut
		if y0 < cut then
			local cap = caps_node:CreateChild("cap")
			built[#built + 1] = cap
			local cg = cap:CreateComponent("CustomGeometry")
			cg:SetNumGeometries(1)
			cg:BeginGeometry(0, magic.TRIANGLE_LIST)
			local y = math.min(y1, cut) - 3
			local col = y1 >= cut and magic.Color(0.16, 0.16, 0.18) or
					magic.Color(0.55, 0.55, 0.58)
			for _, t in ipairs(tris) do
				tri(cg, v(pts[t[1]], y), v(pts[t[2]], y), v(pts[t[3]], y), up,
						col)
			end
			cg:Commit()
			cg:SetMaterial(0, flat_material)
		end
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

-- Where the cursor is on the floor, in mm; nil when looking above it
local function cursor_floor()
	local o, d = cursor_ray()
	if d.y > -1e-6 then
		return nil
	end
	local t = -o.y / d.y
	return (o.x + d.x * t) * 1000, (o.z + d.z * t) * 1000
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

-- The node nearest to (x, z) within r, skipping `except`
local function nearest_node(x, z, r, except)
	local best, bd = nil, r
	for _, n in ipairs(doc.of_type("node")) do
		if n.id ~= except then
			local nx, nz = node_pos(n.id)
			local d = geom.len(nx - x, nz - z)
			if d <= bd then
				best, bd = n.id, d
			end
		end
	end
	return best
end

-- The wall whose line is nearest to (x, z) within r: id, point, distance
-- along it from a
local function nearest_wall(x, z, r, except_node)
	local best, bx, bz, bt = nil, 0, 0, 0
	local bd = r
	for id, w in pairs(wall_data) do
		if w.a_node ~= except_node and w.b_node ~= except_node then
			local px, pz, t, d = geom.nearest_on_segment(x, z, w.ax, w.az,
					w.bx, w.bz)
			if d <= bd and t > 0 and t < 1 then
				best, bx, bz, bd = id, px, pz, d
				bt = t * geom.len(w.bx - w.ax, w.bz - w.az)
			end
		end
	end
	return best, bx, bz, bt
end

-- The wall under the cursor: in 2D the outline the point is in, in 3D the
-- first face the ray hits. Returns id and, for painting, which face.
local function pick_wall()
	if S.view == "2d" then
		local x, z = cursor_floor()
		for id, o in pairs(outlines) do
			if geom.point_in_polygon(x, z, o.pts) then
				local w = wall_data[id]
				local side = (w.bx - w.ax) * (z - w.az) -
						(w.bz - w.az) * (x - w.ax) > 0 and "left" or "right"
				return id, side
			end
		end
		return nil
	end
	local o, d = cursor_ray()
	local best, best_t, best_side = nil, math.huge, nil
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
					local _, _, s, dist = geom.nearest_on_segment(hx, hz,
							px, pz, qx, qz)
					if dist < 1e-4 and hy >= y0 and hy <= y1 then
						best, best_t, best_side = id, t, ol.sides[i]
					end
				end
			end
		end
		if math.abs(d.y) > 1e-9 then
			local t = (y1 - o.y) / d.y
			if t > 0 and t < best_t then
				local hx, hz = (o.x + d.x * t) * 1000, (o.z + d.z * t) * 1000
				if geom.point_in_polygon(hx, hz, pts) then
					best, best_t, best_side = id, t, "core"
				end
			end
		end
	end
	return best, best_side
end

-- Where a point the cursor gives lands: on a node, on a wall's line, or on
-- the grid. from: the point a segment is drawn from, for the angle snap.
-- Returns x, z and what it landed on: {node = id} or {wall = id, t = mm}.
local function snapped_point(from, except_node)
	local x, z = cursor_floor()
	if not x then
		return nil
	end
	local r = snap_radius()
	local n = nearest_node(x, z, r, except_node)
	if n then
		local nx, nz = node_pos(n)
		return nx, nz, {node = n}
	end
	local wid, wx, wz, wt = nearest_wall(x, z, r, except_node)
	if wid then
		-- Along the wall, the distance from its a end is what snaps
		local w = wall_data[wid]
		local l = geom.len(w.bx - w.ax, w.bz - w.az)
		local t = math.max(1, math.min(l - 1, geom.snap(wt, grid_step())))
		return w.ax + (w.bx - w.ax) * t / l, w.az + (w.bz - w.az) * t / l,
				{wall = wid, t = t}
	end
	if from then
		local step = S.shift and ANGLE_STEPS[S.angle] or 90
		local ex, ez = geom.snap_direction(from.x, from.z, x, z,
				step or nil, grid_step())
		return math.floor(ex + 0.5), math.floor(ez + 0.5), {}
	end
	return geom.snap(x, grid_step()), geom.snap(z, grid_step()), {}
end

--
-- Batches
--
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

-- The ops that give a point a node: an existing one, one splitting a wall,
-- or a new one. Returns the node's id (maybe a placeholder).
local function node_for(ops, x, z, ref)
	if ref and ref.node then
		return real_id(ref.node)
	end
	local ph = doc.placeholder()
	ops[#ops + 1] = {op = "create", ent = {id = ph, type = "node",
			ints = {x = math.floor(x + 0.5), z = math.floor(z + 0.5)}}}
	if ref and ref.wall and doc.ents[ref.wall] then
		-- The wall is split at the new node: it keeps a->node and a copy of
		-- it takes node->b
		local w = doc.ents[ref.wall].ints
		ops[#ops + 1] = {op = "set", ent = {id = ref.wall, ints = {b = ph}}}
		local f = wall_fields(w)
		f.a, f.b = ph, w.b
		ops[#ops + 1] = {op = "create", ent = {id = doc.placeholder(),
				type = "wall", ints = f}}
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

local function add_wall(from, x, z, ref)
	if from.ref and ref and from.ref.wall and from.ref.wall == ref.wall then
		doc.notice("Both ends on one wall: nothing to draw")
		return false
	end
	if from.ref and ref and from.ref.node and from.ref.node == ref.node then
		return false
	end
	if geom.len(x - from.x, z - from.z) < 1 then
		return false
	end
	local ops = {}
	local a = node_for(ops, from.x, from.z, from.ref)
	if not a then
		return false
	end
	local b = node_for(ops, x, z, ref)
	local mat = default_material()
	ops[#ops + 1] = {op = "create", ent = {id = doc.placeholder(),
			type = "wall", ints = {a = a, b = b, thickness = S.thickness,
			justify = S.justify, height = S.height, hang = S.hang,
			mat_left = mat, mat_right = mat}}}
	send(ops)
	-- The chain goes on from the end, which is now a node
	S.draw = {x = x, z = z, ref = {node = b}}
	return true
end

local function delete_selected()
	local sel = S.selected
	if not sel or not doc.ents[sel.id] then
		return
	end
	local ops = {{op = "delete", ent = {id = sel.id}}}
	if sel.kind == "wall" then
		-- Its nodes go with it where nothing else holds them
		local w = doc.ents[sel.id].ints
		for _, n in ipairs({w.a, w.b}) do
			local used = false
			for _, o in ipairs(doc.of_type("wall")) do
				if o.id ~= sel.id and (o.ints.a == n or o.ints.b == n) then
					used = true
				end
			end
			if not used then
				ops[#ops + 1] = {op = "delete", ent = {id = n}}
			end
		end
	end
	S.selected = nil
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
	panel.button(toolbar, "Select (V)", function() set_tool("select") end,
			S.tool == "select")
	panel.button(toolbar, "Wall (B)", function() set_tool("wall") end,
			S.tool == "wall")
	panel.button(toolbar, "Paint (P)", function() set_tool("paint") end,
			S.tool == "paint")
	local g = grid_step()
	panel.button(toolbar, "Grid " .. (g < 10 and g .. " mm" or
			(g / 10) .. " cm") .. " (G)", function()
		S.grid = S.grid % #GRID_STEPS + 1
		refresh_panels()
	end)
	local a = ANGLE_STEPS[S.angle]
	panel.button(toolbar, "Shift angle " .. (a and a .. " deg" or "free") ..
			" (H)", function()
		S.angle = S.angle % #ANGLE_STEPS + 1
		refresh_panels()
	end)
end

local function build_props()
	if props then
		props:Remove()
	end
	props = panel.window(magic.HA_RIGHT, magic.VA_TOP, -8, 8)
	local sel = S.selected and doc.ents[S.selected.id]
	local function set(id, ints)
		send({{op = "set", ent = {id = id, ints = ints}}})
	end
	local function num(text)
		local v = tonumber(text)
		return v and math.floor(v + 0.5)
	end
	if sel and sel.type == "wall" then
		local w = sel.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		local l = geom.len(bx - ax, bz - az)
		panel.label(props, "Wall " .. sel.id)
		panel.field(props, "Length mm", math.floor(l + 0.5), function(t)
			local v = num(t)
			if v and v > 0 and l > 0 then
				set(w.b, {x = math.floor(ax + (bx - ax) * v / l + 0.5),
						z = math.floor(az + (bz - az) * v / l + 0.5)})
			end
		end)
		panel.field(props, "Thickness mm", w.thickness, function(t)
			local v = num(t)
			if v then set(sel.id, {thickness = v}) end
		end)
		panel.field(props, "Height mm", w.height, function(t)
			local v = num(t)
			if v then set(sel.id, {height = v}) end
		end)
		panel.label(props, "(height 0: to the ceiling)")
		panel.button(props, "Justify: " .. JUSTIFY_NAMES[w.justify], function()
			set(sel.id, {justify = (w.justify + 1) % 3})
		end)
		panel.button(props, w.hang == 1 and "Hangs from the ceiling" or
				"Stands on the floor", function()
			set(sel.id, {hang = 1 - w.hang})
		end)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "node" then
		panel.label(props, "Node " .. sel.id)
		panel.field(props, "X mm", sel.ints.x, function(t)
			local v = num(t)
			if v then set(sel.id, {x = v}) end
		end)
		panel.field(props, "Z mm", sel.ints.z, function(t)
			local v = num(t)
			if v then set(sel.id, {z = v}) end
		end)
		panel.button(props, "Delete (Del)", delete_selected)
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
		local st = settings()
		panel.label(props, "Plan")
		panel.field(props, "Ceiling mm", st.ceiling, function(t)
			local v = num(t)
			if v then set(doc.settings().id, {ceiling = v}) end
		end)
		panel.field(props, "Plan cut mm", st.cut, function(t)
			local v = num(t)
			if v then set(doc.settings().id, {cut = v}) end
		end)
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
		-- A node near the cursor wins over the wall it is on
		if x then
			local n = nearest_node(x, z, snap_radius())
			if n then
				S.press.target = {kind = "node", id = n}
				return
			end
		end
		local wid = pick_wall()
		if wid then
			S.press.target = {kind = "wall", id = wid}
		end
	end
end

local function start_drag()
	local t = S.press.target
	if not t or not doc.can("edit") then
		return
	end
	if t.kind == "node" then
		S.drag = {kind = "node", id = t.id, moved = true,
				x = doc.ents[t.id].ints.x, z = doc.ents[t.id].ints.z}
	else
		local w = doc.ents[t.id].ints
		S.drag = {kind = "wall", id = t.id, a = w.a, b = w.b, dx = 0, dz = 0,
				moved = true}
	end
	S.selected = {kind = t.kind, id = t.id}
end

local function update_drag()
	local d = S.drag
	if d.kind == "node" then
		local x, z = snapped_point(nil, d.id)
		if x then
			d.x, d.z = x, z
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

-- simplified: a drag is sent when it is released, so others see it land
-- rather than move; streaming it goes with the drag locks in [FP_UNDO]
local function end_drag()
	local d = S.drag
	S.drag = nil
	S.dirty = true
	if d.kind == "node" then
		send({{op = "set", ent = {id = d.id, ints = {x = d.x, z = d.z}}}})
	elseif d.dx ~= 0 or d.dz ~= 0 then
		local ops = {}
		for _, n in ipairs({d.a, d.b}) do
			local p = doc.ents[n].ints
			ops[#ops + 1] = {op = "set", ent = {id = n,
					ints = {x = p.x + d.dx, z = p.z + d.dz}}}
		end
		send(ops)
	end
end

local function click()
	local t = S.press.target
	if S.tool == "select" then
		S.selected = t and {kind = t.kind, id = t.id} or nil
		refresh_panels()
	elseif S.tool == "wall" then
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local x, z, ref = snapped_point(S.draw)
		if not x then
			return
		end
		if S.draw then
			if S.draw.ref and S.draw.ref.node and not real_id(S.draw.ref.node) then
				-- The last segment's node has not come back yet
				return
			end
			add_wall(S.draw, x, z, ref)
		else
			S.draw = {x = x, z = z, ref = ref}
		end
		S.typed = ""
	elseif S.tool == "paint" then
		local id, side = pick_wall()
		if id and doc.can("edit") then
			local f = side == "left" and "mat_left" or side == "right" and
					"mat_right" or "mat_core"
			send({{op = "set", ent = {id = id, ints = {[f] = default_material()}}}})
		end
	end
end

function M.mouse_down(button)
	if button == magic.MOUSEB_RIGHT then
		if S.tool == "wall" and S.draw then
			S.draw = nil
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
	if not v or v <= 0 or not S.draw then
		return
	end
	local x, z = snapped_point(S.draw)
	if not x then
		return
	end
	local dx, dz = x - S.draw.x, z - S.draw.z
	local l = geom.len(dx, dz)
	if l == 0 then
		return
	end
	add_wall(S.draw, math.floor(S.draw.x + dx / l * v + 0.5),
			math.floor(S.draw.z + dz / l * v + 0.5), {})
end

function M.key_down(key, event_data)
	if S.tool == "wall" and S.draw then
		local digit = key >= magic.KEY_0 and key <= magic.KEY_9
		if digit then
			S.typed = S.typed .. tostring(key - magic.KEY_0)
			return
		elseif key == magic.KEY_BACKSPACE then
			S.typed = S.typed:sub(1, -2)
			return
		elseif key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
			commit_typed()
			return
		end
	end
	if key == magic.KEY_ESCAPE then
		if S.draw then
			S.draw = nil
			S.typed = ""
		elseif S.selected then
			S.selected = nil
			refresh_panels()
		elseif S.tool ~= "select" then
			set_tool("select")
		end
	elseif key == magic.KEY_TAB then
		set_view(S.view == "2d" and "3d" or "2d")
	elseif key == magic.KEY_V then
		set_tool("select")
	elseif key == magic.KEY_B then
		set_tool("wall")
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
	if doc.typing() then
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
	local y = S.view == "2d" and W(settings().cut) - 0.001 or 0.002
	local function P(x, z, yy)
		return magic.Vector3(W(x), yy or y, W(z))
	end
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
		local gy = 0.001
		for gx = math.floor(x0 / step) * step, x1, step do
			debug:AddLine(P(gx, z0, gy), P(gx, z1, gy),
					gx % 1000 == 0 and major or fine, true)
		end
		for gz = math.floor(z0 / step) * step, z1, step do
			debug:AddLine(P(x0, gz, gy), P(x1, gz, gy),
					gz % 1000 == 0 and major or fine, true)
		end
	end
	-- The walls' lines where they are hung above the cut, dashed
	if S.view == "2d" then
		local cut = settings().cut
		for id, o in pairs(outlines) do
			local y0 = wall_span(doc.ents[id].ints)
			if y0 >= cut then
				local pts = o.pts
				for i = 1, #pts do
					local p, q = pts[i], pts[i % #pts + 1]
					local l = geom.len(q[1] - p[1], q[2] - p[2])
					local n = math.max(1, math.floor(l / (6 * mm_per_px())))
					for j = 0, n - 1, 2 do
						debug:AddLine(P(p[1] + (q[1] - p[1]) * j / n, p[2] +
								(q[2] - p[2]) * j / n), P(p[1] + (q[1] - p[1]) *
								(j + 1) / n, p[2] + (q[2] - p[2]) * (j + 1) / n),
								magic.Color(0.2, 0.2, 0.25), false)
					end
				end
			end
		end
	end
	local accent = magic.Color(1.0, 0.6, 0.1)
	local function outline(id, col)
		local o = outlines[id]
		if not o then
			return
		end
		local y0, y1 = wall_span(doc.ents[id].ints)
		local ys = S.view == "2d" and {y} or {W(y0) + 0.002, W(y1) + 0.002}
		for _, yy in ipairs(ys) do
			for i = 1, #o.pts do
				local p, q = o.pts[i], o.pts[i % #o.pts + 1]
				debug:AddLine(P(p[1], p[2], yy), P(q[1], q[2], yy), col, false)
			end
		end
	end
	if S.selected and S.selected.kind == "wall" then
		outline(S.selected.id, accent)
		local w = wall_data[S.selected.id]
		if w then
			world_label((w.ax + w.bx) / 2, 0, (w.az + w.bz) / 2,
					mm_text(geom.len(w.bx - w.ax, w.bz - w.az)))
		end
	end
	-- Nodes, for the select tool
	if S.tool == "select" then
		local size = S.view == "2d" and W(6 * mm_per_px()) or 0.08
		for _, n in ipairs(doc.of_type("node")) do
			local x, z = node_pos(n.id)
			local sel = S.selected and S.selected.id == n.id
			debug:AddCross(P(x, z), size, sel and accent or
					magic.Color(0.1, 0.3, 0.8), false)
		end
	end
	-- What the wall tool would do on a click
	if S.tool == "wall" and not over_ui() then
		local x, z, ref = snapped_point(S.draw)
		if x then
			local col = ref.node and magic.Color(0.1, 0.8, 0.2) or ref.wall and
					magic.Color(0.9, 0.3, 0.9) or accent
			local size = S.view == "2d" and W(8 * mm_per_px()) or 0.12
			debug:AddCross(P(x, z), size, col, false)
			if S.draw then
				debug:AddLine(P(S.draw.x, S.draw.z), P(x, z), accent, false)
				local l = geom.len(x - S.draw.x, z - S.draw.z)
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
		S.dirty = true
		if S.selected and not doc.ents[S.selected.id] then
			S.selected = nil
		end
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
