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
local keys = load("keys.lua")

local M = {}
-- init.lua's chat key, and its way past the T while a key is being bound
M.keys = keys
local doc
M.daylight = load("daylight.lua")

local GRID_STEPS = {1, 10, 50, 100, 200, 500, 1000}
local ANGLE_STEPS = {false, 1, 5, 15, 45, 90}
-- How near, in pixels, the cursor snaps to a node or an edge
local SNAP_PX = 12
local DRAG_PX = 4
-- Where a copy lands from what it was copied from
local COPY_OFFSET = 500
-- The view button goes round the views: the plan, the free camera, walking
local VIEW_NAMES = {["2d"] = "2D", ["3d"] = "3D", walk = "Walk"}
-- Walking: the body's radius, how high a step it takes, its height, mm.
-- A step takes a stair's riser, which building codes cap near 220 mm.
local BODY_R, STEP, HEAD = 250, 250, 1750
local JUSTIFY_CHOICES = {{"centered", 0}, {"left", 1}, {"right", 2}}
-- What a definition is, as main.cpp's DefKind
local KIND = {box = 0, voxel = 1, opening = 2, door = 3, window = 4,
	switch = 5, stairs = 6}
-- A door's or a window's parts, by the field each keeps its material in
local DOOR_PARTS = {mat = true, mat_leaf = true, mat_glass = true}
local KIND_NAMES = {[0] = "Box", [2] = "Opening", [3] = "Door",
	[4] = "Window", [5] = "Switch", [6] = "Stairs"}
-- I goes round what the door/window tool puts in
local NEXT_HOSTED = {[2] = 3, [3] = 4, [4] = 5, [5] = 2}
-- A new opening, door and window
local HOSTED = {
	[2] = {w = 900, h = 2100, sill = 0},
	[3] = {w = 900, h = 2100, sill = 0},
	[4] = {w = 1200, h = 1200, sill = 900},
	[5] = {w = 80, h = 80, sill = 1050},
}
-- A door leaf's thickness and the gap round it, and a window's frame
local LEAF_T, LEAF_GAP, FRAME_W = 40, 4, 50

local S = {
	-- How the 3D view and walking are lit ([FP_DAYLIGHT]): "pbr", the
	-- plan's sun and sky at its place and hour in radiance, or "unlit",
	-- the plain look the plan view always has, for clarity and speed; every
	-- client starts pbr. The viewer's own, kept on the client.
	lighting = buildat.storage_read("lighting") or "pbr",
	view = "2d",
	show_ids = false, -- the material id decals
	plan_look = true, -- the plan view in flat colours (L)
	tool = "select",
	voxel_mode = "place", -- the voxel tool's click in 3D
	angle = 4,      -- index into ANGLE_STEPS: the angle snap
	-- New walls
	thickness = 120, -- a new wall's, mm: a 90 mm stud and a board on each side (user)
	justify = 0,
	height = 0,
	hang = 0,
	room_walls = true, -- a room drawn gets walls on its edges
	-- and a plafond lamp at its middle (user: a room is dark without one)
	room_lamp = buildat.storage_read("room_lamp") ~= "0",
	-- New boxes
	box = {w = 600, h = 750, d = 600, align = 0, offset = 0},
	-- The object tool's other shape: stairs this wide, up this high (0: the
	-- plan's floor to floor) in risers of about this much, each this deep
	shape = "box",
	stairs = {w = 1000, h = 0, riser = 200, tread = 250},
	hosted = 3,     -- what the door/window tool puts in a wall
	voxel_size = 150, -- a new voxel volume's, mm (user, 2026-10-01: was 50)
	-- Doors and windows a viewer has opened, and lamps they have switched,
	-- which only they see
	local_open = {},
	local_on = {},
	linking = nil,  -- the switch whose lamps clicks add and remove
	material = nil, -- the palette entry picked
	-- The cursor, in window pixels
	mx = 0, my = 0,
	shift = false,
	-- The 2D camera: centre in mm, and how many mm tall the view is
	cx = 0, cz = 0, span = 12000,
	-- The 3D camera, in metres and degrees
	pos = {x = -4, y = 6, z = -6},
	-- Walking: where the feet are, mm, and the eyes above them
	walk = {x = 0, z = 0, feet = 0, noclip = false},
	-- The fingers down, by id ([FP_TOUCH] 3)
	fingers = {},
	eye = 1600,
	-- The pointer is a finger ([FP_TOUCH]): the page says so
	touch = buildat.get_env("BUILDAT_TOUCH") == "1",
	-- In a browser (only the web page sets it): the wheel comes in tenths
	-- of a notch there
	web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil,
	-- Walking's vertical field of view in degrees, the viewer's own and
	-- kept on this client (user)
	walk_fov = tonumber(buildat.storage_read("walk_fov") or "") or 80,
	-- How fast the mouse turns the view, in percent: walking's look and
	-- the 3D view's orbit (user)
	mouse_sens = tonumber(buildat.storage_read("mouse_sens") or "") or 100,
	-- How much a wheel notch zooms, in percent, and whether the 3D view
	-- zooms toward the cursor rather than along its own direction (user)
	wheel_speed = tonumber(buildat.storage_read("wheel_speed") or "") or 100,
	zoom_to_cursor = buildat.storage_read("zoom_to_cursor") == "1",
	-- The middle drag in 3D moving the camera along the ground (XZ) rather
	-- than across the screen (user), the default; kept on the client
	pan_xz = buildat.storage_read("pan_xz") ~= "0",
	-- How far the 3D view's middle drag moves the camera, in percent of
	-- the point under the pointer following it (user); the plan view's
	-- stays one to one. Kept on the client, so a desktop and a phone each
	-- have their own.
	pan_speed = tonumber(buildat.storage_read("pan_speed") or "") or 100,
	-- The 3D view without the floors above the current one, to see into it
	-- from above (user); kept on the client
	hide_above = buildat.storage_read("hide_above") == "1",
	calib = nil,    -- an image being calibrated: {id, pts, measured}
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
	-- The face each wall in it was selected by: "left", "right" or "core"
	sel_face = {},
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

-- The sun, when the plan has it: shadowed, since light that went through
-- the walls would light the rooms as if they had none
local sun_node = scene:CreateChild("Sun")
local sun = sun_node:CreateComponent("Light")
sun.lightType = magic.LIGHT_DIRECTIONAL
sun.brightness = 1.0
sun.castShadows = true
sun.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
sun.shadowCascade = magic.CascadeParameters(8.0, 25.0, 80.0, 0.0, 0.8)
-- A faint unshadowed light from one side, so that the faces of a wall read
-- apart without the sun; it lights nothing that ambient light would not
local fill_node = scene:CreateChild("Fill")
fill_node.direction = magic.Vector3(0.5, -0.6, -0.7)
local fill = fill_node:CreateComponent("Light")
fill.lightType = magic.LIGHT_DIRECTIONAL
fill.brightness = 0.25
-- The lamps' lights, rebuilt with everything else
local lamps_node = scene:CreateChild("Lamps")

-- From the resource cache, which holds them: a Material made in Lua is
-- freed under a geometry still using it
local lit_material = magic.cache:GetResource("Material", "main/palette.xml")
-- A ceiling is seen from above by the sun, from its back: it casts all the
-- same ([FP_DAYLIGHT])
lit_material.shadowCullMode = magic.CULL_NONE
-- The same, for the type previews: its own so the plan's flat look is not
-- theirs
local preview_material = magic.cache:GetResource("Material",
		"main/palette_preview.xml")
local flat_material = magic.cache:GetResource("Material", "main/flat_vcol.xml")
M.shadow_material = magic.cache:GetResource("Material", "main/shadow_only.xml")
local glass_material = magic.cache:GetResource("Material",
		"main/palette_glass.xml")
-- What a Lua wrapper would otherwise free under the engine
M.kept = {}

-- simplified: the two low bits only, which is all a flip holds
local function bit_xor(a, b)
	local r = 0
	for i = 0, 1 do
		local p = 2 ^ i
		if (math.floor(a / p) % 2) ~= (math.floor(b / p) % 2) then
			r = r + p
		end
	end
	return r
end

-- The world is in metres; the plan in millimetres
local function W(mm)
	return mm / 1000
end

local function rgb_color(rgb, f)
	f = f or 1
	return magic.Color(math.floor(rgb / 65536) % 256 / 255 * f,
			math.floor(rgb / 256) % 256 / 255 * f, rgb % 256 / 255 * f)
end

local WHITE = magic.Color(1, 1, 1)
-- A lamp's vertices when it is off: its colour, and no light of its own
local UNLIT = magic.Color(1, 1, 1, 0)

-- A triangle facing n: Urho3D's front faces are clockwise as seen, which in
-- its left-handed space is cross(b - a, c - a) pointing at the viewer
-- The lists tri() gathers into, by the part they are for: a lookup here
-- rather than a field of the part, which an engine geometry would refuse
local TRI_LISTS = {}
local function tri(g, a, b, c, n, col, tint)
	local ux, uy, uz = b.x - a.x, b.y - a.y, b.z - a.z
	local vx, vy, vz = c.x - a.x, c.y - a.y, c.z - a.z
	local cx = uy * vz - uz * vy
	local cy = uz * vx - ux * vz
	local cz = ux * vy - uy * vx
	if cx * n.x + cy * n.y + cz * n.z < 0 then
		b, c = c, b
	end
	-- A number is a palette row, for the palette's shader; a Color is a
	-- flat colour, for the plan view's own
	local row = 0
	if type(col) == "number" then
		row, col = col, tint or WHITE
	end
	-- A list being built (TRI_LISTS, handed to the engine at once by
	-- buildat.set_triangle_geometry): 12 numbers a vertex, no call into the
	-- engine a vertex
	local out = TRI_LISTS[g]
	if out then
		local nx, ny, nz = n.x, n.y, n.z
		local cr, cg, cb, ca = col.r, col.g, col.b, col.a
		-- What of the sky's light this face does not get, which the
		-- texture coordinate's y carries to the shader ([FP_DAYLIGHT]):
		-- the room the face looks into, a little in front of it, or one
		-- value for a part built in its own frame
		local occ = M.tri_occ or 0
		local fn = M.tri_occ_fn
		if fn then
			occ = fn((a.x + b.x + c.x) / 3 + nx * 0.05,
					(a.z + b.z + c.z) / 3 + nz * 0.05)
		end
		local k = #out
		for _, p in ipairs({a, b, c}) do
			out[k + 1], out[k + 2], out[k + 3] = p.x, p.y, p.z
			out[k + 4], out[k + 5], out[k + 6] = nx, ny, nz
			out[k + 7], out[k + 8], out[k + 9], out[k + 10] = cr, cg, cb, ca
			out[k + 11], out[k + 12] = row, occ
			k = k + 12
		end
		return
	end
	-- An engine geometry, a call a vertex (plain {x, y, z} tables made
	-- into the engine's vectors here)
	local uv = magic.Vector2(row, 0)
	local nv = magic.Vector3(n.x, n.y, n.z)
	for _, v in ipairs({a, b, c}) do
		g:DefineVertex(magic.Vector3(v.x, v.y, v.z))
		g:DefineNormal(nv)
		g:DefineColor(col)
		g:DefineTexCoord(uv)
	end
end

-- A point or a direction as tri() takes it: a plain table, which costs
-- nothing to make or read where an engine vector is a sandbox object
local function V3(x, y, z)
	return {x = x, y = y, z = z}
end

-- A flat polygon at height y (mm) facing n, as one geometry
local function flat_polygon(g, pts, y, n, col)
	for _, t in ipairs(geom.triangulate(pts)) do
		local a, b, c = pts[t[1]], pts[t[2]], pts[t[3]]
		tri(g, V3(W(a[1]), W(y), W(a[2])), V3(W(b[1]), W(y), W(b[2])),
				V3(W(c[1]), W(y), W(c[2])), n, col)
	end
end

-- A box of half sizes hx, hy, hz (metres) about the origin, or about
-- (cx, cy, cz)
local function box_geometry(g, hx, hy, hz, col, cx, cy, cz, tint)
	cx, cy, cz = cx or 0, cy or 0, cz or 0
	local function V(x, y, z)
		return V3(cx + x * hx, cy + y * hy, cz + z * hz)
	end
	for _, f in ipairs({{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0},
			{0, 0, 1}, {0, 0, -1}}) do
		local n = V3(f[1], f[2], f[3])
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
		tri(g, C(-1, -1), C(1, -1), C(1, 1), n, col, tint)
		tri(g, C(-1, -1), C(1, 1), C(-1, 1), n, col, tint)
	end
end

local UP, DOWN = magic.Vector3(0, 1, 0), magic.Vector3(0, -1, 0)
-- The same for tri()
M.UP3, M.DOWN3 = V3(0, 1, 0), V3(0, -1, 0)

local ground_node = scene:CreateChild("Ground")
-- The ground: the plain grey, or under PBR the season's colour in its own
-- palette row ([FP_DAYLIGHT]); again when either changes
function M.build_ground()
	if not M.ground_row then
		return
	end
	local pbr = M.pbr_now()
	local key = tostring(pbr) .. ":" .. tostring(M.ground_row)
	if key == M.ground_key then
		return
	end
	M.ground_key = key
	local g = ground_node:GetComponent("CustomGeometry") or
			ground_node:CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	-- Under PBR a disc of 200 m round the camera, whose edge is where the
	-- sky's treeline stands (LuantiSky.glsl, TREE_DISTANCE): the node
	-- follows the camera (M.apply_daylight), and the lawn's pattern is the
	-- world's, so it stays put
	local r = 200000
	local pts = {{-r, -r}, {r, -r}, {r, r}, {-r, r}}
	if pbr then
		pts = {}
		for i = 1, 96 do
			local a = i / 96 * 2 * math.pi
			pts[i] = {r * math.cos(a), r * math.sin(a)}
		end
	end
	flat_polygon(g, pts, 0, M.UP3,
			pbr and M.ground_row or magic.Color(0.85, 0.85, 0.83))
	g:Commit()
	g:SetMaterial(0, lit_material)
end

local walls_node = scene:CreateChild("Walls")
local caps_node = scene:CreateChild("Caps")
-- The ceilings and what is aligned to them, hidden from above
local overhead_node = scene:CreateChild("Overhead")
-- Doors' and windows' own parts: the plan view draws symbols instead
local pieces_node = scene:CreateChild("Pieces")
-- The pictures traced over
local images_node = scene:CreateChild("Images")
-- Each surface's material id, on the surface
local decals_node = scene:CreateChild("Decals")
-- Each layout's own node under each of the parts, placing it ([FP_LAYOUTS]):
-- place.parts: layout id -> {walls = node, ...}, and P the one rebuild()
-- builds
local P = nil
-- simplified: a material per picture file, and one made in Lua is freed
-- under the geometry using it, so there are eight of them in files and
-- eight pictures at most; the upgrade is the engine keeping what Lua made
local IMAGE_MATERIALS = 8

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
-- Vertical, in degrees; walking has S.walk_fov (set_view)
cam3d.fov = 60

-- A viewport for a view, made new each time: the engine frees one when the
-- viewports it is shown in are replaced, so one kept in Lua to show again
-- would be a dangling pointer. So would a render path.
local function viewport_for(v)
	if v == "2d" then
		return magic.Viewport:new(scene, cam2d)
	end
	local vp = magic.Viewport:new(scene, cam3d)
	-- Deferred, so that a house full of lamps costs a light each rather
	-- than a light for each thing each lights; the plan view stays forward
	local rp = vp.renderPath:Clone()
	-- PBR: in radiance, metered and tone mapped ([FP_DAYLIGHT]), and the
	-- ambient occluded in corners ([FP_AO])
	local pbr = S.lighting ~= "unlit"
	rp:Load(magic.cache:GetResource("XMLFile", pbr and
			"main/deferred_ssao.xml" or "RenderPaths/Deferred.xml"))
	if pbr then
		M.daylight.pbr_render_path(rp)
	end
	vp.renderPath = rp
	return vp
end

--
-- The document, as the editor reads it
--
local function settings()
	return doc.settings().ints
end

-- SNAP_PX and DRAG_PX for a finger ([FP_TOUCH] 4): a pixel is a device's, a fraction of
-- a CSS pixel on a phone, and a finger is broader than a pointer
function M.px(n)
	return S.touch and n * 2 * magic.ui.scale or n
end

-- Layouts ([FP_LAYOUTS]). The current one, S.layout, is edited, and its
-- own coordinates are the scene's: picking, snapping and the tools see only
-- its entities. Every other is drawn where it is relative to it.
-- S.view_layout is the layout whose entities of_type() gives: the current
-- one, but another while rebuild() builds that one
local of_type
do
	local function layout_of(e)
		if e.type == "wall" then
			local n = doc.ents[e.ints.a]
			return n and n.ints.layout
		elseif e.type == "room" then
			local n = doc.ents[e.lists.nodes[1]]
			return n and n.ints.layout
		end
		return e.ints.layout
	end

	local LAYERED = {node = true, wall = true, room = true, instance = true,
		image = true}
	of_type = function(t)
		local all = doc.of_type(t)
		if not LAYERED[t] then
			return all
		end
		local out = {}
		for _, e in ipairs(all) do
			if layout_of(e) == S.view_layout then
				out[#out + 1] = e
			end
		end
		return out
	end
end

local place = {parts = {}}
-- The current layout's fields, making the first one current when the
-- current one is gone
function place.current()
	local e = S.layout and doc.ents[S.layout]
	if not e or e.type ~= "layout" then
		e = doc.of_type("layout")[1]
		S.layout = e and e.id
	end
	doc.layout = S.layout
	S.view_layout = S.layout
	return e and e.ints or {x = 0, y = 0, z = 0, yaw = 0}
end

-- The world's own placement
place.WORLD = {x = 0, y = 0, z = 0, yaw = 0}
-- Where the frame of a placement l ({x, y, z, yaw}: layout fields, mm and
-- millidegrees) is in the frame of c: {x, y, z} mm and a yaw in degrees
function place.rel(l, c)
	local x, y, z = geom.unrot(l.x - c.x, l.y - c.y, l.z - c.z, 0, c.yaw / 1000,
			0)
	return {x = x, y = y, z = z, yaw = (l.yaw - c.yaw) / 1000}
end
-- A point of the frame r places, in the frame it is placed in, and back
function place.point(r, x, y, z)
	local px, py, pz = geom.rot(x, y, z, 0, r.yaw, 0)
	return px + r.x, py + r.y, pz + r.z
end
function place.unpoint(r, x, y, z)
	return geom.unrot(x - r.x, y - r.y, z - r.z, 0, r.yaw, 0)
end
-- Presence goes in the world's coordinates, and comes to where it is in
-- the current layout's: back = true for that way
function place.presence(p, back)
	local r = place.rel(place.current(), place.WORLD)
	local f = back and place.unpoint or place.point
	local q = {}
	for k, v in pairs(p) do
		q[k] = v
	end
	local _
	q.cx, _, q.cz = f(r, p.cx, 0, p.cz)
	if p.view >= 1 then
		q.px, q.py, q.pz = f(r, p.px, p.py, p.pz)
	else
		-- The plan view's py is its span
		q.px, _, q.pz = f(r, p.px, 0, p.pz)
	end
	q.yaw = p.yaw + (back and -1 or 1) * r.yaw * 1000
	for _, k in ipairs({"cx", "cz", "px", "py", "pz", "yaw"}) do
		q[k] = math.floor(q[k] + 0.5)
	end
	return q
end
-- Another layout current, the cameras staying where they are in the world
function place.switch(id)
	local e = doc.ents[id]
	if not e or e.type ~= "layout" or id == S.layout then
		return
	end
	local r = place.rel(place.current(), e.ints)
	S.layout = id
	place.current()
	local _
	S.cx, _, S.cz = place.point(r, S.cx, 0, S.cz)
	local x, y, z = place.point(r, S.pos.x * 1000, S.pos.y * 1000, S.pos.z * 1000)
	S.pos = {x = x / 1000, y = y / 1000, z = z / 1000}
	S.yaw = S.yaw + r.yaw
	local w = S.walk
	w.x, w.feet, w.z = place.point(r, w.x, w.feet, w.z)
	S.sel, S.primary, S.nodes, S.sel_face = {}, nil, {}, {}
	S.draw, S.corners, S.drag, S.press = nil
	S.dirty = true
end

-- The grid, the plan's own so it is saved and restored with it. Here, above
-- everything that snaps: a drag of a door along its wall called it from
-- above where it was defined, and got nil
local function grid_step()
	return settings().grid
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
	-- Where somebody else's drag has it
	local pv = doc.previewed(id)
	if pv and pv.x then
		return pv.x, pv.z
	end
	local n = doc.ents[id]
	if not n then
		return 0, 0
	end
	return n.ints.x, n.ints.z
end

-- A lamp's light colour at a temperature in kelvin
local function kelvin_rgb(k)
	local t = k / 100
	local r, g, b
	if t <= 66 then
		r, g = 255, 99.4708025861 * math.log(t) - 161.1195681661
	else
		r = 329.698727446 * (t - 60) ^ -0.1332047592
		g = 288.1221695283 * (t - 60) ^ -0.0755148492
	end
	if t >= 66 then
		b = 255
	elseif t <= 19 then
		b = 0
	else
		b = 138.5177312231 * math.log(t - 10) - 305.0447927307
	end
	local function c(v)
		return math.floor(math.max(0, math.min(255, v)) + 0.5)
	end
	return c(r) * 65536 + c(g) * 256 + c(b)
end

local function split_rgb(v)
	return math.floor(v / 65536) % 256 / 255, math.floor(v / 256) % 256 / 255,
			v % 256 / 255
end

-- A palette entry's colour as the plan view and the swatches show it: its
-- own colour with its finish applied, without the pattern
local function palette_rgb(id)
	local e = id and id ~= 0 and doc.ents[id]
	if not e or e.type ~= "palette" then
		return 0xb0b0b0
	end
	local p = e.ints
	if p.kind == 4 then
		return kelvin_rgb(p.temperature)
	end
	local br, bg, bb = split_rgb(p.base)
	local pr, pg, pb = split_rgb(p.color)
	local o = p.opacity / 1000
	local r, g, b
	if p.finish == 0 then
		r, g, b = br * pr, bg * pg, bb * pb
	elseif p.finish == 1 then
		r, g, b = pr, pg, pb
	else
		r, g, b = br + (pr - br) * o, bg + (pg - bg) * o, bb + (pb - bb) * o
	end
	return math.floor(r * 255 + 0.5) * 65536 + math.floor(g * 255 + 0.5) * 256 +
			math.floor(b * 255 + 0.5)
end

-- Whether a lamp instance is lit: a viewer's own switching wins
local function lamp_on(id)
	if S.local_on[id] ~= nil then
		return S.local_on[id]
	end
	return doc.ents[id].ints.on == 1
end

local function is_lamp_entry(id)
	local e = id and id ~= 0 and doc.ents[id]
	return e and e.type == "palette" and e.ints.kind == 4
end

-- Whether an instance gives light: a volume with lamp voxels, or a box of
-- a lamp material
local function is_lamp(id)
	local e = doc.ents[id]
	if not e or e.type ~= "instance" then
		return false
	end
	local def = doc.ents[e.ints.def].ints
	if def.kind == KIND.voxel then
		for _, m in pairs(doc.voxels[e.ints.def] or {}) do
			if is_lamp_entry(m) then
				return true
			end
		end
		return false
	end
	return def.kind == KIND.box and is_lamp_entry(def.mat)
end

-- The palette's rows: 0 is what has no material, 1 the glass a window has
-- when it was given none, and the entries follow in id order
local MATERIAL_KINDS = {[0] = "Drywall", "Wood", "Stone", "Wallpaper", "Lamp",
	"Glass", "Metal", "Tile", "Fabric", "Plaster", "Paneling"}
-- What a type looks like when an entry is switched to it
local KIND_DEFAULTS = {
	[0] = {base = 0xe8e4dc, color2 = 0x404040, scale = 200, roughness = 800,
			specular = 100},
	{base = 0xb07a48, color2 = 0x404040, scale = 300, roughness = 600,
			specular = 250},
	{base = 0x9a968e, color2 = 0x5a5650, scale = 400, roughness = 500,
			specular = 300},
	{base = 0xeadfc8, color2 = 0x8a6a4a, scale = 150, roughness = 900,
			specular = 50},
	{base = 0xffffff, color2 = 0x404040, scale = 200, roughness = 500,
			specular = 0},
	{base = 0xa8c8e0, color2 = 0x404040, scale = 200, roughness = 50,
			specular = 800},
	{base = 0xb8bcc0, color2 = 0x404040, scale = 200, roughness = 300,
			specular = 700},
	{base = 0xf0f0ec, color2 = 0x9a9890, scale = 200, roughness = 200,
			specular = 500},
	{base = 0x6a7a8a, color2 = 0x404040, scale = 3, roughness = 1000,
			specular = 20},
	{base = 0xe4ddd0, color2 = 0x404040, scale = 200, roughness = 900,
			specular = 60},
	-- Paneling: scale is a board's width
	{base = 0xd8b07a, color2 = 0x404040, scale = 120, roughness = 600,
			specular = 250},
}
-- A type as its preview shows it: its defaults over every other field's
local function kind_preview(k)
	local p = {color = 0xffffff, finish = 0, opacity = 500, reflect = 0,
		seed = 0, axis = 0, stagger = 0, grout = 3, temperature = 2700,
		brightness = 1000, speckle = 300, angle = 0, contrast = 1000, polish = 500,
		gap_depth = 15, gap_width = 60, handmade = 0, kind = k}
	for f, v in pairs(KIND_DEFAULTS[k]) do
		p[f] = v
	end
	return p
end

local palette_rows = {}
local palette_key = nil
-- Grows with every new palette texture, whose rows the meshes point at
local palette_gen = 0

local function row(id)
	return palette_rows[id] or 0
end

-- The palette as the shader reads it: eight texels a row. The small
-- integers are spread out (type * 20, finish * 32, flags * 16) and read back
-- rounded: what the shader reads can be a level off what was written.
--   0: own colour, type          1: paint, finish
--   2: second colour, opacity    3: roughness, specular, reflect, seed low
--   4: log2 of the scale in mm / 16, flags (grain axis + 4 * stagger),
--      seed high, the type's own knob (lamp brightness, grout, speckle)
--   5: paneling's angle, grain contrast, paneling's polish and hand made
--      look
--   6: paneling's gap width and depth in tenths of a mm, high and low bytes
-- Rebuilt only when an entry changes, since each texture is kept.
local function palette_texture()
	local entries = of_type("palette")
	local parts = {}
	for _, e in ipairs(entries) do
		for k, v in pairs(e.ints) do
			parts[#parts + 1] = e.id .. k .. v
		end
	end
	table.sort(parts)
	-- and the ground's colour of the season, its row the last
	local ground, ground_mode = M.ground_rgb()
	local key = table.concat(parts, ",") .. ";" .. ground
	if key == palette_key then
		return
	end
	palette_key = key
	palette_rows = {}
	-- The two rows of nothing, a preview's for each type, the entries, then
	-- the ground's ([FP_DAYLIGHT])
	local n = #entries + 2 + #MATERIAL_KINDS + 1 + 1
	M.ground_row = n - 1
	local image = magic.Image:new()
	assert(image:SetSize(8, n, 4), "Image:SetSize")
	local function put(x, y, rgb, a)
		local r, g, b = split_rgb(rgb)
		image:SetPixel(x, y, magic.Color(r, g, b, a))
	end
	local function px(x, y, r, g, b, a)
		image:SetPixel(x, y, magic.Color(r, g, b, a))
	end
	-- The two rows of nothing: a flat grey, and a pale glass
	put(0, 0, 0xb0b0b0, 0)
	put(1, 0, 0xffffff, 0)
	put(2, 0, 0x404040, 1)
	px(3, 0, 0.9, 0.05, 0, 0)
	px(4, 0, 0.5, 0, 0, 0)
	put(0, 1, 0xa8c8e0, 5 * 20 / 255)
	put(1, 1, 0xffffff, 0)
	put(2, 1, 0x404040, 0.3)
	px(3, 1, 0.1, 0.8, 0.5, 0)
	px(4, 1, 0.5, 0, 0, 0)
	local function put_row(y, p)
		local base = p.kind == 4 and kelvin_rgb(p.temperature) or p.base
		put(0, y, base, p.kind * 20 / 255)
		put(1, y, p.color, p.finish * 32 / 255)
		put(2, y, p.color2, p.opacity / 1000)
		px(3, y, p.roughness / 1000, p.specular / 1000, p.reflect / 1000,
				(p.seed % 256) / 255)
		local knob = 0
		if p.kind == 4 then
			-- 0 to 1000 %, as its square root for the steps
			knob = math.sqrt(p.brightness / 10000)
		elseif p.kind == 7 then
			knob = math.min(1, p.grout / p.scale * 4)
		elseif p.kind == 9 then
			knob = p.speckle / 1000
		end
		px(4, y, math.log(p.scale) / math.log(2) / 16,
				(p.axis + 4 * p.stagger) * 16 / 255, math.floor(p.seed / 256) / 255,
				knob)
		-- Wood's grain contrast, paneling's angle, polish and hand made look
		px(5, y, p.angle / 180, p.contrast / 3000, p.polish / 1000,
				p.handmade / 1000)
		-- Paneling's gap width and depth, 16 bits each
		px(6, y, math.floor(p.gap_width / 256) / 255, (p.gap_width % 256) / 255,
				math.floor(p.gap_depth / 256) / 255, (p.gap_depth % 256) / 255)
	end
	for k = 0, #MATERIAL_KINDS do
		put_row(2 + k, kind_preview(k))
	end
	for i, e in ipairs(entries) do
		palette_rows[e.id] = i + 2 + #MATERIAL_KINDS
		put_row(i + 2 + #MATERIAL_KINDS, e.ints)
	end
	-- The ground: the shader's own type 11, grass or snow in its own
	-- colour; the knob is green 0, dry 0.5, snow 1
	put(0, M.ground_row, ground, 11 * 20 / 255)
	put(1, M.ground_row, 0xffffff, 0)
	put(2, M.ground_row, 0x404040, 1)
	px(3, M.ground_row, 1, 0, 0, 0)
	px(4, M.ground_row, 0.5, 0, 0, ((ground_mode or 1) - 1) / 2)
	local texture = magic.Texture2D:new()
	-- One level: a smaller one would average the rows' knobs together
	texture:SetNumLevels(1)
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = magic.FILTER_NEAREST
	M.kept[#M.kept + 1] = texture
	M.kept[#M.kept + 1] = image
	-- The one that is on the materials, for a new GL context to be given
	-- again (the ScreenMode handler below)
	M.palette_upload = {texture = texture, image = image}
	for _, m in ipairs({lit_material, glass_material, preview_material}) do
		m:SetTexture(magic.TU_DIFFUSE, texture)
		m:SetShaderParameter("PaletteRows", n)
	end
	palette_gen = palette_gen + 1
end

-- The types' previews ([FP_TYPES]): a quad of each, a metre square, side
-- by side in a scene of their own, drawn once into a texture PREVIEW_PX
-- high and PREVIEW_PX a type wide. The quads point at the preview rows of
-- the palette texture, so they are the shader's own look and follow it.
local PREVIEW_PX = 64
local function kind_previews()
	if M.previews then
		return M.previews.texture
	end
	local scene = magic.Scene.new()
	scene:CreateComponent("Octree")
	local zone = scene:CreateChild("zone"):CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-100, 100)
	zone.ambientColor = magic.Color(0.45, 0.45, 0.47)
	local light_node = scene:CreateChild("light")
	light_node.direction = magic.Vector3(0.3, -0.5, 1)
	local light = light_node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.color = magic.Color(0.8, 0.78, 0.74)
	local count = #MATERIAL_KINDS + 1
	local g = scene:CreateChild("quads"):CreateComponent("CustomGeometry")
	g:SetNumGeometries(1)
	g:BeginGeometry(0, magic.TRIANGLE_LIST)
	local n = magic.Vector3(0, 0, -1)
	for k = 0, count - 1 do
		local x0, x1 = k * 1.0, k * 1.0 + 1.0
		local function V(x, y) return magic.Vector3(x, y, 0) end
		tri(g, V(x0, 0), V(x1, 0), V(x1, 1), n, 2 + k)
		tri(g, V(x0, 0), V(x1, 1), V(x0, 1), n, 2 + k)
	end
	g:Commit()
	g:SetMaterial(0, preview_material)
	local cam_node = scene:CreateChild("camera")
	local camera = cam_node:CreateComponent("Camera")
	camera.orthographic = true
	camera.orthoSize = 1.0
	cam_node.position = magic.Vector3(count / 2, 0.5, -5)
	local texture = magic.render_scene_to_texture(scene, cam_node,
			PREVIEW_PX * count, PREVIEW_PX)
	-- Kept: the scene goes when nothing holds it
	M.previews = {scene = scene, texture = texture}
	return texture
end

-- **A new GL context** (user: F11 on native lost every material): what is
-- written from Lua and not loaded from a file is not brought back by Urho,
-- so the palette's pixels go back on and the types' previews are drawn
-- again when next asked for. extensions/launch_world's handler is the model.
magic.SubscribeToEvent("ScreenMode", function()
	local pu = M.palette_upload
	if pu then
		pu.texture:SetData(pu.image)
	end
	M.previews = nil
	log:info("screen mode changed: the palette texture goes back on")
end)

-- The walls with their ends looked up, their outlines, the rooms with
-- their corners counter-clockwise, and the instances placed; rebuild()
-- fills them
local outlines = {}
local wall_data = {}
local room_data = {}
local inst_data = {}
-- The scene nodes rebuild() made, for the next one to remove
local built = {}
-- What a walker bumps into: {pts, y0, y1}, footprints and their heights
local solids = {}
-- The pictures, as rebuild() placed them: id -> {foot}
local image_data = {}
-- The material each picture file has: file -> one of IMAGE_MATERIALS
local image_materials = {}
local images_used = 0

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
	for _, e in ipairs(of_type("room")) do
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

local function copy_fields(p)
	local f = {}
	for k, v in pairs(p) do
		f[k] = v
	end
	return f
end

-- A wall's frame: its a end, its direction u and left normal n, how far
-- its faces are from its line, its length and the yaw that turns +X to u
local function wall_frame(id)
	local w = wall_data[id]
	if not w then
		return nil
	end
	local l = geom.len(w.bx - w.ax, w.bz - w.az)
	if l == 0 then
		return nil
	end
	local ux, uz = (w.bx - w.ax) / l, (w.bz - w.az) / l
	local lo, ro = geom.offsets(w.thickness, w.justify)
	return {ax = w.ax, az = w.az, ux = ux, uz = uz, nx = -uz, nz = ux,
			lo = lo, ro = ro, len = l, yaw = math.deg(math.atan2(-uz, ux))}
end

-- An instance placed: its centre, rotation and extents in mm. The 90
-- degree pitch and roll swap the definition's axes; the yaw turns the
-- footprint, which is ex by ez in the yawed frame.
-- A volume's voxels' extent in cells: {x0, y0, z0, x1, y1, z1}, or nil
-- when it has none
local function voxel_bounds(def)
	local b = nil
	for key in pairs(doc.voxels[def] or {}) do
		local x, y, z = doc.voxel_cell(key)
		if not b then
			b = {x, y, z, x, y, z}
		else
			b[1], b[2], b[3] = math.min(b[1], x), math.min(b[2], y), math.min(b[3], z)
			b[4], b[5], b[6] = math.max(b[4], x), math.max(b[5], y), math.max(b[6], z)
		end
	end
	return b
end

local function build_inst_data()
	inst_data = {}
	local d = S.drag
	for _, e in ipairs(of_type("instance")) do
		local i = e.ints
		-- Where somebody else's drag has it
		local pv = doc.previewed(e.id)
		if pv then
			i = copy_fields(i)
			for k, v in pairs(pv) do
				i[k] = v
			end
		end
		local def = doc.ents[i.def]
		local moved = d and d.moved and d.kind == "move" and d.inst[e.id]
		local it
		if def and i.host ~= 0 then
			-- In a wall: across its whole thickness and trim, at its sill;
			-- dragged onto another, in that one (the drag's rehost)
			local rh = moved and d.rehost
			local f = wall_frame(rh and rh.wall or i.host)
			local p = def.ints
			if f then
				local along = i.along
				if rh then
					along = rh.along
				elseif moved then
					along = geom.snap(along + d.dx * f.ux + d.dz * f.uz,
							grid_step())
				end
				local mid = (f.lo - f.ro) / 2
				local trim = p.kind == KIND.opening and 0 or p.trim
				local td = p.kind == KIND.opening and 0 or p.trim_depth
				local thick = f.lo + f.ro + 2 * td
				if p.kind == KIND.switch then
					-- On one face, standing out of it
					mid = i.flip % 2 == 0 and f.lo + 5 or -f.ro - 5
					trim, thick = 0, 10
				end
				it = {x = f.ax + f.ux * along + f.nx * mid,
						z = f.az + f.uz * along + f.nz * mid,
						y = i.sill + p.h / 2, yaw = f.yaw, pitch = 0, roll = 0,
						ex = p.w + 2 * trim, ey = p.h, ez = thick,
						hosted = true, along = along, frame = f}
			end
		elseif def and def.ints.kind == KIND.voxel then
			-- About its origin cell's corner, which is where it is placed:
			-- its extent is what its voxels make it
			local p = def.ints
			local sz = p.voxel_size
			local b = voxel_bounds(i.def) or {0, 0, 0, 0, 0, 0}
			local lx0, ly0, lz0 = b[1] * sz, b[2] * sz, b[3] * sz
			local lx1, ly1, lz1 = (b[4] + 1) * sz, (b[5] + 1) * sz, (b[6] + 1) * sz
			local pitch, roll, yaw = i.pitch * 90, i.roll * 90, i.yaw / 1000
			local ox, oz = i.x, i.z
			if moved then
				ox, oz = ox + d.dx, oz + d.dz
			end
			local oy = i.align == 1 and settings().ceiling - i.offset or i.offset
			local cx, cy, cz = geom.rot((lx0 + lx1) / 2, (ly0 + ly1) / 2,
					(lz0 + lz1) / 2, pitch, yaw, roll)
			local ex, ey, ez = geom.rot(lx1 - lx0, ly1 - ly0, lz1 - lz0, pitch, 0,
					roll)
			it = {x = ox + cx, y = oy + cy, z = oz + cz, yaw = yaw, pitch = pitch,
					roll = roll, ex = math.abs(ex), ey = math.abs(ey),
					ez = math.abs(ez), hx = (lx1 - lx0) / 2, hy = (ly1 - ly0) / 2,
					hz = (lz1 - lz0) / 2, voxel = true, ox = ox, oy = oy, oz = oz,
					size = sz}
		elseif def then
			local p = def.ints
			local pitch, roll = i.pitch * 90, i.roll * 90
			local ex, ey, ez = geom.rot(p.w, p.h, p.d, pitch, 0, roll)
			ex, ey, ez = math.abs(ex), math.abs(ey), math.abs(ez)
			local x, z = i.x, i.z
			if moved then
				x, z = x + d.dx, z + d.dz
			end
			local y
			if i.align == 1 then
				y = settings().ceiling - i.offset - ey / 2
			else
				y = i.offset + ey / 2
			end
			it = {x = x, y = y, z = z, yaw = i.yaw / 1000, pitch = pitch,
					roll = roll, ex = ex, ey = ey, ez = ez,
					-- The box's own half sizes, before its rotation
					hx = p.w / 2, hy = p.h / 2, hz = p.d / 2}
		end
		if it then
			it.hx = it.hx or it.ex / 2
			it.hy = it.hy or it.ey / 2
			it.hz = it.hz or it.ez / 2
			it.y0, it.y1, it.def = it.y - it.ey / 2, it.y + it.ey / 2, i.def
			local foot = {}
			for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
				local fx, _, fz = geom.rot(c[1] * it.ex / 2, 0, c[2] * it.ez / 2,
						0, it.yaw, 0)
				foot[k] = {it.x + fx, it.z + fz}
			end
			if not geom.is_ccw(foot) then
				foot = {foot[4], foot[3], foot[2], foot[1]}
			end
			it.foot = foot
			inst_data[e.id] = it
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

-- The voxel volumes' meshes, kept between rebuilds: an instance's is made
-- again only when its voxels, its size or the palette's rows change, and
-- otherwise only moved. instance id -> {node, key}
local voxel_meshes = {}

local FACES = {
	{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
}

-- A volume's cells as the node's geometry: a face wherever a neighbour is
-- empty, built in the engine from one list of cells and palette rows
-- (buildat.set_cell_geometry; a face at a time from here was a freeze on
-- the web, user 2026-09-30)
-- simplified: a quad per exposed face; the upgrade is a greedy mesher,
-- which the same call can do inside
local function voxel_geometry(node, def, sz, tint, occ)
	local cells = {}
	for key, mat in pairs(doc.voxels[def] or {}) do
		cells[#cells + 1] = key
		cells[#cells + 1] = row(mat)
	end
	local c = tint or WHITE
	buildat.set_cell_geometry(node, cells, W(sz), c.r, c.g, c.b, c.a, occ or 0)
end

local function update_voxel_meshes(seen)
	for id, it in pairs(inst_data) do
		if it.voxel then
			seen[id] = true
			local e = doc.ents[id].ints
			local def = e.def
			local on = lamp_on(id)
			-- and the room it stands in, for the sky's share ([FP_DAYLIGHT])
			local occ = M.inst_occlusion(it)
			local key = (doc.voxel_version[def] or 0) .. ":" .. palette_gen ..
					":" .. it.size .. ":" .. def .. ":" .. e.align .. ":" ..
					tostring(on) .. ":" .. occ
			local m = voxel_meshes[id]
			if not m or m.key ~= key then
				if m then
					m.node:Remove()
				end
				local parent = e.align == 1 and P.overhead or P.walls
				local node = parent:CreateChild("voxels")
				voxel_geometry(node, def, it.size, not on and UNLIT or nil, occ)
				local g = node:GetComponent("CustomGeometry")
				g:SetMaterial(0, lit_material)
				g.castShadows = true
				m = {node = node, key = key}
				voxel_meshes[id] = m
			end
			m.node.position = magic.Vector3(W(it.ox), W(it.oy), W(it.oz))
			m.node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
		end
	end
end

-- How open a door or window is, in thousandths of a right angle (to 1889,
-- 170 degrees): a viewer's own opening wins over the plan's
local function open_amount(id)
	return S.local_open[id] or doc.ents[id].ints.open
end

-- A door's or window's parts, in the frame of the wall at its centre: X
-- along the wall, Y up from the floor, Z to the wall's left
local function build_hosted(id, it, def, e, geometry, commit)
	if def.kind == KIND.opening then
		return
	end
	if def.kind == KIND.switch then
		local g, node = geometry(P.pieces)
		node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
		node.rotation = magic.Quaternion(0, it.yaw, 0)
		box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(5), row(def.mat))
		commit(g, lit_material)
		return
	end
	local f = it.frame
	local ox, oz = f.ax + f.ux * it.along, f.az + f.uz * it.along
	local function part()
		local g, node = geometry(P.pieces)
		node.position = magic.Vector3(W(ox), 0, W(oz))
		node.rotation = magic.Quaternion(0, f.yaw, 0)
		return g, node
	end
	local function B(g, x0, y0, z0, x1, y1, z1, col)
		box_geometry(g, W(x1 - x0) / 2, W(y1 - y0) / 2, W(z1 - z0) / 2, col,
				W(x0 + x1) / 2, W(y0 + y1) / 2, W(z0 + z1) / 2)
	end
	local frame_col = row(def.mat)
	local leaf_col = row(def.mat_leaf ~= 0 and def.mat_leaf or def.mat)
	-- simplified: only a window's glass is drawn see-through; a glass
	-- entry on a wall or a box is drawn opaque in its tint
	local glass_col = def.mat_glass ~= 0 and row(def.mat_glass) or 1
	local hw, t, td = def.w / 2, def.trim, def.trim_depth
	local y0, y1 = e.sill, e.sill + def.h
	local window = def.kind == KIND.window

	-- The trim on both faces
	local g = part()
	if t > 0 and td > 0 then
		for _, face in ipairs({{f.lo, f.lo + td}, {-f.ro - td, -f.ro}}) do
			local z0, z1 = face[1], face[2]
			local b = window and y0 - t or y0
			B(g, -hw - t, b, z0, -hw, y1 + t, z1, frame_col)
			B(g, hw, b, z0, hw + t, y1 + t, z1, frame_col)
			B(g, -hw, y1, z0, hw, y1 + t, z1, frame_col)
			if window then
				B(g, -hw, y0 - t, z0, hw, y0, z1, frame_col)
			end
		end
	end
	-- A window's frame in the opening
	if window then
		local fw = FRAME_W
		B(g, -hw, y0, -30, -hw + fw, y1, 30, frame_col)
		B(g, hw - fw, y0, -30, hw, y1, 30, frame_col)
		B(g, -hw + fw, y0, -30, hw - fw, y0 + fw, 30, frame_col)
		B(g, -hw + fw, y1 - fw, -30, hw - fw, y1, 30, frame_col)
	end
	commit(g, lit_material)

	-- The leaves, each on its own node at its hinge, turned by how open it
	-- is: towards +Z, or -Z when the swing is flipped
	local angle = open_amount(id) / 1000 * 90
	local right = e.flip % 2 == 1
	local sign = math.floor(e.flip / 2) % 2 == 1 and -1 or 1
	local leaves = {}
	if window and def.leaf == 2 then
		-- Double casement (user): two sashes meeting in the middle
		local inner = hw - FRAME_W
		leaves[1] = {x = -inner, w = inner, dir = 1}
		leaves[2] = {x = inner, w = inner, dir = -1}
	elseif window then
		local inner = hw - FRAME_W
		leaves[1] = {x = right and inner or -inner, w = 2 * inner,
				dir = right and -1 or 1}
	elseif def.leaf == 1 then
		leaves[1] = {x = -hw + LEAF_GAP, w = hw - 1.5 * LEAF_GAP, dir = 1}
		leaves[2] = {x = hw - LEAF_GAP, w = hw - 1.5 * LEAF_GAP, dir = -1}
	else
		leaves[1] = {x = right and hw - LEAF_GAP or -hw + LEAF_GAP,
				w = 2 * hw - 2 * LEAF_GAP, dir = right and -1 or 1}
	end
	-- A fixed window does not open
	if window and def.leaf == 0 then
		angle = 0
	end
	-- **Where each leaf is, for a click on it** (user): its box in its own
	-- frame, and the hinge and the turn that frame is at, in the layout's
	-- metres as the picking ray is (ray_instance)
	it.leaves = {}
	for _, lf in ipairs(leaves) do
		local lg, node = part()
		local yaw = f.yaw - lf.dir * sign * angle
		local hx, _, hz = geom.rot(lf.x, 0, 0, 0, f.yaw, 0)
		node.position = magic.Vector3(W(ox + hx), 0, W(oz + hz))
		node.rotation = magic.Quaternion(0, yaw, 0)
		local x0, x1 = 0, lf.dir * lf.w
		if x1 < x0 then
			x0, x1 = x1, x0
		end
		local t = window and 20 or LEAF_T / 2
		it.leaves[#it.leaves + 1] = {x = W(ox + hx), z = W(oz + hz), yaw = yaw,
				lo = {W(x0), W(y0), W(-t)}, hi = {W(x1), W(y1), W(t)}}
		if window then
			local fw = FRAME_W
			B(lg, x0, y0 + fw, -20, x0 + fw, y1 - fw, 20, frame_col)
			B(lg, x1 - fw, y0 + fw, -20, x1, y1 - fw, 20, frame_col)
			B(lg, x0 + fw, y0 + fw, -20, x1 - fw, y0 + 2 * fw, 20, frame_col)
			B(lg, x0 + fw, y1 - 2 * fw, -20, x1 - fw, y1 - fw, 20, frame_col)
			commit(lg, lit_material)
			local gg, gnode = part()
			gnode.position = node.position
			gnode.rotation = node.rotation
			B(gg, x0 + fw, y0 + 2 * fw, -4, x1 - fw, y1 - 2 * fw, 4, glass_col)
			commit(gg, glass_material)
		else
			-- **A glazed leaf** (user): stiles and rails around a pane, the
			-- bottom rail a panel to 900 mm; a leaf too small for a pane
			-- is solid
			local st, top, bot = 120, 150, 900
			local ly1 = y1 - LEAF_GAP
			local lt = LEAF_T / 2
			if def.glazed == 1 and x1 - x0 > 2 * st + 100 and
					ly1 - y0 > top + bot + 200 then
				B(lg, x0, y0, -lt, x0 + st, ly1, lt, leaf_col)
				B(lg, x1 - st, y0, -lt, x1, ly1, lt, leaf_col)
				B(lg, x0 + st, y0, -lt, x1 - st, y0 + bot, lt, leaf_col)
				B(lg, x0 + st, ly1 - top, -lt, x1 - st, ly1, lt, leaf_col)
				commit(lg, lit_material)
				local gg, gnode = part()
				gnode.position = node.position
				gnode.rotation = node.rotation
				B(gg, x0 + st, y0 + bot, -4, x1 - st, ly1 - top, 4, glass_col)
				commit(gg, glass_material)
			else
				B(lg, x0, y0, -lt, x1, ly1, lt, leaf_col)
				commit(lg, lit_material)
			end
		end
	end
end

-- The pictures: a quad each over the floors, its size its pixels times
-- its scale, drawn in the plan view and, if asked, in 3D
-- A surface's material id, written on it: corner is the surface's upper
-- left corner as seen from in front, n the way it faces and up the way
-- that is up on it, all in mm and world axes
local DECAL_MARGIN = 40
local function decal(corner, n, up, entry)
	if not entry or entry == 0 or not S.show_ids then
		return
	end
	-- The viewer looks along -n; to their right is up x -n
	local fx, fy, fz = -n[1], -n[2], -n[3]
	local rx = up[2] * fz - up[3] * fy
	local ry = up[3] * fx - up[1] * fz
	local rz = up[1] * fy - up[2] * fx
	local m = DECAL_MARGIN
	local x = corner[1] + rx * m - up[1] * m + n[1] * 2
	local y = corner[2] + ry * m - up[2] * m + n[2] * 2
	local z = corner[3] + rz * m - up[3] * m + n[3] * 2
	local node = P.decals:CreateChild("decal")
	built[#built + 1] = node
	node.position = magic.Vector3(W(x), W(y), W(z))
	-- Text3D faces its node's -Z: the node looks into the surface
	node:LookAt(magic.Vector3(W(x + fx), W(y + fy), W(z + fz)),
			magic.Vector3(up[1], up[2], up[3]))
	node.scale = magic.Vector3(1.5, 1.5, 1.5)
	local t = node:CreateComponent("Text3D")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
	t.text = tostring(entry)
	t:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
	t:SetColor(magic.Color(0.1, 0.1, 0.12))
	t.textEffect = magic.TE_STROKE
	t.effectColor = magic.Color(1, 1, 1, 0.8)
end

-- The decals of everything: a wall's two faces at their longest stretch
-- and its top, floors, ceilings, a box's six faces, a door's and a
-- window's frame
local function build_decals()
	for id, o in pairs(outlines) do
		local w = doc.ents[id].ints
		local y0, y1 = wall_span(w)
		for _, side in ipairs({"left", "right"}) do
			local best, bl = nil, 0
			for i = 1, #o.pts do
				if o.sides[i] == side then
					local p, q = o.pts[i], o.pts[i % #o.pts + 1]
					local l = geom.len(q[1] - p[1], q[2] - p[2])
					if l > bl then
						best, bl = i, l
					end
				end
			end
			if best and bl > 2 * DECAL_MARGIN then
				local p, q = o.pts[best], o.pts[best % #o.pts + 1]
				local nx, nz = (q[2] - p[2]) / bl, -(q[1] - p[1]) / bl
				-- Seen from outside, the edge runs left to right
				decal({p[1], y1, p[2]}, {nx, 0, nz}, {0, 1, 0},
						side == "left" and w.mat_left or w.mat_right)
			end
		end
		-- The top only when it is not the left face's, which says it already
		if w.mat_core ~= 0 and w.mat_core ~= w.mat_left then
			decal({o.pts[1][1], y1, o.pts[1][2]}, {0, 1, 0}, {0, 0, 1}, w.mat_core)
		end
	end
	for id, r in pairs(room_data) do
		local e = doc.ents[id].ints
		local x0, z1 = math.huge, -math.huge
		for _, p in ipairs(r.inner) do
			x0, z1 = math.min(x0, p[1]), math.max(z1, p[2])
		end
		decal({x0, 2, z1}, {0, 1, 0}, {0, 0, 1}, e.mat_floor)
		decal({x0, room_ceiling(doc.ents[id]), z1 - 2 * DECAL_MARGIN},
				{0, -1, 0}, {0, 0, -1}, e.mat_ceiling)
	end
	for id, it in pairs(inst_data) do
		local def = doc.ents[it.def].ints
		if not it.hosted and not it.voxel then
			-- Each face: its normal and its up, in the box's own axes
			for _, f in ipairs({{{0, 0, -1}, {0, 1, 0}}, {{0, 0, 1}, {0, 1, 0}},
					{{-1, 0, 0}, {0, 1, 0}}, {{1, 0, 0}, {0, 1, 0}},
					{{0, 1, 0}, {0, 0, 1}}, {{0, -1, 0}, {0, 0, -1}}}) do
				local n, up = f[1], f[2]
				local rx = up[2] * -n[3] - up[3] * -n[2]
				local ry = up[3] * -n[1] - up[1] * -n[3]
				local rz = up[1] * -n[2] - up[2] * -n[1]
				local h = {it.hx, it.hy, it.hz}
				local c = {}
				for a = 1, 3 do
					c[a] = (n[a] + up[a] - ({rx, ry, rz})[a]) * h[a]
				end
				local cx, cy, cz = geom.rot(c[1], c[2], c[3], it.pitch, it.yaw,
						it.roll)
				local wn = {geom.rot(n[1], n[2], n[3], it.pitch, it.yaw, it.roll)}
				local wu = {geom.rot(up[1], up[2], up[3], it.pitch, it.yaw,
						it.roll)}
				decal({it.x + cx, it.y + cy, it.z + cz}, wn, wu, def.mat)
			end
		elseif it.hosted and (def.kind == KIND.door or def.kind == KIND.window) then
			local f = it.frame
			local e = doc.ents[id].ints
			-- Seen from the wall's left, its far end along it is on the left
			local a = it.along + def.w / 2 + def.trim
			decal({f.ax + f.ux * a + f.nx * (f.lo + def.trim_depth),
					e.sill + def.h + def.trim, f.az + f.uz * a + f.nz *
					(f.lo + def.trim_depth)}, {f.nx, 0, f.nz}, {0, 1, 0}, def.mat)
		end
	end
end

local function build_images()
	image_data = {}
	local d = S.drag
	for _, e in ipairs(of_type("image")) do
		local i = e.ints
		-- The plan's own images/ ([FP_PLANS] 3)
		local tex = e.strs.file ~= "" and magic.cache:GetResource("Texture2D",
				"main/images/" .. doc.plan_name .. "/" .. e.strs.file)
		if tex then
			local mat = image_materials[e.strs.file]
			if not mat and images_used < IMAGE_MATERIALS then
				images_used = images_used + 1
				mat = magic.cache:GetResource("Material", "main/image" ..
						images_used .. ".xml")
				mat:SetTexture(magic.TU_DIFFUSE, tex)
				image_materials[e.strs.file] = mat
			end
			local x, z = i.x, i.z
			if d and d.moved and d.kind == "move" and d.inst[e.id] then
				x, z = x + d.dx, z + d.dz
			end
			local hw, hh = tex.width * i.scale / 2000, tex.height * i.scale / 2000
			local foot, uv = {}, {{0, 1}, {1, 1}, {1, 0}, {0, 0}}
			for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
				local fx, _, fz = geom.rot(c[1] * hw, 0, c[2] * hh, 0, i.yaw / 1000, 0)
				foot[k] = {x + fx, z + fz}
			end
			image_data[e.id] = {foot = foot, locked = i.locked == 1}
			if mat and (S.view == "2d" or i.show3d == 1) then
				local node = P.images:CreateChild("image")
				built[#built + 1] = node
				local g = node:CreateComponent("CustomGeometry")
				g:SetNumGeometries(1)
				g:BeginGeometry(0, magic.TRIANGLE_LIST)
				local col = magic.Color(1, 1, 1, i.opacity / 1000)
				-- Over the floors, under everything else
				for _, t in ipairs({{1, 3, 2}, {1, 4, 3}}) do
					for _, k in ipairs(t) do
						g:DefineVertex(magic.Vector3(W(foot[k][1]), W(3), W(foot[k][2])))
						g:DefineNormal(UP)
						g:DefineColor(col)
						g:DefineTexCoord(magic.Vector2(uv[k][1], uv[k][2]))
					end
				end
				g:Commit()
				g:SetMaterial(0, mat)
			end
		end
	end
end

local build_lamps
do
	-- A point light at (x, y, z) mm in a lamp entry's colour and brightness
	local function lamp_light(x, y, z, entry)
		local p = doc.ents[entry].ints
		local node = P.lamps:CreateChild("lamp")
		built[#built + 1] = node
		node.position = magic.Vector3(W(x), W(y), W(z))
		local light = node:CreateComponent("Light")
		light.lightType = magic.LIGHT_POINT
		light.color = rgb_color(kelvin_rgb(p.temperature))
		-- 1 is 100 %, a lamp's beside the sun (user, 2026-10-02); in
		-- proportion to it, as the lamp's surface is (Palette.glsl)
		local b = p.brightness / 1000
		light.brightness = 0.65 * b * M.daylight.PHYS.lamp
		light.range = 2 + 0.8 * b
end

-- The lamps that are on: each connected region of a volume's lamp voxels
-- is one light at its middle, not one per voxel; a box of a lamp material
-- is one at its centre. Only under PBR (user): in the unlit look, and so
-- in the plan view, a lamp's light only oversaturates.
build_lamps = function()
	if not M.pbr_now() then
		return
	end
	for id, it in pairs(inst_data) do
		if lamp_on(id) and not it.hosted then
			local def = doc.ents[it.def].ints
			if it.voxel then
				local vox = doc.voxels[it.def] or {}
				local lit = {}
				for key, m in pairs(vox) do
					if is_lamp_entry(m) then
						lit[key] = m
					end
				end
				local seen = {}
				for key, m in pairs(lit) do
					if not seen[key] then
						-- The region this voxel is in, by its six neighbours
						local stack, n, sx, sy, sz = {key}, 0, 0, 0, 0
						seen[key] = true
						while #stack > 0 do
							local k = table.remove(stack)
							local x, y, z = doc.voxel_cell(k)
							n, sx, sy, sz = n + 1, sx + x + 0.5, sy + y + 0.5, sz + z + 0.5
							for _, f in ipairs(FACES) do
								local nk = doc.voxel_key(x + f[1], y + f[2], z + f[3])
								if lit[nk] and not seen[nk] then
									seen[nk] = true
									stack[#stack + 1] = nk
								end
							end
						end
						local lx, ly, lz = geom.rot(sx / n * it.size, sy / n * it.size,
								sz / n * it.size, it.pitch, it.yaw, it.roll)
						lamp_light(it.ox + lx, it.oy + ly, it.oz + lz, m)
					end
				end
			elseif def.kind == KIND.box and is_lamp_entry(def.mat) then
				lamp_light(it.x, it.y, it.z, def.mat)
			end
		end
	end
end

end

-- simplified: everything is rebuilt on any change, which at a few hundred
-- walls is milliseconds; the upgrade is rebuilding only what is at the
-- nodes that moved
local rebuild
do
-- Stairwells ([FP_LAYOUTS]): stairs whose top is within STAIRWELL mm of
-- another layout's floor cut their footprint out of that floor and out of
-- the ceilings of their own. layouts: every layout, cur the current one's
-- fields. Returns layout id -> {floor = {pts, ...}, ceiling = {...}}.
local STAIRWELL = 200
function place.stairwells(layouts, cur)
	local out, rels, list = {}, {}, {}
	for _, l in ipairs(layouts) do
		out[l.id] = {floor = {}, ceiling = {}}
		rels[l.id] = place.rel(l.ints, cur)
		S.view_layout = l.id
		for _, e in ipairs(of_type("instance")) do
			local i = e.ints
			local def = doc.ents[i.def]
			if def and def.ints.kind == KIND.stairs and i.pitch == 0 and
					i.roll == 0 then
				local p = def.ints
				local top = i.align == 1 and settings().ceiling - i.offset or
						i.offset + p.h
				local foot = {}
				for k, c in ipairs({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}}) do
					local fx, _, fz = geom.rot(c[1] * p.w / 2, 0, c[2] * p.d / 2, 0,
							i.yaw / 1000, 0)
					foot[k] = {i.x + fx, i.z + fz}
				end
				if not geom.is_ccw(foot) then
					foot = {foot[4], foot[3], foot[2], foot[1]}
				end
				list[#list + 1] = {layout = l.id, top = top, foot = foot}
			end
		end
	end
	S.view_layout = S.layout
	for _, st in ipairs(list) do
		local r = rels[st.layout]
		for id, u in pairs(rels) do
			if id ~= st.layout and math.abs(st.top + r.y - u.y) <= STAIRWELL then
				local pts = {}
				for k, q in ipairs(st.foot) do
					local x, _, z = place.point(r, q[1], 0, q[2])
					local ux, _, uz = place.unpoint(u, x, 0, z)
					pts[k] = {ux, uz}
				end
				table.insert(out[id].floor, pts)
				table.insert(out[st.layout].ceiling, st.foot)
			end
		end
	end
	return out
end

-- Walking changes the current layout (geom.pick_floor)
function place.follow(w)
	local floors = {}
	for _, l in ipairs(place.layers) do
		local lx, _, lz = place.unpoint(l.rel, w.x, 0, w.z)
		local under = false
		for _, r in pairs(l.rooms) do
			if geom.point_in_polygon(lx, lz, r.pts) then
				under = true
				break
			end
		end
		floors[#floors + 1] = {id = l.id, y = l.rel.y, under = under}
	end
	local id = geom.pick_floor(floors, S.layout, w.feet)
	if id then
		place.switch(id)
		-- Stale until the rebuild the switch asks for
		place.layers = {}
		doc.notice("On " .. doc.ents[id].strs.name)
	end
end

-- **What of the open sky's light each room gets** ([FP_DAYLIGHT]): its
-- daylight factor from the glass it has -- windows, glazed doors and
-- openings, found on either side of their walls -- over its floor
-- (daylight.lua), kept as 1 - it by room id, and the lookup tri() makes
-- for a face in the layout's own frame. simplified: the sky's share only;
-- the sun a room's windows let in lights the floor it falls on and not
-- the rest of the room, which a bounce term would.
-- **Each room's slot**, 1 to 255, over the whole rebuild (0: outdoors,
-- or no slot left): its row in the room table, which the texture
-- coordinate's y carries as slot + 1 - daylight factor. And what its
-- sunlight bounce is worked out from (M.room_bounce): the glass to the
-- outside with which way it faces, in the scene's frame, and the room's
-- floor colour and surfaces.
-- Kept over rebuilds, so that a room keeps its row and its probe; a room
-- gone frees its slot at the end of the rebuild
M.room_slot, M.slot_owner, M.room_light, M.room_seen = {}, {}, {}, {}
-- And each slot's probes (M.room_probes): the rows of the probes' atlas
-- they are drawn in, {first, n, and the first's and the last's x and z in
-- the scene's frame, m}; each row's slot, where its probe stands (the
-- scene's frame, mm) and whether its six faces have been drawn
-- (M.probes_tick)
M.probe_rows, M.row_owner, M.probe_pos, M.probe_ready = {}, {}, {}, {}
local function entry_albedo(id)
	local e = id and doc.ents[id]
	if not e or e.type ~= "palette" then
		return {r = 0.5, g = 0.5, b = 0.5}
	end
	local p = e.ints
	local function lin(rgb)
		return {r = (math.floor(rgb / 65536) / 255) ^ 2.2,
				g = (math.floor(rgb / 256) % 256 / 255) ^ 2.2,
				b = (rgb % 256 / 255) ^ 2.2}
	end
	local base, paint = lin(p.base), lin(p.color)
	local k = p.finish == 1 and 1 or p.finish == 2 and p.opacity / 1000 or 0
	local function ch(c)
		local nat = base[c]
		return p.finish == 0 and nat * paint[c] or nat + (paint[c] - nat) * k
	end
	return {r = ch("r"), g = ch("g"), b = ch("b")}
end
M.entry_albedo = entry_albedo

-- A room's walls' albedo: their faces' to it, by their length
function M.wall_albedo(rd)
	local sum, len = {r = 0, g = 0, b = 0}, 0
	for i = 1, #rd.ids do
		local wid, forward = wall_between(rd.ids[i], rd.ids[i % #rd.ids + 1])
		local p, q = rd.pts[i], rd.pts[i % #rd.pts + 1]
		local l = geom.len(q[1] - p[1], q[2] - p[2])
		local w = wid and doc.ents[wid]
		-- The room is left of its counter-clockwise edges
		local a = entry_albedo(w and (forward and w.ints.mat_left or
				w.ints.mat_right))
		sum.r, sum.g, sum.b = sum.r + a.r * l, sum.g + a.g * l, sum.b + a.b * l
		len = len + l
	end
	if len <= 0 then
		return {r = 0.5, g = 0.5, b = 0.5}
	end
	return {r = sum.r / len, g = sum.g / len, b = sum.b / len}
end

-- **A room's probes** (user, 2026-10-01: one in the middle of a long room
-- lit its far wall as if it were by the sun's patch at the other end; the
-- path-traced reference had that wall at under half): along the room's
-- longest edge, one every 2 m or so, up to four, at a standing eye's
-- height or half the ceiling's. Rows of the atlas (PROBE_ROWS) for them,
-- next to each other, kept while their number is; fewer when there are
-- not enough, none past that.
-- simplified: on the line through the middle of the room across that
-- edge; a probe that is not in the room (an L) is put in its first
-- triangle's middle
M.PROBE_GAP, M.PROBES_MAX = 2000, 4
function M.free_rows(slot)
	local pr = M.probe_rows[slot]
	if not pr then
		return
	end
	for row = pr.first, pr.first + pr.n - 1 do
		M.row_owner[row], M.probe_pos[row], M.probe_ready[row] = nil, nil, nil
	end
	M.probe_rows[slot] = nil
end
function M.room_probes(slot, rd, e)
	local pts = #rd.inner >= 3 and rd.inner or rd.pts
	local ux, uz, best = 1, 0, 0
	for i = 1, #pts do
		local p, q = pts[i], pts[i % #pts + 1]
		local l = geom.len(q[1] - p[1], q[2] - p[2])
		if l > best then
			best, ux, uz = l, (q[1] - p[1]) / l, (q[2] - p[2]) / l
		end
	end
	local t0, t1, s0, s1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in ipairs(pts) do
		local t, sv = p[1] * ux + p[2] * uz, -p[1] * uz + p[2] * ux
		t0, t1 = math.min(t0, t), math.max(t1, t)
		s0, s1 = math.min(s0, sv), math.max(s1, sv)
	end
	local n = math.max(1, math.min(M.PROBES_MAX, math.ceil((t1 - t0) / M.PROBE_GAP)))
	-- The rows: the same ones while the number is the same
	local pr = M.probe_rows[slot]
	if not pr or pr.n ~= n then
		M.free_rows(slot)
		pr = nil
		for want = n, 1, -1 do
			for first = 1, M.PROBE_ROWS - want do
				local free = true
				for row = first, first + want - 1 do
					free = free and not M.row_owner[row]
				end
				if free then
					pr = {first = first, n = want}
					break
				end
			end
			if pr then
				break
			end
		end
		if not pr then
			return
		end
		for row = pr.first, pr.first + pr.n - 1 do
			M.row_owner[row] = slot
		end
		M.probe_rows[slot] = pr
	end
	n = pr.n
	local y = math.min(1500, room_ceiling(e) / 2)
	local sm = (s0 + s1) / 2
	local r = M.cur_rel or place.WORLD
	for i = 1, n do
		local t = t0 + (t1 - t0) * (i - 0.5) / n
		local x, z = t * ux - sm * uz, t * uz + sm * ux
		if not geom.point_in_polygon(x, z, pts) then
			local tri = geom.triangulate(pts)[1]
			if tri then
				x = (pts[tri[1]][1] + pts[tri[2]][1] + pts[tri[3]][1]) / 3
				z = (pts[tri[1]][2] + pts[tri[2]][2] + pts[tri[3]][2]) / 3
			end
		end
		local px, py, pz = place.point(r, x, y, z)
		M.probe_pos[pr.first + i - 1] = {x = px, y = py, z = pz}
	end
	local a, b = M.probe_pos[pr.first], M.probe_pos[pr.first + n - 1]
	pr.x0, pr.z0, pr.x1, pr.z1 = W(a.x), W(a.z), W(b.x), W(b.z)
	-- and the room's box, which the probes' light is put back on
	-- (Palette.glsl's RoomAmbient): a corner, the along axis, the extents
	-- along it and across, the floor's and the ceiling's height; m
	local ox, oy, oz = place.point(r, t0 * ux - s0 * uz, 0, t0 * uz + s0 * ux)
	local ax, _, az = place.point(r, ux, 0, uz)
	local zx, _, zz = place.point(r, 0, 0, 0)
	pr.box = {ox = W(ox), oz = W(oz), ux = ax - zx, uz = az - zz,
			lu = W(t1 - t0), lv = W(s1 - s0), y0 = W(oy), y1 = W(oy + room_ceiling(e))}
end

-- Where along a room's probes a point (the scene's frame, m) is: the row
-- before it, the row after and how far between
function M.probe_at(pr, x, z)
	if pr.n < 2 then
		return pr.first, pr.first, 0
	end
	local dx, dz = pr.x1 - pr.x0, pr.z1 - pr.z0
	local t = ((x - pr.x0) * dx + (z - pr.z0) * dz) / (dx * dx + dz * dz)
	t = math.max(0, math.min(1, t)) * (pr.n - 1)
	local i = math.min(math.floor(t), pr.n - 2)
	return pr.first + i, pr.first + i + 1, t - i
end
function M.room_occlusion()
	local glass = {}
	local sunward = {}
	for _, it in pairs(inst_data) do
		local def = it.hosted and it.frame and doc.ents[it.def]
		local d = def and def.ints
		local a = 0
		if d and d.kind == KIND.window then
			a = math.max(0, d.w - 4 * FRAME_W) * math.max(0, d.h - 4 * FRAME_W)
		elseif d and d.kind == KIND.opening then
			a = d.w * d.h
		elseif d and d.kind == KIND.door and d.glazed == 1 then
			a = math.max(0, d.w - 240) * math.max(0, d.h - 1050)
		end
		if a > 0 then
			local f = it.frame
			local off = f.lo + f.ro + 100
			local side = {}
			for _, sgn in ipairs({1, -1}) do
				side[sgn] = room_at(it.x + f.nx * off * sgn, it.z + f.nz * off * sgn)
				local rid = side[sgn]
				if rid then
					glass[rid] = (glass[rid] or 0) + a
				end
			end
			-- Glass with the outside behind it lets the sun in: facing
			-- away from the room, in the scene's frame
			local through = d.kind == KIND.opening and 1 or 0.75
			for _, sgn in ipairs({1, -1}) do
				local rid = side[sgn]
				if rid and not side[-sgn] then
					local r = M.cur_rel or place.WORLD
					local x0, _, z0 = place.point(r, 0, 0, 0)
					local x1, _, z1 = place.point(r, -f.nx * sgn, 0, -f.nz * sgn)
					local l = sunward[rid] or {}
					sunward[rid] = l
					-- and its middle in the scene's frame, in metres, for the
					-- light the probes see from it (M.cpu_cubes)
					local cx, cy, cz = place.point(r, it.x, (it.y0 + it.y1) / 2, it.z)
					l[#l + 1] = {a = a / 1e6 * through, ox = x1 - x0, oz = z1 - z0,
							x = W(cx), y = W(cy), z = W(cz), through = through}
				end
			end
		end
	end
	M.room_occ = {}
	for id, rd in pairs(room_data) do
		local occ = 1 - M.daylight.daylight_factor(glass[id] or 0, rd.net)
		local slot = M.room_slot[id]
		if not slot then
			for k = 1, 255 do
				if not M.slot_owner[k] then
					slot = k
					M.slot_owner[k] = id
					M.room_slot[id] = slot
					break
				end
			end
		end
		M.room_seen[id] = true
		-- Packed: slot + occ, occ under 1
		M.room_occ[id] = (slot or 0) + math.min(occ, 0.995)
		if slot then
			local e = doc.ents[id]
			local perim = 0
			for i = 1, #rd.pts do
				local p, q = rd.pts[i], rd.pts[i % #rd.pts + 1]
				perim = perim + geom.len(q[1] - p[1], q[2] - p[2])
			end
			local floor = rd.net / 1e6
			local height = room_ceiling(e) / 1000
			local _, fy = place.point(M.cur_rel or place.WORLD, 0, 0, 0)
			M.room_light[slot] = {wins = sunward[id] or {},
					area = 2 * floor + perim / 1000 * height,
					floor_area = floor, wall_area = perim / 1000 * height,
					floor = entry_albedo(e.ints.mat_floor),
					ceiling = entry_albedo(e.ints.mat_ceiling),
					wall = M.wall_albedo(rd), height = height,
					floor_y = W(fy)}
			M.room_probes(slot, rd, e)
		end
	end
	M.tri_occ, M.tri_occ_fn = 0, function(xm, zm)
		local id = room_at(xm * 1000, zm * 1000)
		return id and M.room_occ[id] or 0
	end
end

-- **The sun a room's windows let in, bounced** (user, 2026-10-01): what
-- comes through the glass facing the sun lands on the floor, which sends
-- its colour of it back into the room; spread over the room's surfaces
-- and taken up again by them, half each time (1 / (1 - 0.5)). As the
-- shader's ambient adds it: irradiance over pi. For a room without
-- probes; with them, the probes' light is the ambient (M.cpu_cubes, or
-- the cube mode's drawn ones).
-- simplified: the patch is taken to land on the floor, whatever the
-- sun's height, and nothing outside shades a window
--
-- **The room table**, eight texels a row (Palette.glsl's RoomTexel). By
-- the room's slot: the bounce as sqrt(L / 16) and whether the room's
-- probes are there to light it (alpha); its first probe row and their
-- number (/ 255); its box (M.room_probes): the corner's x and z, the
-- extents along and across, the along axis's x and z, the floor's and the
-- ceiling's height. By a probe's row: its x and z, and its y and its
-- room's slot (/ 255). A length is
-- 16 bits in two bytes, 4 mm a step from -131 m; the axis 16 bits from -1
-- to 1.
M.ROOM_TABLE_ROWS = 256
function M.room_bounce(tx, h, tz, light)
	M.bounce_args = {tx, h, tz, light}
	local image = M.room_table_image
	if not image then
		image = magic.Image:new()
		assert(image:SetSize(8, M.ROOM_TABLE_ROWS, 4), "room table image")
		assert(magic.cache:AddManualResource(image, "fp_room_table_image"),
				"room table image in the cache")
		M.room_table_image = image
	end
	-- The texels as one list (buildat.set_image_data), four numbers each
	local W8 = 8
	local v = {}
	for i = 1, W8 * M.ROOM_TABLE_ROWS * 4 do
		v[i] = 0
	end
	local function put(x, y, r, g, b, a)
		local i = (y * W8 + x) * 4
		v[i + 1], v[i + 2], v[i + 3], v[i + 4] = r, g, b, a
	end
	local function c16(x, y, a, b, unit)
		local function k(val)
			if unit then
				return math.max(0, math.min(65535, math.floor((val + 1) * 32767.5 + 0.5)))
			end
			return math.max(0, math.min(65535, math.floor(val / 0.004 + 0.5) + 32768))
		end
		local ka, kb = k(a), k(b)
		put(x, y, math.floor(ka / 256) / 255, ka % 256 / 255,
				math.floor(kb / 256) / 255, kb % 256 / 255)
	end
	local e = h > 0 and light.sun or 0
	local sc = light.sun_color
	local drawn = S.lighting == "pbr_cube"
	for slot, rl in pairs(M.room_light) do
		local c = {0, 0, 0}
		if e > 0 then
			local flux = 0
			for _, w in ipairs(rl.wins) do
				flux = flux + w.a * e * math.max(0, w.ox * tx + w.oz * tz)
			end
			local k = flux / math.max(rl.area, 1) / 0.5 / math.pi
			c = {k * rl.floor.r * sc.r, k * rl.floor.g * sc.g, k * rl.floor.b * sc.b}
		end
		local pr = M.probe_rows[slot]
		local ready = pr ~= nil
		if pr and drawn then
			for row = pr.first, pr.first + pr.n - 1 do
				ready = ready and M.probe_ready[row] == true
			end
		end
		put(0, slot, math.sqrt(math.min(c[1], 16) / 16),
				math.sqrt(math.min(c[2], 16) / 16),
				math.sqrt(math.min(c[3], 16) / 16), ready and 1 or 0)
		if pr then
			put(1, slot, pr.first / 255, pr.n / 255, 0, 0)
			local b = pr.box
			c16(2, slot, b.ox, b.oz)
			c16(3, slot, b.lu, b.lv)
			c16(4, slot, b.ux, b.uz, true)
			c16(5, slot, b.y0, b.y1)
		end
	end
	-- By a probe's row: its place, and its room's slot
	for row, at in pairs(M.probe_pos) do
		c16(6, row, W(at.x), W(at.z))
		c16(7, row, W(at.y), 0)
		v[(row * W8 + 7) * 4 + 3] = (M.row_owner[row] or 0) / 255
	end
	buildat.set_image_data(image, v)
	local texture = M.room_table
	if not texture then
		texture = magic.Texture2D:new()
		texture:SetNumLevels(1)
		-- Held by the cache, and read by name by the grid's pass
		-- (fp_grid.xml)
		assert(magic.cache:AddManualResource(texture, "fp_room_table"),
				"room table in the cache")
		M.room_table = texture
	end
	assert(texture:SetData(image), "room table texture")
	texture.filterMode = magic.FILTER_NEAREST
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetTexture(magic.TU_SPECULAR, texture)
	end
	M.cpu_cubes(tx, h, tz, light)
end

-- **The probes' light worked out here** (plain PBR, user 2026-10-01: the
-- mode without the drawn probes, to come close to the path-traced
-- reference too): each probe's cells (M.PROBE_K by M.PROBE_K a face, as
-- the reduce pass has the drawn ones) as they would have seen the room's
-- box. Where a cell's middle looks, the box is the room's surfaces -- the
-- ceiling up, the floor down, the walls round -- at their albedo times
-- the room's light, as an integrating sphere has it: the sky's flux
-- through the glass spread over the surfaces, and what they and the
-- sun's patches send on, again and again (1 / (1 - the mean albedo), a
-- channel at a time, which is the room's colour cast); and on them the
-- sources, by the share of the cell that sees them: each window's view
-- of half sky and half ground, and each sun's patch, the window's area
-- where the sun through its middle lands on the box, at that face's
-- albedo times the sun on it. Palette.glsl puts the cells back on the box
-- for each surface, near and far as they are. In a 6 * K * K by
-- PROBE_ROWS texture as sqrt(L / 16).
-- simplified: a window and a patch are discs; glass between rooms lets
-- nothing through; a source is not shaded; the surfaces are lit evenly
M.PROBE_K = 2
M.FACE_AXES = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1},
		{0, 0, -1}}
-- Each face's right and up, as Palette.glsl's ProbeSample has the face
-- cameras' (PROBE_FACES)
M.FACE_RU = {{{0, 0, -1}, {0, 1, 0}}, {{0, 0, 1}, {0, 1, 0}},
		{{1, 0, 0}, {0, 0, -1}}, {{1, 0, 0}, {0, 0, 1}},
		{{1, 0, 0}, {0, 1, 0}}, {{-1, 0, 0}, {0, 1, 0}}}
-- Where a ray from p (local to the box: along, up, across) leaves the box,
-- and the face's inward normal
function M.box_exit(b, p, d)
	local lo, hi = {0, b.y0, 0}, {b.lu, b.y1, b.lv}
	local tmin, axis = math.huge, 1
	for i = 1, 3 do
		if math.abs(d[i]) > 1e-9 then
			local t = ((d[i] > 0 and hi[i] or lo[i]) - p[i]) / d[i]
			if t < tmin then
				tmin, axis = t, i
			end
		end
	end
	local n = {0, 0, 0}
	n[axis] = d[axis] > 0 and -1 or 1
	tmin = math.max(tmin, 0)
	return {p[1] + d[1] * tmin, p[2] + d[2] * tmin, p[3] + d[3] * tmin}, n
end
function M.cpu_cubes(tx, h, tz, light)
	local K = M.PROBE_K
	local image = M.cpu_cube_image
	if not image then
		image = magic.Image:new()
		assert(image:SetSize(6 * K * K, M.PROBE_ROWS, 4), "cpu cubes image")
		local texture = magic.Texture2D:new()
		texture:SetNumLevels(1)
		-- Held by the cache: the materials let go of it under the cube
		-- mode, and one nothing holds is freed under the next SetData
		assert(magic.cache:AddManualResource(image, "fp_cpu_cubes_image"),
				"cpu cubes image in the cache")
		assert(magic.cache:AddManualResource(texture, "fp_cpu_cubes"),
				"cpu cubes in the cache")
		M.cpu_cube_image, M.cpu_cube_texture = image, texture
		M.kept[#M.kept + 1] = image
		M.kept[#M.kept + 1] = texture
	end
	M.cpu_cube = {}
	-- The texels as one list (buildat.set_image_data)
	local cw = 6 * K * K
	local v = {}
	for i = 1, cw * M.PROBE_ROWS * 4 do
		v[i] = 0
	end
	local rgb = M.ground_rgb()
	local function lin(v)
		return (v / 255) ^ 2.2
	end
	local ground = {lin(math.floor(rgb / 65536)), lin(math.floor(rgb / 256) % 256),
			lin(rgb % 256)}
	local sky = {light.ambient.r, light.ambient.g, light.ambient.b}
	local sc = {light.sun_color.r, light.sun_color.g, light.sun_color.b}
	local e_sun = h > 0 and light.sun or 0
	local view = {}
	for c = 1, 3 do
		view[c] = 0.5 * sky[c] + 0.5 * ground[c] * (e_sun * math.max(h, 0) / math.pi + sky[c])
	end
	for slot, pr in pairs(M.probe_rows) do
		local rl = M.room_light[slot]
		local b = pr.box
		if rl and b then
			local function ch(t)
				return {t.r, t.g, t.b}
			end
			local rf, rc, rw = ch(rl.floor), ch(rl.ceiling), ch(rl.wall)
			local function albedo(n)
				return n[2] > 0.5 and rf or n[2] < -0.5 and rc or rw
			end
			-- The scene's frame to the box's: along, up, across
			local function loc(x, y, z)
				local dx, dz = x - b.ox, z - b.oz
				return {dx * b.ux + dz * b.uz, y, -dx * b.uz + dz * b.ux}
			end
			local function dir(x, y, z)
				return {x * b.ux + z * b.uz, y, -x * b.uz + z * b.ux}
			end
			local A = math.max(rl.area, 1)
			-- The sources, discs on the box: middle, inward normal, area,
			-- radiance
			local sources = {}
			local phi_win, phi_ref = {0, 0, 0}, {0, 0, 0}
			local s = dir(tx, h, tz)
			for _, w in ipairs(rl.wins) do
				-- The window on its wall's face of the box: its middle (on
				-- the wall's line) brought onto the box, facing in
				local c = loc(w.x, w.y, w.z)
				local at = {math.max(0, math.min(b.lu, c[1])),
						math.max(b.y0, math.min(b.y1, c[2])), math.max(0, math.min(b.lv, c[3]))}
				local inward = dir(-w.ox, 0, -w.oz)
				local n = math.abs(inward[1]) > math.abs(inward[3]) and
						{inward[1] > 0 and 1 or -1, 0, 0} or {0, 0, inward[3] > 0 and 1 or -1}
				sources[#sources + 1] = {p = at, n = n, a = w.a, l = view}
				for i = 1, 3 do
					phi_win[i] = phi_win[i] + math.pi * view[i] * w.a
				end
				local cosw = w.ox * tx + w.oz * tz
				if e_sun > 0 and cosw > 0 then
					local pp, pn = M.box_exit(b, at, {-s[1], -s[2], -s[3]})
					local cosf = math.max(0.05, s[1] * pn[1] + s[2] * pn[2] + s[3] * pn[3])
					local alb = albedo(pn)
					local lp = {}
					for i = 1, 3 do
						phi_ref[i] = phi_ref[i] + alb[i] * e_sun * cosw * w.a * sc[i]
						lp[i] = alb[i] * e_sun * cosf * w.through * sc[i] / math.pi
					end
					sources[#sources + 1] = {p = pp, n = pn,
							a = math.min(w.a / w.through * cosw / cosf, rl.floor_area), l = lp}
				end
			end
			-- The surfaces' irradiance: the sky's direct, spread, and what
			-- has been reflected once or more
			local eu = {}
			for i = 1, 3 do
				local mean = (rl.floor_area * (rf[i] + rc[i]) + rl.wall_area * rw[i]) / A
				eu[i] = phi_win[i] / A + (phi_ref[i] + mean * phi_win[i]) /
						(A * (1 - math.min(mean, 0.95)))
			end
			for row = pr.first, pr.first + pr.n - 1 do
				local pw = M.probe_pos[row]
				local q = loc(W(pw.x), W(pw.y), W(pw.z))
				local cells = {}
				for f = 1, 6 do
					local fa, ru = M.FACE_AXES[f], M.FACE_RU[f]
					for cy = 0, K - 1 do
						for cx = 0, K - 1 do
							-- Three by three looks in the cell, at what the box
							-- is there
							local sum = {0, 0, 0}
							for sy = 0, 2 do
								for sx = 0, 2 do
									local a = 2 * (cx + (sx + 0.5) / 3) / K - 1
									local bb = 1 - 2 * (cy + (sy + 0.5) / 3) / K
									local d = dir(fa[1] + ru[1][1] * a + ru[2][1] * bb,
											fa[2] + ru[1][2] * a + ru[2][2] * bb,
											fa[3] + ru[1][3] * a + ru[2][3] * bb)
									local hp, hn = M.box_exit(b, q, d)
									local alb = albedo(hn)
									local l = {alb[1] * eu[1] / math.pi,
											alb[2] * eu[2] / math.pi, alb[3] * eu[3] / math.pi}
									for _, src in ipairs(sources) do
										local dx, dy, dz = hp[1] - src.p[1], hp[2] - src.p[2],
												hp[3] - src.p[3]
										if hn[1] * src.n[1] + hn[2] * src.n[2] +
												hn[3] * src.n[3] > 0.9 and
												dx * dx + dy * dy + dz * dz < src.a / math.pi then
											l = src.l
										end
									end
									for i = 1, 3 do
										sum[i] = sum[i] + l[i] / 9
									end
								end
							end
							cells[#cells + 1] = sum
						end
					end
				end
				M.cpu_cube[row] = cells
				for i, c in ipairs(cells) do
					local o = (row * cw + i - 1) * 4
					v[o + 1] = math.sqrt(math.min(c[1], 16) / 16)
					v[o + 2] = math.sqrt(math.min(c[2], 16) / 16)
					v[o + 3] = math.sqrt(math.min(c[3], 16) / 16)
					v[o + 4] = 1
				end
			end
		end
	end
	buildat.set_image_data(image, v)
	assert(M.cpu_cube_texture:SetData(image), "cpu cubes texture")
	M.cpu_cube_texture.filterMode = magic.FILTER_NEAREST
	if M.cube_mode == 2 then
		for _, m in ipairs({lit_material, glass_material}) do
			m:SetTexture(magic.TU_EMISSIVE, M.cpu_cube_texture)
		end
	end
end

-- **A probe in each room** (3D lighting "PBR with room cube maps", user,
-- 2026-10-01): the room seen from its middle in six 90 degree faces,
-- drawn in HDR into a row of an atlas, PROBE_T a face, a row a room slot;
-- and each face averaged into a texel of a 6 by PROBE_ROWS table by the
-- reduce pass (probe_reduce.xml), which is the ambient cube a surface
-- takes its indirect light from (Palette.glsl). One face is drawn a
-- frame, round all the rooms, so a change in the light reaches a room's
-- probe in a second or so for ten rooms. Each face sees the probes of the
-- frames before, so the light bounces on.
-- simplified: one probe a room, so all of a room is lit as from its
-- middle; a slot over PROBE_ROWS - 1 has none, and its room is lit as
-- without the cubes. A float16 render target has no mips on the driver
-- this was written on (extensions/launch_world's [PBR_HDR] finding), so
-- the average is the reduce pass's and a reflection is sharp.
local PROBE_T, PROBE_ROWS = 32, 64
M.PROBE_ROWS = PROBE_ROWS
-- Pitch and yaw of each face's camera: +X, -X, +Y, -Y, +Z, -Z, which is
-- the order and the axes Palette.glsl's ProbeUV reads them in
local PROBE_FACES = {{0, 90}, {0, -90}, {-90, 0}, {90, 0}, {0, 0}, {0, 180}}
local function probes_init()
	if M.probe then
		return M.probe
	end
	local p = {i = 0}
	local f16 = magic.Graphics.GetRGBAFloat16Format()
	local atlas = magic.Texture2D:new()
	atlas:SetNumLevels(1)
	assert(atlas:SetSize(6 * PROBE_T, PROBE_ROWS * PROBE_T, f16,
			magic.TEXTURE_RENDERTARGET), "the probes' atlas")
	atlas.filterMode = magic.FILTER_BILINEAR
	-- By name, for the reduce pass's render path to read
	assert(magic.cache:AddManualResource(atlas, "fp_probe_atlas"),
			"the probes' atlas in the cache")
	local reduce = magic.Texture2D:new()
	reduce:SetNumLevels(1)
	assert(reduce:SetSize(6 * M.PROBE_K * M.PROBE_K, PROBE_ROWS, f16,
			magic.TEXTURE_RENDERTARGET),
			"the probes' ambient cubes")
	reduce.filterMode = magic.FILTER_NEAREST
	-- and for the frame's white (FpFrame.glsl)
	assert(magic.cache:AddManualResource(reduce, "fp_probe_reduce"),
			"the probes' ambient cubes in the cache")
	local function view(texture, xml, fov)
		local node = scene:CreateChild("probe camera")
		local cam = node:CreateComponent("Camera")
		cam.fov = fov
		cam.aspectRatio = 1
		cam.nearClip = 0.05
		cam.farClip = 500
		local vp = magic.Viewport:new(scene, cam)
		local rp = vp.renderPath:Clone()
		rp:Load(magic.cache:GetResource("XMLFile", xml))
		vp.renderPath = rp
		local surface = texture:GetRenderSurface()
		surface:SetViewport(0, vp)
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		M.kept[#M.kept + 1] = vp
		return node, vp, surface
	end
	p.node, p.vp, p.surface = view(atlas, "RenderPaths/Deferred.xml", 90)
	local _, _, rsurface = view(reduce, "main/probe_reduce.xml", 90)
	p.reduce_surface = rsurface
	p.atlas, p.reduce = atlas, reduce
	M.kept[#M.kept + 1] = atlas
	M.kept[#M.kept + 1] = reduce
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetTexture(magic.TU_NORMAL, atlas)
	end
	M.probe = p
	return p
end
M.probes_init = probes_init

-- Each frame: which probes light the rooms (the shader's RoomCubes: 0
-- none, 1 the drawn ones, 2 M.cpu_cubes'), and under the cube mode the
-- next face of the next probe
function M.probes_tick()
	local mode = not M.pbr_now() and 0 or S.lighting == "pbr_cube" and 1 or 2
	if mode ~= M.cube_mode then
		M.cube_mode = mode
		local p = mode > 0 and probes_init()
		for _, m in ipairs({lit_material, glass_material}) do
			m:SetShaderParameter("RoomCubes", mode)
			if mode == 1 then
				m:SetTexture(magic.TU_EMISSIVE, p.reduce)
			elseif mode == 2 and M.cpu_cube_texture then
				m:SetTexture(magic.TU_EMISSIVE, M.cpu_cube_texture)
			end
		end
		-- The room table's readiness is the mode's
		S.daylight_key = nil
	end
	if mode ~= 1 then
		return
	end
	local p = probes_init()
	local rows = {}
	for row in pairs(M.probe_pos) do
		rows[#rows + 1] = row
	end
	if #rows == 0 then
		return
	end
	table.sort(rows)
	p.i = p.i % (#rows * 6)
	local row = rows[math.floor(p.i / 6) + 1]
	local face = p.i % 6
	p.i = p.i + 1
	local at = M.probe_pos[row]
	p.node.position = magic.Vector3(W(at.x), W(at.y), W(at.z))
	p.node.rotation = magic.Quaternion(PROBE_FACES[face + 1][1],
			PROBE_FACES[face + 1][2], 0)
	p.vp:SetRect(magic.IntRect(face * PROBE_T, row * PROBE_T,
			(face + 1) * PROBE_T, (row + 1) * PROBE_T))
	p.surface:QueueUpdate()
	p.reduce_surface:QueueUpdate()
	if face == 5 and not M.probe_ready[row] then
		M.probe_ready[row] = true
		if M.bounce_args then
			local a = M.bounce_args
			M.room_bounce(a[1], a[2], a[3], a[4])
		end
	end
end
-- One value for what is built in its own frame: the room it stands in, or
-- for a door or a window the darker of the two it is between; and for
-- those, the two, on the side of the frame's normal first
function M.inst_occlusion(it)
	local function at(x, z)
		local id = room_at(x, z)
		return id and M.room_occ[id] or 0
	end
	if it.hosted and it.frame then
		local f = it.frame
		local off = f.lo + f.ro + 100
		-- The darker of the two by the occ part (slot + occ, packed)
		local a = at(it.x + f.nx * off, it.z + f.nz * off)
		local b = at(it.x - f.nx * off, it.z - f.nz * off)
		return (a % 1) >= (b % 1) and a or b, a, b
	end
	return at(it.x, it.z)
end

-- wells: {floor = {pts, ...}, ceiling = {pts, ...}}, the stairwells cut in
-- this layout's rooms
-- **A foundation from the ground up to the floor** (user): set by
-- rebuild() for a building's lowest layout when it is above the ground,
-- {h = its height in mm, mat = the palette entry}, else nil
local foundation = nil

local function build_layout(seen_voxels, wells)
	solids = {}
	wall_data = {}
	for _, e in ipairs(of_type("wall")) do
		local w = e.ints
		local ax, az = node_pos(w.a)
		local bx, bz = node_pos(w.b)
		wall_data[e.id] = {ax = ax, az = az, bx = bx, bz = bz,
				a_node = w.a, b_node = w.b, thickness = w.thickness,
				justify = w.justify,
				-- Joined with what is at its height: one that hangs clear
				-- of the floor apart from the standing ones, but one hung
				-- from the ceiling all the way down is standing (user:
				-- such a corner was open outside)
				group = (wall_span(w)) > 0 and 1 or 0}
	end
	outlines = geom.wall_outlines(wall_data)
	build_room_data()
	build_inst_data()
	M.room_occlusion()
	local cut = settings().cut
	-- A part's triangles, gathered in Lua and handed to the engine by
	-- commit() in one call (see tri())
	local function geometry(parent)
		local node = parent:CreateChild("")
		built[#built + 1] = node
		local g = {node = node}
		TRI_LISTS[g] = {}
		return g, node
	end
	local function commit(g, material)
		-- A door's or a window's face takes the room it is in front of, as
		-- a wall's does (tri_occ_fn), by where it is in the layout's frame
		-- with the node's turn about Y; one inside the wall, the side of
		-- the wall it faces or, square to the wall in the opening, is on
		local sides, list = M.tri_sides, TRI_LISTS[g]
		if sides then
			local d, o = g.node.direction, g.node.position
			local dx, dz = d.x, d.z
			for k = 0, #list - 36, 36 do
				local nx, nz = list[k + 4], list[k + 6]
				local wx, wz = nx * dz + nz * dx, nz * dz - nx * dx
				local lx = (list[k + 1] + list[k + 13] + list[k + 25]) / 3
				local lz = (list[k + 3] + list[k + 15] + list[k + 27]) / 3
				local px = o.x + lx * dz + lz * dx
				local pz = o.z + lz * dz - lx * dx
				local id = room_at((px + wx * 0.05) * 1000, (pz + wz * 0.05) * 1000)
				local s = wx * sides.nx + wz * sides.nz
				if math.abs(s) <= 0.01 then
					s = (px * 1000 - sides.x) * sides.nx + (pz * 1000 - sides.z) * sides.nz
				end
				local occ = id and M.room_occ[id] or (s > 0 and sides.a or sides.b)
				list[k + 12], list[k + 24], list[k + 36] = occ, occ, occ
			end
		end
		buildat.set_triangle_geometry(g.node, list)
		TRI_LISTS[g] = nil
		local cg = g.node:GetComponent("CustomGeometry")
		cg:SetMaterial(0, material)
		-- Everything in the sun's way casts its shadow but the glass, which
		-- is how daylight comes in ([FP_DAYLIGHT])
		cg.castShadows = material ~= glass_material
	end
	-- What the plan view shows where the cut goes through something: dark
	-- where it is cut, lighter for what is below the cut
	local function cap(pts, y0, y1, cut_col, low_col)
		if y0 < cut then
			local cg = geometry(P.caps)
			flat_polygon(cg, pts, math.min(y1, cut) - 3, M.UP3, y1 >= cut and
					cut_col or low_col)
			commit(cg, flat_material)
		end
	end

	-- An outline extruded between y0 and y1, its faces coloured by label
	local function extrude(g, pts, labels, y0, y1, cols, bottom)
		flat_polygon(g, pts, y1, M.UP3, cols.core)
		if bottom then
			flat_polygon(g, pts, y0, M.DOWN3, cols.core)
		end
		local function v(p, y)
			return V3(W(p[1]), W(y), W(p[2]))
		end
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local dx, dz = q[1] - p[1], q[2] - p[2]
			local l = geom.len(dx, dz)
			if l > 0.01 then
				-- Outward of a counter-clockwise outline is to the right
				local n = V3(dz / l, 0, -dx / l)
				local col = cols[labels[i]]
				tri(g, v(p, y0), v(q, y0), v(q, y1), n, col)
				tri(g, v(p, y0), v(q, y1), v(p, y1), n, col)
			end
		end
	end

	-- The openings in each wall, by where they are along it
	local holes = {}
	for id, it in pairs(inst_data) do
		if it.hosted and doc.ents[it.def].ints.kind ~= KIND.switch then
			local host = doc.ents[id].ints.host
			local p = doc.ents[it.def].ints
			holes[host] = holes[host] or {}
			table.insert(holes[host], {c = it.along, w = p.w,
					sill = doc.ents[id].ints.sill, h = p.h})
		end
	end

	-- A wall is cut along its length into slabs: whole ones between the
	-- openings, and at each opening the part below its sill and the part
	-- above its head. The faces the cuts make are the reveals.
	for id, o in pairs(outlines) do
		local w = doc.ents[id].ints
		local y0, y1 = wall_span(w)
		local cols = {
			left = row(w.mat_left),
			right = row(w.mat_right),
			core = row(w.mat_core ~= 0 and w.mat_core or w.mat_left),
		}
		local f = wall_frame(id)
		local list = holes[id] or {}
		table.sort(list, function(a, b) return a.c < b.c end)
		local slabs, prev = {}, -math.huge
		for _, h in ipairs(list) do
			local s0, e0 = h.c - h.w / 2, h.c + h.w / 2
			if s0 > prev then
				slabs[#slabs + 1] = {prev, s0}
			end
			slabs[#slabs + 1] = {math.max(s0, prev), e0, h}
			prev = math.max(prev, e0)
		end
		slabs[#slabs + 1] = {prev, math.huge}
		local d0 = f and f.ax * f.ux + f.az * f.uz or 0
		if foundation then
			local g = geometry(P.walls)
			local labels = {}
			for i = 1, #o.pts do
				labels[i] = "core"
			end
			extrude(g, o.pts, labels, -foundation.h, 0,
					{core = row(foundation.mat)}, false)
			commit(g, lit_material)
		end
		for _, sl in ipairs(slabs) do
			local pts, labels = o.pts, o.sides
			if f and sl[1] > -math.huge then
				pts, labels = geom.clip(pts, labels, -f.ux, -f.uz, -(d0 + sl[1]),
						"core")
			end
			if f and sl[2] < math.huge then
				pts, labels = geom.clip(pts, labels, f.ux, f.uz, d0 + sl[2], "core")
			end
			local parts = {{y0, y1}}
			if sl[3] then
				parts = {{y0, math.min(y1, sl[3].sill)},
						{math.max(y0, sl[3].sill + sl[3].h), y1}}
			end
			if #pts >= 3 then
				for _, part in ipairs(parts) do
					if part[2] - part[1] > 0.5 then
						local g = geometry(P.walls)
						extrude(g, pts, labels, part[1], part[2], cols, part[1] > 0)
						commit(g, lit_material)
						cap(pts, part[1], part[2], magic.Color(0.16, 0.16, 0.18),
								magic.Color(0.55, 0.55, 0.58))
						solids[#solids + 1] = {pts = pts, y0 = part[1],
								y1 = part[2]}
					end
				end
			end
		end
	end

	for id, r in pairs(room_data) do
		local e = doc.ents[id]
		-- The foundation under the floor too, where a room has no walls
		if foundation and #r.pts >= 3 then
			local g = geometry(P.walls)
			local labels = {}
			for i = 1, #r.pts do
				labels[i] = "core"
			end
			extrude(g, r.pts, labels, -foundation.h, 0,
					{core = row(foundation.mat)}, false)
			commit(g, lit_material)
		end
		if #r.pts >= 3 then
			local g = geometry(P.walls)
			r.floor = geom.minus(r.pts, wells.floor)
			for _, pts in ipairs(r.floor) do
				flat_polygon(g, pts, 2, M.UP3, row(e.ints.mat_floor))
			end
			commit(g, lit_material)
			local cg = geometry(P.overhead)
			for _, pts in ipairs(geom.minus(r.pts, wells.ceiling)) do
				flat_polygon(cg, pts, room_ceiling(e), M.DOWN3,
						row(e.ints.mat_ceiling))
			end
			commit(cg, lit_material)
			-- A slab over it for the sun's shadow alone, 300 mm thick and
			-- out past the walls: the thin wall tops and the ceiling
			-- leaked a line of daylight where they meet ([FP_DAYLIGHT])
			local offs = {}
			for i = 1, #r.pts do
				offs[i] = -300
			end
			local slab_pts = geom.inset(r.pts, offs)
			if #slab_pts >= 3 then
				local sg = geometry(P.overhead)
				local c0 = room_ceiling(e)
				local labels = {}
				for i = 1, #slab_pts do
					labels[i] = "core"
				end
				extrude(sg, slab_pts, labels, c0, c0 + 300, {core = 0}, true)
				commit(sg, M.shadow_material)
			end
		end
	end

	local occ_fn = M.tri_occ_fn
	M.tri_occ_fn = nil
	for id, it in pairs(inst_data) do
		local def = doc.ents[it.def].ints
		local e = doc.ents[id].ints
		local occ, a, b = M.inst_occlusion(it)
		M.tri_occ = occ
		-- A door's or a window's faces each their own room (commit):
		-- the darker one's was black on the lit side of a door to a room
		-- with no window and its lamp off
		M.tri_sides = a and {a = a, b = b, nx = it.frame.nx, nz = it.frame.nz,
				x = it.x, z = it.z}
		if it.hosted then
			build_hosted(id, it, def, e, geometry, commit)
			-- A window and a shut door are in the way; an open door is not
			-- simplified: the opening, not the leaf where it has swung to
			if def.kind == KIND.window or (def.kind == KIND.door and
					open_amount(id) < 300) then
				solids[#solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
			end
		elseif def.kind == KIND.box then
			local g, node = geometry(e.align == 1 and P.overhead or P.walls)
			node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
			node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
			local rgb = palette_rgb(def.mat)
			box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(def.d) / 2,
					row(def.mat), nil, nil, nil, not lamp_on(id) and UNLIT or nil)
			commit(g, lit_material)
			cap(it.foot, it.y0, it.y1, rgb_color(rgb, 0.7), rgb_color(rgb, 0.9))
			solids[#solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
		elseif def.kind == KIND.stairs then
			-- A box a step, and a solid a step to walk up
			local g, node = geometry(e.align == 1 and P.overhead or P.walls)
			node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
			node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
			local rgb = palette_rgb(def.mat)
			local flat = it.pitch % 360 == 0 and it.roll % 360 == 0
			for _, b in ipairs(geom.stair_steps(def.w, def.h, def.d, def.steps)) do
				box_geometry(g, W(b[4] - b[1]) / 2, W(b[5] - b[2]) / 2,
						W(b[6] - b[3]) / 2, row(def.mat), W(b[1] + b[4]) / 2,
						W(b[2] + b[5]) / 2, W(b[3] + b[6]) / 2)
				-- simplified: stairs pitched or rolled are walked as their box
				if flat then
					local pts = {}
					for k, c in ipairs({{b[1], b[3]}, {b[4], b[3]}, {b[4], b[6]},
							{b[1], b[6]}}) do
						local px, _, pz = geom.rot(c[1], 0, c[2], 0, it.yaw, 0)
						pts[k] = {it.x + px, it.z + pz}
					end
					if not geom.is_ccw(pts) then
						pts = {pts[4], pts[3], pts[2], pts[1]}
					end
					solids[#solids + 1] = {pts = pts, y0 = it.y + b[2],
							y1 = it.y + b[5]}
					-- A cap a step, inside it: one over the whole footprint
					-- floated over the low steps, the caps being drawn in 3D too
					cap(pts, it.y + b[2], it.y + b[5], rgb_color(rgb, 0.7),
							rgb_color(rgb, 0.9))
				end
			end
			commit(g, lit_material)
			if not flat then
				solids[#solids + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
			end
		end
	end
	M.tri_occ, M.tri_occ_fn, M.tri_sides = 0, occ_fn, nil
	-- A floor is something to stand on, when walking up to another layout
	for _, r in pairs(room_data) do
		for _, pts in ipairs(r.floor or {}) do
			solids[#solids + 1] = {pts = pts, y0 = 0, y1 = 0, floor = true}
		end
	end
	update_voxel_meshes(seen_voxels)
	build_lamps(geometry)
	-- The pictures traced over and the material ids are the current
	-- layout's; seen from above another's are clutter
	image_data = {}
	if S.view_layout == S.layout then
		build_images()
		build_decals()
	end
end

-- The layouts' own inst_data and where each is, for the walker's voxels:
-- {{insts, rel}, ...}
place.layers = {}

-- simplified: every layout is rebuilt on any change
rebuild = function()
	M.build_gen = M.build_gen + 1
	palette_texture()
	M.build_ground()
	for _, n in ipairs(built) do
		n:Remove()
	end
	built = {}
	local cur = place.current()
	local order = {}
	for _, l in ipairs(doc.of_type("layout")) do
		if l.id ~= S.layout then
			order[#order + 1] = l
		end
	end
	-- The current one last, so what the tools read is its
	if S.layout then
		order[#order + 1] = doc.ents[S.layout]
	end
	local seen_voxels, all_solids = {}, {}
	place.layers = {}
	M.room_light, M.room_seen = {}, {}
	-- Which layouts are above the current one, for S.hide_above; what is
	-- built new is shown, so the hiding is done again
	place.above, place.shown = {}, {}
	local wells = place.stairwells(order, cur)
	-- Each building's lowest floor, which a foundation goes under
	local lowest = {}
	for _, l in ipairs(order) do
		local g = l.strs.group
		lowest[g] = math.min(lowest[g] or math.huge, l.ints.y)
	end
	for _, l in ipairs(order) do
		local r = place.rel(l.ints, cur)
		local parts = place.parts[l.id]
		if not parts then
			parts = {}
			for k, n in pairs({walls = walls_node, caps = caps_node,
					overhead = overhead_node, pieces = pieces_node,
					images = images_node, decals = decals_node,
					lamps = lamps_node}) do
				parts[k] = n:CreateChild("layout")
			end
			place.parts[l.id] = parts
		end
		for _, n in pairs(parts) do
			n.position = magic.Vector3(W(r.x), W(r.y), W(r.z))
			n.rotation = magic.Quaternion(0, r.yaw, 0)
		end
		place.above[l.id] = r.y > 0
		P, S.view_layout = parts, l.id
		M.cur_rel = r
		foundation = l.ints.y > 0 and l.ints.y == lowest[l.strs.group] and
				{h = l.ints.y, mat = l.ints.mat_foundation} or nil
		build_layout(seen_voxels, wells[l.id])
		foundation = nil
		for _, sd in ipairs(solids) do
			local pts = {}
			for k, q in ipairs(sd.pts) do
				local x, _, z = place.point(r, q[1], 0, q[2])
				pts[k] = {x, z}
			end
			all_solids[#all_solids + 1] = {pts = pts, y0 = sd.y0 + r.y,
					y1 = sd.y1 + r.y, floor = sd.floor}
		end
		place.layers[#place.layers + 1] = {id = l.id, insts = inst_data, rel = r,
				rooms = room_data}
	end
	solids = all_solids
	-- The slots of rooms that are gone
	for id, slot in pairs(M.room_slot) do
		if not M.room_seen[id] then
			M.room_slot[id], M.slot_owner[slot] = nil, nil
			M.free_rows(slot)
		end
	end
	for id, m in pairs(voxel_meshes) do
		if not seen_voxels[id] then
			m.node:Remove()
			voxel_meshes[id] = nil
		end
	end
	for id, parts in pairs(place.parts) do
		local e = doc.ents[id]
		if not e or e.type ~= "layout" then
			for _, n in pairs(parts) do
				n:Remove()
			end
			place.parts[id] = nil
		end
	end
	-- The ground is the world's, under every layout
	ground_node.position = magic.Vector3(0, W(-cur.y), 0)
	pieces_node.enabled = S.view ~= "2d"
	caps_node.enabled = S.view == "2d"
	S.daylight_key = nil
	S.dirty = false
end
end

-- **The plan's daylight** on the 3D view and walking ([FP_DAYLIGHT],
-- daylight.lua): the sun where the plan's place and hour put it, at its
-- irradiance and colour, the sky's ambient and fog, the sky drawn and its
-- cube reflected; or, unlit and in the plan view, the plain look. Each
-- frame, recomputed when the minute (to a tenth), the settings or the
-- mode change.
M.UNLIT = {ambient = magic.Color(0.55, 0.55, 0.58),
		fog = magic.Color(0.55, 0.62, 0.72)}
-- **The moment's settings, saved or this client's** (user, 2026-09-30):
-- the date, the hour, the time-lapse and the ground as the plan has them
-- ("Saved"), or a copy of them this client changes for its own view and
-- sends nowhere ("Temporary", S.sun_temp, for the plan it was made in),
-- which a viewer may change too
function M.sun()
	local t = S.sun_temp
	local base = (t and t.plan == doc.plan_name) and t or settings()
	-- A viewport that recalls its moment: its day and minute, still
	local vp = S.vp and doc.ents[S.vp]
	if vp and vp.ints.recall == 1 then
		local t2 = {}
		for k, v in pairs(base) do
			t2[k] = v
		end
		t2.day, t2.minute, t2.lapse = vp.ints.day, vp.ints.minute, 0
		return t2
	end
	return base
end
-- The plan's minute now: its own, or on from it at the time-lapse's
-- speed since this client saw it set
-- simplified: from when this client saw it, so two clients that joined
-- apart see a time-lapse apart; the upgrade is the server's clock
function M.plan_minute()
	local st = M.sun()
	-- Real time (user): each viewer's own wall clock, as the solar hour
	-- simplified: the clock's hour, not the sun's at the plan's longitude
	-- (the plan has none) and with summer time in it
	if st.lapse < 0 then
		local _, h, m, sec = buildat.get_local_time()
		return h * 60 + m + sec / 60
	end
	local key = st.minute .. ":" .. st.lapse
	if S.lapse_key ~= key then
		S.lapse_key, S.lapse_t0 = key, buildat.get_time_us()
	end
	if st.lapse == 0 then
		return st.minute
	end
	return (st.minute + st.lapse * (buildat.get_time_us() - S.lapse_t0) / 1e6) % 1440
end
-- The plan's day of the year now: its own, or the viewer's calendar's
-- under "real date and time"
function M.plan_day()
	local st = M.sun()
	if st.lapse == -2 then
		return math.min(365, (buildat.get_local_time()))
	end
	return st.day
end
-- The ground's colour now, as the palette's row and the light's albedo
function M.ground_rgb()
	local st = settings()
	return M.daylight.ground(st.latitude, M.plan_day(), M.sun().ground)
end
-- Whether what is drawn now is PBR: the setting's, and never the plan view
function M.pbr_now()
	return S.lighting ~= "unlit" and S.view ~= "2d"
end
function M.apply_daylight()
	local pbr = M.pbr_now()
	local st = settings()
	local minute = pbr and M.plan_minute() or 0
	local day = M.plan_day()
	-- The trees' foot is the ground's, which moves with the floor edited,
	-- and the ground's disc is under the camera
	if M.sky then
		local y = ground_node.position.y
		M.sky.material:SetShaderParameter("TreeGround", y)
		if pbr then
			ground_node.position = magic.Vector3(S.pos.x, y, S.pos.z)
		end
	end
	local key = string.format("%s %.1f %d %d %d %d %d", tostring(pbr), minute,
			st.north, st.latitude, day, M.sun().ground, st.treeline)
	if key == S.daylight_key then
		if pbr and M.sky then
			M.sky:flush()
		end
		return
	end
	S.daylight_key = key
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetShaderParameter("Pbr", pbr and 1 or 0)
	end
	if not pbr then
		sun.enabled, fill.enabled = false, true
		zone.ambientColor, zone.fogColor = M.UNLIT.ambient, M.UNLIT.fog
		if M.sky then
			M.sky:show(false)
		end
		return
	end
	M.sky = M.sky or M.daylight.new_sky(scene)
	M.sky:show(true)
	zone.zoneTexture = M.sky.texture
	local tx, h, tz = M.daylight.sun_toward(st.latitude, st.north, day, minute)
	local rgb = M.ground_rgb()
	local function lin(v)
		return (v / 255) ^ 2.2
	end
	local light = M.daylight.light(h, {r = lin(math.floor(rgb / 65536)),
			g = lin(math.floor(rgb / 256) % 256), b = lin(rgb % 256)})
	sun.enabled, fill.enabled = h > 0, false
	sun_node.direction = magic.Vector3(-tx, -h, -tz)
	-- The shader's Lambert has no 1/pi, which the irradiance carries here
	sun.brightness = light.sun / math.pi
	local sc = light.sun_color
	sun.color = magic.Color(sc.r, sc.g, sc.b)
	local a, f = light.ambient, light.horizon
	-- The white outdoors (M.wb_tick): a grey card's light, a quarter of
	-- the sun's irradiance over its sphere and half of the sky's
	M.wb_outdoor = {r = sc.r * light.sun / 4 / math.pi + a.r / 2,
			g = sc.g * light.sun / 4 / math.pi + a.g / 2,
			b = sc.b * light.sun / 4 / math.pi + a.b / 2}
	zone.ambientColor = magic.Color(a.r, a.g, a.b)
	zone.fogColor = magic.Color(f.r, f.g, f.b)
	M.sky.material:SetShaderParameter("Treeline", st.treeline / 1000)
	M.room_bounce(tx, h, tz, light)
	M.sky:set(tx, h, tz, h, light)
	-- A changed treeline is in the reflections at once, not when the sun
	-- next moves
	if M.sky.treeline ~= st.treeline then
		M.sky.treeline = st.treeline
		M.sky.cube:update()
	end
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetShaderParameter("SunToward", magic.Vector3(tx, h, tz))
	end
end

--
-- Screen and plan
--
local function screen_size()
	return magic.graphics.width, magic.graphics.height
end

-- **A field of view is of the screen's short side** (user, the sixth
-- round): the camera's is vertical, which on a portrait screen left a
-- slot. The degrees are the narrower of width and height; set each frame,
-- so a turned phone follows.
function M.fov_for(deg)
	local w, h = screen_size()
	if h <= w or w <= 0 then
		return deg
	end
	return math.deg(2 * math.atan(math.tan(math.rad(deg) / 2) * h / w))
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
		return M.px(SNAP_PX) * mm_per_px()
	end
	local x, z = cursor_floor()
	if not x then
		return 100
	end
	local dist = geom.len(x / 1000 - S.pos.x, z / 1000 - S.pos.z)
	dist = math.sqrt(dist * dist + S.pos.y * S.pos.y)
	local _, h = screen_size()
	return M.px(SNAP_PX) * dist * 1000 * 2 * math.tan(math.rad(cam3d.fov) / 2) / h
end



local function angle_step()
	return ANGLE_STEPS[S.angle] or 1
end

-- The node nearest to (x, z) within r, skipping those in `except`
local function nearest_node(x, z, r, except)
	local best, bd = nil, r
	for _, n in ipairs(of_type("node")) do
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
-- Whether a point on a wall (mm) is in one of its openings, doors or
-- windows: the wall is not there, whatever its outline says
local function in_hole(wall, x, y, z)
	for id, it in pairs(inst_data) do
		if it.hosted and doc.ents[id].ints.host == wall then
			local def = doc.ents[it.def].ints
			if def.kind ~= KIND.switch then
				local f = it.frame
				local along = (x - f.ax) * f.ux + (z - f.az) * f.uz
				local sill = doc.ents[id].ints.sill
				if math.abs(along - it.along) < def.w / 2 and y > sill and
						y < sill + def.h then
					return true
				end
			end
		end
	end
	return false
end

-- How far into an opening's edge its trim and frame stay pickable, mm
local HOLE_MARGIN = 40

-- id: the instance, for an opening or an open door: a ray through the hole
-- in the wall misses it and goes on to what is seen through it
-- A ray against a box from lo to hi, in the box's frame: where it enters,
-- or nil. These are on M: this file is at Lua's 200 locals.
function M.ray_box(ox, oy, oz, dx, dy, dz, lo, hi)
	local tmin, tmax = 0, math.huge
	for a, v in ipairs({{ox, dx}, {oy, dy}, {oz, dz}}) do
		if math.abs(v[2]) < 1e-12 then
			if v[1] < lo[a] or v[1] > hi[a] then
				return nil
			end
		else
			local t1, t2 = (lo[a] - v[1]) / v[2], (hi[a] - v[1]) / v[2]
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

-- Where the ray meets one of a door's or a window's leaves first, or nil
function M.ray_leaves(it, o, d)
	local best = nil
	for _, lf in ipairs(it.leaves or {}) do
		local ox, oy, oz = geom.unrot(o.x - lf.x, o.y, o.z - lf.z, 0, lf.yaw, 0)
		local dx, dy, dz = geom.unrot(d.x, d.y, d.z, 0, lf.yaw, 0)
		local t = M.ray_box(ox, oy, oz, dx, dy, dz, lf.lo, lf.hi)
		if t and (not best or t < best) then
			best = t
		end
	end
	return best
end

-- The ray against an instance: where it enters, and "leaf" when that is a
-- door's or a window's leaf, which is outside the box once it swings
local function ray_instance(it, o, d, id)
	local leaf_t = it.hosted and M.ray_leaves(it, o, d)
	local t = M.ray_instance_box(it, o, d, id)
	-- A shut leaf is inside the frame's box, a little behind where the
	-- ray enters it: a leaf hit within a wall's depth of that is the leaf
	if leaf_t and (not t or leaf_t <= t + 0.4) then
		return leaf_t, "leaf"
	end
	return t
end

function M.ray_instance_box(it, o, d, id)
	local ox, oy, oz = geom.unrot(o.x - W(it.x), o.y - W(it.y), o.z - W(it.z),
			it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	local tmin, tmax = 0, math.huge
	for _, a in ipairs({{ox, dx, W(it.hx)}, {oy, dy, W(it.hy)},
			{oz, dz, W(it.hz)}}) do
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
	local def = it.hosted and id and doc.ents[it.def].ints
	if def and (def.kind == KIND.opening or (def.kind == KIND.door and
			open_amount(id) > 0)) then
		-- Where the ray enters, in mm about the opening's middle: inside
		-- the hole less the margin is the hole; a door's hole goes down to
		-- the floor
		local lx = (ox + dx * tmin) * 1000
		local ly = (oy + dy * tmin) * 1000
		local hw, hh = def.w / 2 - HOLE_MARGIN, def.h / 2 - HOLE_MARGIN
		local floor = doc.ents[id].ints.sill == 0
		if math.abs(lx) < hw and ly < hh and (ly > -hh or floor) then
			return nil
		end
	end
	return tmin
end

-- What is under the cursor for painting and selecting: an instance, a
-- wall and which of its faces, or a room's floor or ceiling.
-- {kind = "instance"|"wall"|"floor"|"ceiling", id, side}
-- whole: an opening's hole is the opening's too, as the use key wants it
-- -- an open door is closed by pointing through it
local function pick_surface(whole)
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
				return {kind = "wall", id = id, side = side, x = x, z = z}
			end
		end
		for id, im in pairs(image_data) do
			if not im.locked and geom.point_in_polygon(x, z, im.foot) then
				return {kind = "image", id = id}
			end
		end
		local r = room_at(x, z)
		return r and {kind = "floor", id = r} or nil
	end
	local o, d = cursor_ray()
	local best, best_t = nil, math.huge
	-- What hangs from the ceiling is drawn from above too, so it is
	-- picked from above too
	for id, it in pairs(inst_data) do
		local t, part = ray_instance(it, o, d, not whole and id or nil)
		if t and t < best_t then
			-- A leaf is the door's leaf part, which a click selects
			best, best_t = {kind = "instance", id = id,
					side = part == "leaf" and "mat_leaf" or nil}, t
		end
	end
	for id, ol in pairs(outlines) do
		-- (an outline outlives its wall for the frame a plan is left in)
		local we = doc.ents[id]
		local y0, y1 = 0, 0
		if we then
			y0, y1 = wall_span(we.ints)
		end
		y0, y1 = W(y0), W(y1)
		local pts = we and ol.pts or {}
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
					if dist < 1e-4 and hy >= y0 and hy <= y1 and
							not in_hole(id, hx * 1000, hy * 1000, hz * 1000) then
						best, best_t = {kind = "wall", id = id,
								side = ol.sides[i], x = hx * 1000, z = hz * 1000}, t
					end
				end
			end
		end
		local hx, hz, t = ray_at_height(y1 * 1000)
		if hx and t < best_t and geom.point_in_polygon(hx, hz, pts) then
			best, best_t = {kind = "wall", id = id, side = "core", x = hx,
					z = hz}, t
		end
	end
	for id, r in pairs(room_data) do
		local surfaces = {{"floor", 2}}
		-- (the 3D pick: best_t is how far along the ray it is)
		-- A ceiling faces down and is seen only from under it
		if d.y > 0 then
			surfaces[2] = {"ceiling", room_ceiling(doc.ents[id])}
		end
		for _, s in ipairs(surfaces) do
			local hx, hz, t = ray_at_height(s[2])
			if hx and t < best_t and geom.point_in_polygon(hx, hz, r.pts) then
				best, best_t = {kind = s[1], id = id}, t
			end
		end
	end
	if best then
		best.t = best_t
	end
	return best
end

-- The cell of a volume under the cursor: the first voxel the ray enters
-- and the cell it came from, in the volume's own cells. With no voxel on
-- the way, the cell on the floor where the ray meets it, as the place.
local function voxel_ray(id)
	local it = inst_data[id]
	local o, d = cursor_ray()
	local sz = it.size
	local ox, oy, oz = geom.unrot((o.x - W(it.ox)) * 1000, (o.y - W(it.oy)) * 1000,
			(o.z - W(it.oz)) * 1000, it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	ox, oy, oz = ox / sz, oy / sz, oz / sz
	local vox = doc.voxels[doc.ents[id].ints.def] or {}
	-- Amanatides and Woo: from cell to cell along the ray
	local cell = {math.floor(ox), math.floor(oy), math.floor(oz)}
	local pos, dir = {ox, oy, oz}, {dx, dy, dz}
	local stepv, tmax, tdelta = {}, {}, {}
	for a = 1, 3 do
		if dir[a] > 0 then
			stepv[a] = 1
			tmax[a] = (cell[a] + 1 - pos[a]) / dir[a]
			tdelta[a] = 1 / dir[a]
		elseif dir[a] < 0 then
			stepv[a] = -1
			tmax[a] = (pos[a] - cell[a]) / -dir[a]
			tdelta[a] = -1 / dir[a]
		else
			stepv[a], tmax[a], tdelta[a] = 0, math.huge, math.huge
		end
	end
	local prev = nil
	for _ = 1, 600 do
		local inside = true
		for a = 1, 3 do
			inside = inside and cell[a] >= -128 and cell[a] <= 127
		end
		if inside and vox[doc.voxel_key(cell[1], cell[2], cell[3])] then
			return {cell[1], cell[2], cell[3]}, prev
		end
		prev = {cell[1], cell[2], cell[3]}
		local a = 1
		if tmax[2] < tmax[a] then a = 2 end
		if tmax[3] < tmax[a] then a = 3 end
		cell[a] = cell[a] + stepv[a]
		tmax[a] = tmax[a] + tdelta[a]
	end
	local x, z = cursor_floor()
	if not x then
		return nil
	end
	local lx, ly, lz = geom.unrot(x - it.ox, 1 - it.oy, z - it.oz, it.pitch,
			it.yaw, it.roll)
	return nil, {math.floor(lx / sz), math.floor(ly / sz), math.floor(lz / sz)}
end

-- **Imaginary cells past the volume** (user): the cell where the pointer's
-- ray meets the plane through cell `a` that faces the view most -- of the
-- volume's three axes, the one nearest the view's direction -- so a box
-- held on past the voxels goes on as a sheet in that plane. nil when the
-- ray runs along the plane or away from it.
function M.voxel_plane_cell(id, a)
	local it = inst_data[id]
	if not it then
		return nil
	end
	local o, d = cursor_ray()
	local sz = it.size
	local ox, oy, oz = geom.unrot((o.x - W(it.ox)) * 1000, (o.y - W(it.oy)) * 1000,
			(o.z - W(it.oz)) * 1000, it.pitch, it.yaw, it.roll)
	local dx, dy, dz = geom.unrot(d.x, d.y, d.z, it.pitch, it.yaw, it.roll)
	local p, v = {ox / sz, oy / sz, oz / sz}, {dx, dy, dz}
	-- The camera's own forward, for which plane faces it
	local f = {geom.rot(0, 0, 1, S.pitch, S.yaw, 0)}
	f = {geom.unrot(f[1], f[2], f[3], it.pitch, it.yaw, it.roll)}
	local ax = 1
	for k = 2, 3 do
		if math.abs(f[k]) > math.abs(f[ax]) then
			ax = k
		end
	end
	if math.abs(v[ax]) < 1e-6 then
		return nil
	end
	local t = (a[ax] + 0.5 - p[ax]) / v[ax]
	if t <= 0 then
		return nil
	end
	local c = {}
	for k = 1, 3 do
		c[k] = k == ax and a[ax] or math.floor(p[k] + v[k] * t)
	end
	for k = 1, 3 do
		if c[k] < -128 or c[k] > 127 then
			return nil
		end
	end
	return c
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
		-- Right angles, or with Shift or the touch bar's Angle the angle
		-- step, which may be free
		local step = 90
		if S.shift or S.touch_angle then
			step = ANGLE_STEPS[S.angle] or nil
		end
		local ex, ez = geom.snap_direction(from.x, from.z, x, z, step,
				grid_step())
		return math.floor(ex + 0.5), math.floor(ez + 0.5), {}
	end
	return geom.snap(x, grid_step()), geom.snap(z, grid_step()), {}
end

-- **A dragged node straightens its walls** (user): for each wall joined to
-- it, lines out of the wall's other end at every multiple of the angle
-- step (90 degrees when the angle is free). The pointer within a degree of
-- one -- or within the snap radius of it, which a short wall needs -- puts
-- the node on it, the wall's length snapped to the grid; near two walls'
-- lines, where they cross, both straight. Before the grid and after nodes
-- and edges; Ctrl gives it up. `ends`: the other ends, {{x, z}, ...}.
-- Returns x, z and the lines it used ({p = {x, z}, ux, uz}), or nil.
function M.angle_snap(x, z, ends)
	if S.ctrl or #ends == 0 then
		return nil
	end
	local step = ANGLE_STEPS[S.angle] or 90
	local r = snap_radius()
	local g = grid_step()
	local tol = math.tan(math.rad(1))
	local cands = {}
	for _, p in ipairs(ends) do
		local dx, dz = x - p[1], z - p[2]
		local l = geom.len(dx, dz)
		if l > 1 then
			local a = math.rad(math.floor(math.deg(math.atan2(dz, dx)) / step + 0.5) *
					step)
			local ux, uz = math.cos(a), math.sin(a)
			local t = dx * ux + dz * uz
			local perp = math.abs(dx * uz - dz * ux)
			local cap = math.max(t * tol, r)
			if t > 0 and perp <= cap then
				cands[#cands + 1] = {p = p, ux = ux, uz = uz, t = t, perp = perp,
						cap = cap}
			end
		end
	end
	if #cands == 0 then
		return nil
	end
	-- Two lines of different walls: where they cross, the nearest crossing
	-- the pointer is in both captures of
	local best, bd = nil, math.huge
	for i = 1, #cands do
		for j = i + 1, #cands do
			local a, b = cands[i], cands[j]
			local den = a.ux * b.uz - a.uz * b.ux
			if (a.p[1] ~= b.p[1] or a.p[2] ~= b.p[2]) and math.abs(den) > 1e-6 then
				local s = ((b.p[1] - a.p[1]) * b.uz - (b.p[2] - a.p[2]) * b.ux) / den
				local cx, cz = a.p[1] + a.ux * s, a.p[2] + a.uz * s
				local d = geom.len(cx - x, cz - z)
				if s > 0 and d <= math.min(a.cap, b.cap) and d < bd then
					best, bd = {cx, cz, a, b}, d
				end
			end
		end
	end
	if best then
		return math.floor(best[1] + 0.5), math.floor(best[2] + 0.5),
				{best[3], best[4]}
	end
	-- One line: on it, at a length of whole grid steps
	table.sort(cands, function(a, b) return a.perp < b.perp end)
	local c = cands[1]
	local t = math.max(g, geom.snap(c.t, g))
	return math.floor(c.p[1] + c.ux * t + 0.5), math.floor(c.p[2] + c.uz * t + 0.5),
			{c}
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

local real_id, send, default_material, add_wall, add_room, add_box, voxel_target, voxel_column
local voxel_edit, add_hosted, copy_selected, unlink, merge_ops, delete_selected, moved_by, apply_material, rotate_selection
do
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

	real_id = function(id)
		if id and id < 0 then
			return S.real[id]
		end
		return id
	end

	send = function(ops, done)
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
			local half = doc.placeholder()
			add_op(b, "create", {id = half, type = "wall", ints = f})
			-- What is in the wall past the split goes with the second half
			for _, inst in ipairs(of_type("instance")) do
				if inst.ints.host == e.wall and inst.ints.along > ref.t then
					add_op(b, "set", {id = inst.id, ints = {host = half,
							along = inst.ints.along - ref.t}})
				end
			end
			b.pairs[pair_key(w.a, ph)] = true
			b.pairs[pair_key(ph, w.b)] = true
		end
		for _, room in ipairs(of_type("room")) do
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

	default_material = function()
		if S.material and doc.ents[S.material] then
			return S.material
		end
		local p = of_type("palette")[1]
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
		local ph = doc.placeholder()
		add_op(b, "create", {id = ph, type = "wall", ints = {
				a = a, b = bnode, thickness = S.thickness, justify = S.justify,
				height = S.height, hang = S.hang,
				mat_left = face_material(mx + nx * d, mz + nz * d),
				mat_right = face_material(mx - nx * d, mz - nz * d)}})
		return ph
	end

	-- **What was put in is what is selected**, as a door already was: its
	-- panel is then its own, and an edit there goes to Select (user)
	local function select_placed(ph, kind)
		return function(err)
			if err == "" and S.real[ph] then
				S.sel, S.sel_face = {[S.real[ph]] = kind}, {}
				S.primary = S.real[ph]
				M.refresh_panels()
			end
		end
	end

	-- **A node put into an edge** (user: a room drawn with three corners
	-- made four): the wall on it split and every room along it given the
	-- corner, as a wall drawn from there does, and the node selected to be
	-- dragged. Returns whether it did.
	function M.insert_node(x, z, ref)
		if not (ref and ref.edge) then
			return false
		end
		local b = new_batch()
		local ph = node_for(b, x, z, ref)
		if not ph then
			return false
		end
		send(finish_batch(b), function(err)
			if err == "" and S.real[ph] then
				S.nodes = {[S.real[ph]] = true}
				M.refresh_panels()
			end
		end)
		return true
	end

	add_wall = function(from, x, z, ref)
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
		local ph = wall_op(b, a, from.x, from.z, bn, x, z)
		send(finish_batch(b), select_placed(ph, "wall"))
		-- The chain goes on from the end, which is now a node
		S.draw = {x = x, z = z, ref = {node = bn}}
		return true
	end

	-- The room tool's corners, as a room and (if asked) walls on its edges
	add_room = function(corners)
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
				(#of_type("room") + 1)}, lists = {nodes = ids}})
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
		-- The lamp at the middle, when the middle is in the room (not
		-- always so for an L)
		if S.room_lamp then
			local pts = {}
			for i, c in ipairs(corners) do
				pts[i] = {c.x, c.z}
			end
			local cx, cz = geom.centroid(pts)
			if geom.point_in_polygon(cx, cz, pts) then
				M.plafond_ops(b.ops, cx, cz)
			end
		end
		local selected = select_placed(ph, "room")
		send(finish_batch(b), function(err)
			selected(err)
			-- The 3D view, while it is not looked at, above the new room and
			-- looking down at it (user: it began where nothing was)
			if err == "" and S.view == "2d" then
				M.look_at_corners(corners)
			end
		end)
	end

	-- The 3D camera south of the points' middle and above, looking down at
	-- 60 degrees from far enough to see them all
	function M.look_at_corners(corners)
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		for _, c in ipairs(corners) do
			x0, z0 = math.min(x0, c.x), math.min(z0, c.z)
			x1, z1 = math.max(x1, c.x), math.max(z1, c.z)
		end
		local size = W(math.max(x1 - x0, z1 - z0, 1000))
		local dist = size / (2 * math.tan(math.rad(cam3d.fov) / 2)) * 2 + 1
		S.yaw, S.pitch = 0, 60
		local fx, fy, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
		S.pos = {x = W((x0 + x1) / 2) - fx * dist, y = W(1200) - fy * dist,
				z = W((z0 + z1) / 2) - fz * dist}
	end

	-- **Splitting a room and combining two** ([FP_ROOM_SPLIT], user
	-- 2026-10-01), by two corners: a room is a list of nodes, and the walls
	-- and what is in them are their own and stay as they are. A corner may
	-- also be a node on one of the room's edges, which the room then gets.

	-- Where node n is in a room's list: its index, or the edge it lies on
	-- (after which it would go), or nil
	local function room_place(list, n)
		for i, m in ipairs(list) do
			if m == n then
				return i, false
			end
		end
		local ne = doc.ents[n]
		if not ne then
			return nil
		end
		for i = 1, #list do
			local u, v = doc.ents[list[i]], doc.ents[list[i % #list + 1]]
			if u and v then
				local _, _, t, d = geom.nearest_on_segment(ne.ints.x, ne.ints.z,
						u.ints.x, u.ints.z, v.ints.x, v.ints.z)
				if d < 2 and t > 0 and t < 1 then
					return i, true
				end
			end
		end
		return nil
	end

	-- The room's list with a and b in it, and their indices; nil when a
	-- corner is not the room's
	local function with_corners(room, a, b)
		local list = {}
		for i, n in ipairs(room.lists.nodes) do
			list[i] = n
		end
		for _, n in ipairs({a, b}) do
			local i, edge = room_place(list, n)
			if not i then
				return nil
			end
			if edge then
				table.insert(list, i + 1, n)
			end
		end
		local ia, ib
		for i, n in ipairs(list) do
			if n == a then ia = i end
			if n == b then ib = i end
		end
		return list, ia, ib
	end

	-- list[from], list[from + 1], ... list[to], round the end
	local function arc(list, from, to)
		local out, i = {}, from
		while true do
			out[#out + 1] = list[i]
			if i == to then
				return out
			end
			i = i % #list + 1
		end
	end

	local function pts_of(ids)
		local pts = {}
		for i, n in ipairs(ids) do
			local e = doc.ents[n].ints
			pts[i] = {e.x, e.z}
		end
		return pts
	end

	-- Whether segments p-q and r-s cross other than at their ends
	local function crosses(p, q, r, s2)
		local function side(a, b, c)
			return (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1])
		end
		local d1, d2 = side(p, q, r), side(p, q, s2)
		local d3, d4 = side(r, s2, p), side(r, s2, q)
		return d1 * d2 < 0 and d3 * d4 < 0
	end

	-- The room split along a-b: nil and why, or the two lists
	function M.split_lists(room, a, b)
		local list, ia, ib = with_corners(room, a, b)
		if not list then
			return nil, "Both corners must be on the room"
		end
		local n = #list
		if ia % n + 1 == ib or ib % n + 1 == ia then
			return nil, "Those corners are the ends of one edge"
		end
		local pts = pts_of(list)
		local pa, pb = pts[ia], pts[ib]
		local mid = {(pa[1] + pb[1]) / 2, (pa[2] + pb[2]) / 2}
		if not geom.point_in_polygon(mid[1], mid[2], pts) then
			return nil, "The line between the corners goes outside the room"
		end
		for i = 1, n do
			if crosses(pa, pb, pts[i], pts[i % n + 1]) then
				return nil, "The line between the corners crosses the room's edge"
			end
		end
		return arc(list, ia, ib), arc(list, ib, ia)
	end

	function M.split_room(id, a, b)
		local room = doc.ents[id]
		local l1, l2 = M.split_lists(room, a, b)
		if not l1 then
			doc.notice(l2)
			return
		end
		-- The bigger keeps the room; the other is a copy of its settings
		if math.abs(geom.area(pts_of(l1))) < math.abs(geom.area(pts_of(l2))) then
			l1, l2 = l2, l1
		end
		local bt = new_batch()
		add_op(bt, "set", {id = id, lists = {nodes = l1}})
		local ph = doc.placeholder()
		local ints = {}
		for k, v in pairs(room.ints) do
			ints[k] = v
		end
		add_op(bt, "create", {id = ph, type = "room", ints = ints,
				strs = {name = room.strs.name .. " 2"}, lists = {nodes = l2}})
		-- A wall on the new edge, as a drawn room gets them
		if S.room_walls and not wall_between(a, b) then
			local ea, eb = doc.ents[a].ints, doc.ents[b].ints
			wall_op(bt, a, ea.x, ea.z, b, eb.x, eb.z)
		end
		send(bt.ops, function(err)
			if err == "" then
				doc.notice("Split " .. room.strs.name .. " in two")
			end
		end)
	end

	-- Rooms ra and rb joined through the edge from a to b that they share:
	-- nil and why, or the joined list
	function M.combine_list(ra, rb, a, b)
		local la, ia, ib = with_corners(ra, a, b)
		local lb, ja, jb = with_corners(rb, a, b)
		if not la or not lb then
			return nil, "Both corners must be on both rooms"
		end
		local want = math.abs(geom.area(pts_of(la))) +
				math.abs(geom.area(pts_of(lb)))
		-- Each room's way from b to a that is not the shared edge, and the
		-- other's from a to b: the one of the four whose area is the two's
		for _, pa in ipairs({arc(la, ib, ia), arc(la, ia, ib)}) do
			if pa[1] ~= b then
				local r = {}
				for i = #pa, 1, -1 do r[#r + 1] = pa[i] end
				pa = r
			end
			for _, pb in ipairs({arc(lb, ja, jb), arc(lb, jb, ja)}) do
				if pb[1] ~= a then
					local r = {}
					for i = #pb, 1, -1 do r[#r + 1] = pb[i] end
					pb = r
				end
				local out = {}
				for i = 1, #pa - 1 do out[#out + 1] = pa[i] end
				for i = 1, #pb - 1 do out[#out + 1] = pb[i] end
				if #out >= 3 and math.abs(math.abs(geom.area(pts_of(out))) -
						want) <= 0.001 * want + 1 then
					return out
				end
			end
		end
		return nil, "Those corners are not an edge the two rooms share"
	end

	function M.combine_rooms(ida, idb, a, b)
		local ra, rb = doc.ents[ida], doc.ents[idb]
		local list, why = M.combine_list(ra, rb, a, b)
		if not list then
			doc.notice(why)
			return
		end
		-- The bigger's settings and name
		if math.abs(geom.area(pts_of(ra.lists.nodes))) <
				math.abs(geom.area(pts_of(rb.lists.nodes))) then
			ida, idb, ra, rb = idb, ida, rb, ra
		end
		local bt = new_batch()
		add_op(bt, "set", {id = ida, lists = {nodes = list}})
		add_op(bt, "delete", {id = idb})
		send(bt.ops, select_placed(ida, "room"))
		doc.notice("Joined " .. rb.strs.name .. " into " .. ra.strs.name)
	end

	-- What two selected corners can do to the rooms: {{text, fn}, ...}
	function M.room_actions(a, b)
		local out, both = {}, {}
		for _, r in ipairs(of_type("room")) do
			if with_corners(r, a, b) then
				both[#both + 1] = r
				if M.split_lists(r, a, b) then
					out[#out + 1] = {"Split " .. r.strs.name .. " here", function()
						M.split_room(r.id, a, b)
					end}
				end
			end
		end
		for i = 1, #both do
			for j = i + 1, #both do
				local ra, rb = both[i], both[j]
				if M.combine_list(ra, rb, a, b) then
					out[#out + 1] = {"Combine " .. ra.strs.name .. " and " ..
							rb.strs.name, function()
						M.combine_rooms(ra.id, rb.id, a, b)
					end}
				end
			end
		end
		return out
	end

	-- **A plafond lamp** (user): a square 250 by 250, 50 thick, on the
	-- ceiling at (x, z), of the palette's lamp material -- a new "Lamp"
	-- entry when it has none -- and lit, as an instance starts. Its ops
	-- go onto ops, the instance's last.
	function M.plafond_ops(ops, x, z)
		local mat = nil
		for _, p in ipairs(of_type("palette")) do
			if p.ints.kind == 4 then
				mat = p.id
				break
			end
		end
		if not mat then
			mat = doc.placeholder()
			local k = KIND_DEFAULTS[4]
			ops[#ops + 1] = {op = "create", ent = {id = mat, type = "palette",
					ints = {kind = 4, base = k.base, color2 = k.color2,
					scale = k.scale, roughness = k.roughness,
					specular = k.specular}, strs = {name = "Lamp"}}}
		end
		local def = doc.placeholder()
		ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
				ints = {kind = KIND.box, w = 250, h = 50, d = 250, mat = mat}}}
		ops[#ops + 1] = {op = "create", ent = {id = doc.placeholder(),
				type = "instance", ints = {def = def, x = math.floor(x + 0.5),
				z = math.floor(z + 0.5), align = 1, offset = 0}}}
	end

	-- A box drawn: a definition of that size and an instance of it. Stairs
	-- the same, given their depth or taking it from their steps (d nil).
	add_box = function(x, z, w, d)
		local def = doc.placeholder()
		local inst = doc.placeholder()
		local ints = {kind = KIND.box, w = w, h = S.box.h, d = d,
				mat = default_material()}
		if S.shape == "stairs" then
			local st = S.stairs
			local h = st.h > 0 and st.h or settings().floor_step
			local n = math.max(1, math.min(200, math.floor(h / st.riser + 0.5)))
			ints.kind, ints.h, ints.steps = KIND.stairs, h, n
			ints.d = d or n * st.tread
		end
		local ops = {}
		local align, offset = S.box.align, S.box.offset
		if S.shape == "lamp" then
			M.plafond_ops(ops, x, z)
			send(ops, select_placed(ops[#ops].ent.id, "instance"))
			return
		end
		ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
				ints = ints}}
		ops[#ops + 1] = {op = "create", ent = {id = inst, type = "instance",
				ints = {def = def, x = math.floor(x + 0.5),
				z = math.floor(z + 0.5), align = align, offset = offset}}}
		send(ops, select_placed(inst, "instance"))
	end

	-- The voxel volume the voxel tool works on: the one selected
	voxel_target = function()
		local id = S.primary
		if id and S.sel[id] == "instance" and inst_data[id] and inst_data[id].voxel then
			return id
		end
		return nil
	end

	local function in_range(c)
		for a = 1, 3 do
			if c[a] < -128 or c[a] > 127 then
				return false
			end
		end
		return true
	end

	-- A new voxel volume at the point, of one voxel, selected
	local function add_volume(x, z, offset)
		local def = doc.placeholder()
		local inst = doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = KIND.voxel, voxel_size = S.voxel_size}}},
			{op = "create", ent = {id = inst, type = "instance", ints = {def = def,
					x = math.floor(x + 0.5), z = math.floor(z + 0.5),
					offset = offset or 0}}},
		}, function(err)
			if err == "" then
				doc.set_voxels(S.real[def], {[doc.voxel_key(0, 0, 0)] =
						default_material()})
				S.sel = {[S.real[inst]] = "instance"}
				S.primary = S.real[inst]
				M.refresh_panels()
			end
		end)
	end

	-- From above: the column of a volume's cells under the cursor, and the
	-- top voxel in it (nil when it is empty)
	voxel_column = function(id)
		local it = inst_data[id]
		local x, z = cursor_floor()
		if not x then
			return nil
		end
		local lx, _, lz = geom.unrot(x - it.ox, 0, z - it.oz, it.pitch, it.yaw,
				it.roll)
		local cx, cz = math.floor(lx / it.size), math.floor(lz / it.size)
		local top = nil
		for key in pairs(doc.voxels[doc.ents[id].ints.def] or {}) do
			local vx, vy, vz = doc.voxel_cell(key)
			if vx == cx and vz == cz and (not top or vy > top) then
				top = vy
			end
		end
		return cx, cz, top
	end

	-- The voxel tool at the cursor: place a voxel against what is under it,
	-- or dig the one under it, or (paint, Shift) give the one it would dig
	-- the palette entry
	-- **The cell a press or a release points at** in the selected volume
	-- (user): mode "dig" and "paint" an existing voxel, "place" the empty
	-- one on it -- or, off every voxel, the floor's cell beside the volume
	-- (within a cell of what it has, or anywhere when it has none): a volume
	-- that is being edited is not added to far from itself. nil: nothing.
	function M.voxel_cell(mode)
		local id = voxel_target()
		if not id then
			return nil
		end
		if S.view == "2d" then
			local cx, cz, top = voxel_column(id)
			if not cx then
				return nil
			end
			if mode == "place" then
				local c = {cx, top and top + 1 or 0, cz}
				return in_range(c) and id or nil, c
			end
			return top and id or nil, top and {cx, top, cz}
		end
		local hit, place = voxel_ray(id)
		if mode ~= "place" then
			return hit and id or nil, hit
		end
		if not place or not in_range(place) then
			return nil
		end
		if not hit then
			local b = voxel_bounds(doc.ents[id].ints.def)
			if b and (place[1] < b[1] - 1 or place[1] > b[4] + 1 or
					place[3] < b[3] - 1 or place[3] > b[6] + 1) then
				return nil
			end
		end
		return id, place
	end

	-- Where a held box would end: the cell pointed at, or for a fill off
	-- the volume's voxels the imaginary one in the plane facing the view
	function M.voxel_box_end(vb)
		local id, c = M.voxel_cell(vb.mode)
		if vb.mode == "place" and S.view ~= "2d" then
			local hit = voxel_ray(vb.id)
			if not hit then
				local pc = M.voxel_plane_cell(vb.id, vb.a)
				if pc then
					return vb.id, pc
				end
			end
		end
		return id, c
	end

	-- A box of cells from a to b, both in: emptied, painted where there are
	-- voxels, or filled where there are none
	local MAX_BOX = 100000
	function M.voxel_box(mode, id, a, b)
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local def = doc.ents[id].ints.def
		local vox = doc.voxels[def] or {}
		local lo = {math.min(a[1], b[1]), math.min(a[2], b[2]), math.min(a[3], b[3])}
		local hi = {math.max(a[1], b[1]), math.max(a[2], b[2]), math.max(a[3], b[3])}
		if (hi[1] - lo[1] + 1) * (hi[2] - lo[2] + 1) * (hi[3] - lo[3] + 1) > MAX_BOX then
			doc.notice("A box of more than " .. MAX_BOX .. " voxels: make it smaller")
			return
		end
		local mat = default_material()
		local sets = {}
		for x = lo[1], hi[1] do
			for y = lo[2], hi[2] do
				for z = lo[3], hi[3] do
					local key = doc.voxel_key(x, y, z)
					if mode == "dig" then
						if vox[key] then sets[key] = 0 end
					elseif mode == "paint" then
						if vox[key] then sets[key] = mat end
					elseif not vox[key] then
						sets[key] = mat
					end
				end
			end
		end
		if next(sets) then
			doc.set_voxels(def, sets)
		end
	end

	voxel_edit = function(dig, paint)
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local id = voxel_target()
		if not id then
			local x, z = snapped_point(nil)
			-- In 3D, on the top of what the crosshair is on (user: a lamp on
			-- a cupboard), a new volume starts there
			local offset = nil
			if S.view ~= "2d" then
				local s = pick_surface(true)
				local it = s and s.kind == "instance" and inst_data[s.id]
				if it and s.t then
					local o, d = cursor_ray()
					local y = (o.y + d.y * s.t) * 1000
					if d.y < 0 and math.abs(y - it.y1) < 20 then
						x, z = (o.x + d.x * s.t) * 1000, (o.z + d.z * s.t) * 1000
						offset = math.floor(it.y1 + 0.5)
					end
				end
			end
			if x and not dig and not paint then
				add_volume(x, z, offset)
			else
				doc.notice("Select a voxel volume, or place one on the floor")
			end
			return
		end
		local def = doc.ents[id].ints.def
		local sets = {}
		if S.view == "2d" then
			local cx, cz, top = voxel_column(id)
			if not cx then
				return
			end
			if dig or paint then
				if top then
					sets[doc.voxel_key(cx, top, cz)] = paint and default_material() or 0
				end
			else
				local c = {cx, top and top + 1 or 0, cz}
				if in_range(c) then
					sets[doc.voxel_key(c[1], c[2], c[3])] = default_material()
				end
			end
		else
			local ok, c = M.voxel_cell(paint and "paint" or dig and "dig" or "place")
			if ok then
				sets[doc.voxel_key(c[1], c[2], c[3])] = (dig and not paint) and 0 or
						default_material()
			end
		end
		if next(sets) then
			doc.set_voxels(def, sets)
		end
	end

	-- A door, window or opening put in a wall where the point is along it
	add_hosted = function(wall, x, z, side)
		local f = wall_frame(wall)
		if not f then
			return
		end
		local kind = S.hosted
		local d = HOSTED[kind]
		local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
		along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
		local def = doc.placeholder()
		local inst = doc.placeholder()
		local mat = default_material()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = kind, w = d.w, h = d.h, mat = mat, mat_leaf = mat,
					trim = kind == KIND.opening and 0 or 70}}},
			{op = "create", ent = {id = inst, type = "instance",
					ints = {def = def, host = wall, along = math.floor(along + 0.5),
					sill = d.sill, flip = side == "right" and 1 or 0}}},
		})
	end

	-- Copies of the selected instances next to them: linked ones share the
	-- definition, the others get a copy of it
	-- A copied definition's voxels go to the copy once it exists
	-- simplified: a second message after the copy's batch, so undoing the copy
	-- is two steps
	local function copy_voxels(copies)
		for _, c in ipairs(copies) do
			local vox = doc.voxels[c.from]
			if vox and next(vox) and S.real[c.to] then
				local sets = {}
				for k, v in pairs(vox) do
					sets[k] = v
				end
				doc.set_voxels(S.real[c.to], sets)
			end
		end
	end

	copy_selected = function(linked)
		-- **A door, window or opening alone is copied into a wall of the
		-- user's choosing** (user: a linked clone of a window did not fit
		-- on its wall, and was wanted on another one anyway): the next
		-- click on a wall puts it there (M.place_copy), Esc gives up
		local only, n = nil, 0
		for id, kind in pairs(S.sel) do
			only, n = id, n + 1
		end
		local oe = only and doc.ents[only]
		if n == 1 and S.sel[only] == "instance" and oe and oe.ints.host ~= 0 then
			S.place_copy = {id = only, linked = linked}
			S.dirty = true
			return
		end
		local ops, new, voxel_copies = {}, {}, {}
		for id, kind in pairs(S.sel) do
			if kind == "instance" then
				local i = copy_fields(doc.ents[id].ints)
				if not linked then
					local def = doc.placeholder()
					ops[#ops + 1] = {op = "create", ent = {id = def,
							type = "definition", ints = copy_fields(
							doc.ents[i.def].ints)}}
					voxel_copies[#voxel_copies + 1] = {to = def, from = i.def}
					i.def = def
				end
				if i.host ~= 0 then
					-- Along the wall, next to it
					i.along = i.along + doc.ents[doc.ents[id].ints.def].ints.w + 100
				else
					i.x = i.x + COPY_OFFSET
					i.z = i.z - COPY_OFFSET
				end
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
				copy_voxels(voxel_copies)
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

	-- The copy S.place_copy is for, into this wall under the pointer: along
	-- it where the pointer is, snapped and kept inside it, the rest as the
	-- original has it; a linked one shares its definition
	function M.place_copy(wall, x, z, side)
		local pc = S.place_copy
		S.place_copy = nil
		S.dirty = true
		local src = pc and doc.ents[pc.id]
		local f = wall_frame(wall)
		if not src or not f then
			return
		end
		local i = copy_fields(src.ints)
		local w = doc.ents[i.def].ints.w
		local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
		i.along = math.floor(math.max(w / 2, math.min(f.len - w / 2, along)) + 0.5)
		i.host = wall
		local ops = {}
		if not pc.linked then
			local def = doc.placeholder()
			ops[#ops + 1] = {op = "create", ent = {id = def, type = "definition",
					ints = copy_fields(doc.ents[i.def].ints)}}
			i.def = def
		end
		local ph = doc.placeholder()
		ops[#ops + 1] = {op = "create", ent = {id = ph, type = "instance", ints = i}}
		send(ops, function(err)
			if err == "" then
				S.sel = {[S.real[ph]] = "instance"}
				S.primary = S.real[ph]
				M.refresh_panels()
			end
		end)
	end

	unlink = function(id)
		local i = doc.ents[id].ints
		local def = doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition",
					ints = copy_fields(doc.ents[i.def].ints)}},
			{op = "set", ent = {id = id, ints = {def = def}}},
		}, function(err)
			if err == "" then
				copy_voxels({{to = def, from = i.def}})
			end
		end)
	end

	-- Node `from` merged into node `into`: what referred to one refers to the
	-- other, and what that makes degenerate goes
	merge_ops = function(from, into)
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
		for _, room in ipairs(of_type("room")) do
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
			for _, room in ipairs(of_type("room")) do
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
		for _, room in ipairs(of_type("room")) do
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

	delete_selected = function()
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
	moved_by = function(sel)
		local inst, nodes = {}, {}
		for id, kind in pairs(sel) do
			local e = doc.ents[id]
			if e then
				if kind == "instance" or kind == "image" then
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
	local turning, turn_queued = false, 0
	local function send_turn(deg)
		local inst, nodes = moved_by(S.sel)
		local sx, sz, n = 0, 0, 0
		for id in pairs(inst) do
			local c = inst_data[id] or doc.ents[id].ints
			sx, sz, n = sx + c.x, sz + c.z, n + 1
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
			-- What is in a wall turns with the wall, not by itself
			if i.host == 0 then
				local x, z = turn(i.x, i.z)
				-- Yaw grows turning right, which from above is clockwise
				local yaw = (i.yaw - math.floor(deg * 1000 + 0.5)) % 360000
				ops[#ops + 1] = {op = "set", ent = {id = id, ints = {x = x, z = z,
						yaw = yaw}}}
			end
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
	-- both: a wall's two faces; else only the face it was selected by, and
	-- a wall with none (selected by a box) is left alone
	apply_material = function(both)
		local mat = default_material()
		local ops = {}
		local faceless = 0
		for id, kind in pairs(S.sel) do
			local e = doc.ents[id]
			if e and kind == "instance" then
				-- A door's or a window's part, when one was picked in its panel
				local part = S.sel_face[id]
				ops[#ops + 1] = {op = "set", ent = {id = e.ints.def,
						ints = {[DOOR_PARTS[part] and part or "mat"] = mat}}}
			elseif e and kind == "wall" then
				local face = S.sel_face[id]
				local ints = both == true and {mat_left = mat, mat_right = mat} or
						face == "left" and {mat_left = mat} or
						face == "right" and {mat_right = mat} or
						face == "core" and {mat_core = mat} or nil
				if ints then
					ops[#ops + 1] = {op = "set", ent = {id = id, ints = ints}}
				else
					faceless = faceless + 1
				end
			elseif e and kind == "room" then
				ops[#ops + 1] = {op = "set", ent = {id = id, ints =
						S.sel_face[id] == "ceiling" and {mat_ceiling = mat} or
						{mat_floor = mat}}}
			end
		end
		if faceless > 0 then
			doc.notice(faceless .. " walls were selected by a box, not by a face: "
					.. "click a wall on the face to paint")
		end
		if #ops > 0 then
			send(ops)
		end
	end

end

-- The next of GRID_STEPS after the plan's
local function next_grid()
	local g = grid_step()
	local n = GRID_STEPS[1]
	for i, v in ipairs(GRID_STEPS) do
		if v == g then
			n = GRID_STEPS[i % #GRID_STEPS + 1]
		end
	end
	send({{op = "set", ent = {id = doc.settings().id, ints = {grid = n}}}})
	return n
end

-- The grid and the angle steps as the settings page says them (user: out
-- of the toolbar and into Settings, with their keys); on M, since this
-- file is at Lua's 200 locals
function M.grid_text(g)
	return g < 10 and g .. " mm" or (g / 10) .. " cm"
end
function M.angle_text(i)
	local a = ANGLE_STEPS[i]
	return a and a .. " deg" or "free"
end

--
-- The panels
--
local toolbar, props, palette_win
local label_nodes = {}

local refresh_panels

-- Walking and the voxel tool in 3D have two levels ([FP_ESC]): the pointer,
-- for the panels, and above it the crosshair, which holds the mouse
-- Luanti's way -- the view turns with it and the crosshair picks. A click on
-- the view goes up into the crosshair and Esc comes back down.
local function crosshair_view()
	-- A touchscreen has no pointer to hold: walking is by the stick and a
	-- drag ([FP_TOUCH] 3), and the voxel tool by taps
	-- The voxel tool works at the pointer in 3D (user: a touchscreen has
	-- no crosshair, and it needs none)
	return not S.touch and S.view == "walk"
end

local function update_capture()
	local want = S.crosshair and crosshair_view() and not S.paused or false
	if want ~= (S.captured or false) then
		S.captured = want
		S.looking = want
		magic.input:SetMouseMode(want and magic.MM_RELATIVE or magic.MM_ABSOLUTE)
	end
end

-- **The free camera and the walker are each their own** (user,
-- 2026-10-01: a walking shot could not be taken again from the same place
-- after an edit in 3D): M.update keeps the camera of the view in use --
-- S.cam3d, and the walker's look in S.walk -- and a view gone back to
-- takes its own again. The walker starts under the free camera the first
-- time, and again by "Walk from here".
local function set_view(v)
	-- Another view than a viewport's is out of it
	if S.vp and v ~= "3d" then
		M.leave_viewport()
	end
	if v == "walk" and S.view ~= "walk" then
		if not S.walk.placed then
			-- On the floor under the camera, or the plan's middle
			if S.view == "3d" then
				local x, z = S.pos.x * 1000, S.pos.z * 1000
				S.walk.x, S.walk.z = x, z
			else
				S.walk.x, S.walk.z = S.cx, S.cz
			end
			S.walk.feet = 0
			S.walk.yaw, S.walk.pitch = S.yaw, 0
			S.walk.placed = true
		end
		S.yaw, S.pitch = S.walk.yaw, S.walk.pitch
	end
	-- A view starts at its pointer, so the view button can go on from it
	if v ~= S.view then
		S.crosshair = false
	end
	S.view = v
	-- Only when it changes: the walk and the free camera share a viewport.
	-- The lighting's HDR frame is for the 3D one under PBR.
	local lighting = v ~= "2d" and S.lighting or "unlit"
	if (v == "2d") ~= (S.shown_2d == true) or not S.shown or
			lighting ~= S.shown_lighting then
		S.shown, S.shown_2d, S.shown_lighting = true, v == "2d", lighting
		magic.renderer.HDRRendering = lighting ~= "unlit"
		magic.set_preferred_viewports({viewport_for(v)})
		S.daylight_key = nil
		-- The lamps' brightness and the ground go with it
		S.dirty = true
	end
	-- The plan view's look: flat colours, or the materials lit
	local flat = v == "2d" and S.plan_look and 1 or 0
	lit_material:SetShaderParameter("PlanLook", flat)
	glass_material:SetShaderParameter("PlanLook", flat)
	caps_node.enabled = v == "2d"
	pieces_node.enabled = v ~= "2d"
	update_capture()
	refresh_panels()
end

-- A view the user picked: 3D takes its own camera back. "walk_here"
-- puts the walker under the free camera first. (On M: the chunk is at
-- Lua's limit of 200 locals.)
function M.pick_view(v)
	if v == "save" then
		M.save_viewport()
		return
	elseif type(v) == "string" and v:sub(1, 3) == "vp:" then
		M.go_viewport(tonumber(v:sub(4)))
		return
	end
	if v == "walk_here" then
		S.walk.placed = false
		v = "walk"
	end
	local was_vp = S.vp
	M.leave_viewport()
	if v == "3d" and (S.view ~= "3d" or was_vp) and S.cam3d then
		local c = S.cam3d
		S.pos = {x = c.x, y = c.y, z = c.z}
		S.yaw, S.pitch = c.yaw, c.pitch
	end
	set_view(v)
end

local function set_tool(t)
	-- Viewing ([FP_VIEW_EDIT]): only Select, whose clicks show things
	if t ~= "select" and not doc.can("edit") then
		doc.notice(doc.can("can_edit") and
				"Viewing: switch to Editing in the menu to use that tool" or
				"Viewing only: no edit privilege")
		return
	end
	if t ~= S.tool and S.view == "3d" then
		S.crosshair = false
	end
	-- A placing tool starts with nothing selected, so its panel is the
	-- settings of what it puts in until it has put one in
	if t ~= S.tool and (t == "wall" or t == "room" or t == "box" or
			t == "hosted") then
		S.sel, S.sel_face, S.primary = {}, {}, nil
	end
	S.tool = t
	S.draw = nil
	S.corners = nil
	S.typed = ""
	update_capture()
	refresh_panels()
end

local function build_toolbar()
	if toolbar then
		toolbar:Remove()
	end
	-- Rows of buttons, as many as the screen's width needs ([FP_TOUCH] 2);
	-- one on a desktop's. A touchscreen has no keys: no key in the names,
	-- and a Menu button for Esc's pause menu.
	toolbar = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 8)
	local row, used = panel.row(toolbar), 0
	local room = magic.ui.root.width - 16 - 12
	-- make(parent) makes the button
	local function place(make)
		-- Measured before it is put in a row: a row a button was taken back
		-- out of keeps the width it had with it
		local probe = make(magic.ui.root)
		local w = probe.minWidth + 4
		probe:Remove()
		if used > 0 and used + w > room then
			row, used = panel.row(toolbar), 0
		end
		-- Not stretched to the widest row
		local b = make(row)
		b.maxWidth = b.minWidth
		used = used + w
	end
	local function add(text, key, f, down, min_width)
		if key and not S.touch then
			text = text .. " (" .. key .. ")"
		end
		place(function(parent)
			return panel.button(parent, text, f, down, min_width)
		end)
	end
	-- The pause menu's own button, and on a desktop the key it is on: a
	-- phone has no Esc, and a newcomer does not know it yet (user)
	add("Menu", S.touch and nil or "Esc", function() M.open_pause() end)
	local views = {}
	for i, v in ipairs({"2d", "3d", "walk"}) do
		views[i] = {VIEW_NAMES[v] .. (S.touch and "" or
				" (" .. keys.name("view_" .. v) .. ")"), v}
	end
	if S.view == "3d" and not S.vp then
		views[#views + 1] = {"Walk from here", "walk_here"}
	end
	-- **Viewports** (user, 2026-10-01): saved from 3D or walking by an
	-- editor, gone to by anyone; picked again, or the dropdown opened and
	-- closed, the menus are hidden again
	if S.view ~= "2d" and not S.vp and doc.can("edit") then
		views[#views + 1] = {"Save viewport", "save"}
	end
	for _, e in ipairs(M.viewports()) do
		views[#views + 1] = {e.strs.name, "vp:" .. e.id}
	end
	place(function(parent)
		return panel.dropdown(parent, nil, views,
				S.vp and "vp:" .. S.vp or S.view, M.pick_view, 40, function()
			if S.vp then
				M.hide_ui()
			end
		end)
	end)
	-- The layout edited, and the window that picks another
	local l = S.layout and doc.ents[S.layout]
	add(l and l.strs.name or "Layouts", nil, function()
		S.layouts_open = not S.layouts_open
		refresh_panels()
	end, S.layouts_open)
	-- Viewing ([FP_VIEW_EDIT]): the tools that only make and change
	-- things are not there
	for _, t in ipairs({{"select", "Select"}, {"node", "Nodes"},
			{"wall", "Wall"}, {"room", "Room"}, {"box", "Object"},
			{"hosted", "Door/window"}, {"voxel", "Voxels"}, {"paint", "Material"}}) do
		if t[1] == "select" or doc.can("edit") then
			add(t[2], keys.name(t[1]), function() set_tool(t[1]) end,
					S.tool == t[1])
		end
	end
	-- The panels folded away on a narrow screen, opened here
	if panel.narrow() then
		for _, p in ipairs({{"palette", "Palette"}, {"props", "Properties"}}) do
			add(p[2], nil, function()
				panel.toggle_fold(p[1])
				refresh_panels()
			end, not panel.folded(p[1]))
		end
	end
	add("IDs", nil, function()
		S.show_ids = not S.show_ids
		S.dirty = true
		refresh_panels()
	end, S.show_ids)
	-- Viewing with a role that edits: the way to editing, last (user),
	-- where the tools were
	if not doc.can("edit") and doc.can("can_edit") then
		add("Start editing", nil, function() doc.set_editing(true) end)
	end
	-- The panels start under it
	S.panel_y = 8 + toolbar.height + 8
	-- **A touchscreen's keys** ([FP_TOUCH] 4): what Ctrl+Z, Ctrl+Y, Del,
	-- E and Esc do, at the lower right
	if S.touch_bar then
		S.touch_bar:Remove()
		S.touch_bar = nil
	end
	if S.touch then
		local b = panel.window(magic.HA_RIGHT, magic.VA_BOTTOM, -8, -8, true)
		S.touch_bar = b
		if doc.can("edit") then
			panel.button(b, "Undo", function() doc.undo() end)
			panel.button(b, "Redo", function() doc.redo() end)
			panel.button(b, "Delete", function() delete_selected() end)
			-- What Shift does to a wall or room drawn: the angle step
			-- instead of right angles (user)
			panel.button(b, "Angle " .. (S.touch_angle and
					M.angle_text(S.angle) or "90 deg"), function()
				S.touch_angle = not S.touch_angle
				refresh_panels()
			end)
		end
		if S.view == "walk" then
			panel.button(b, "Use", function() M.use() end)
		end
		panel.button(b, "Cancel", function() M.escape() end)
	end
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

-- The room actions of two corners, as buttons, or how to get one
function M.room_buttons(a, b)
	local acts = M.room_actions(a, b)
	for _, act in ipairs(acts) do
		panel.button(props, act[1], act[2])
	end
	if #acts == 0 then
		panel.label(props, "(two corners of a room split it,")
		panel.label(props, " two shared by two rooms join them)")
	end
end

-- What the voxel tool's click does in 3D, for a touchscreen above all,
-- which has no Ctrl or Shift
function M.voxel_mode_dropdown()
	panel.keep(function() return panel.dropdown(props, S.touch and "Tap" or "Click", {
		{"place a voxel", "place"}, {"dig one", "dig"},
		{"paint one", "paint"}}, S.voxel_mode, function(v)
		S.voxel_mode = v
		refresh_panels()
	end) end)
end

local function build_props()
	if props then
		props:Remove()
	end
	props = panel.window(magic.HA_RIGHT, magic.VA_TOP, -8, S.panel_y or 50)
	if panel.folded("props") then
		props.visible = false
		return
	end
	local sel = S.primary and S.sel[S.primary] and doc.ents[S.primary]
	if S.stair_riser and not (sel and sel.id == S.stair_riser.inst) then
		S.stair_riser = nil
	end
	-- **Nothing to show with Select and nothing selected** (user): the
	-- panel is for what is selected and for a tool's own settings
	if S.tool == "select" and not sel and sel_count() == 0 then
		props.visible = false
		return
	end
	-- **An edit of what is selected leaves a placing tool for Select**, the
	-- selection kept (user): the next click in the view is then not one
	-- more of what was being edited
	local function editing_selection()
		if sel and (S.tool == "wall" or S.tool == "room" or S.tool == "box" or
				S.tool == "hosted") then
			set_tool("select")
		end
	end
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints,
				strs = fields.strs}}})
		-- The plan's own settings are not the selection's
		if id ~= doc.settings().id then
			editing_selection()
		end
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
		-- One node's place, to be read off another and typed in (user)
		if n == 1 then
			local id = next(S.nodes)
			local ne = doc.ents[id]
			if ne then
				int_field(id, "X mm", "x", ne.ints.x)
				int_field(id, "Z mm", "z", ne.ints.z)
			end
		end
		if n == 2 then
			local a = next(S.nodes)
			M.room_buttons(a, next(S.nodes, a))
		end
		panel.label(props, "Drag one to move them all;")
		panel.label(props, "drop one on another to merge;")
		panel.label(props, "double click an edge: a node into it")
		if n > 0 then
			panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
		end
	elseif count > 1 then
		panel.label(props, count .. " selected")
		-- Two corners: a room split or two combined there
		if count == 2 then
			local a = next(S.sel)
			local b = next(S.sel, a)
			if S.sel[a] == "node" and S.sel[b] == "node" then
				M.room_buttons(a, b)
			end
		end
		panel.button(props, "Turn left (" .. keys.name("turn_left") .. ")",
				function()
			rotate_selection(angle_step())
		end)
		panel.button(props, "Turn right (" .. keys.name("turn_right") .. ")",
				function()
			rotate_selection(-angle_step())
		end)
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clones (Ctrl+L)", function()
			copy_selected(true)
		end)
		panel.button(props, "Apply the palette entry", apply_material)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" and sel.ints.host ~= 0 then
		local i = sel.ints
		local p = doc.ents[i.def].ints
		local links = instances_of(i.def)
		panel.label(props, KIND_NAMES[p.kind] .. " " .. sel.id ..
				(links > 1 and ("   linked x" .. links) or ""))
		-- **A window's sizes as its frame's or its glass's** (user): the
		-- frame's are what is stored, and the glass is inset from it by
		-- the frame and the sash on each side (build_hosted's FRAME_W
		-- twice). A double casement's glass is from its one outer edge to
		-- the other, the sashes' middle stiles over it.
		local glass = p.kind == KIND.window and p.measure == 1
		if p.kind == KIND.window then
			panel.dropdown(props, "Sizes of", {{"the frame", 0}, {"the glass", 1}},
					p.measure, function(v)
				set(i.def, {ints = {measure = v}})
			end)
		end
		local inset = glass and 2 * FRAME_W or 0
		local function sized(id, label, name, value, by)
			panel.field(props, label, value - by, function(t)
				local v = num(t)
				if v then set(id, {ints = {[name] = v + by}}) end
			end)
		end
		sized(i.def, "Width mm", "w", p.w, 2 * inset)
		sized(i.def, "Height mm", "h", p.h, 2 * inset)
		sized(sel.id, "Sill mm", "sill", i.sill, -inset)
		int_field(sel.id, "Along mm", "along", i.along)
		if p.kind == KIND.switch then
			panel.label(props, #sel.lists.lamps .. " lamps (E switches them)")
			panel.button(props, S.linking == sel.id and "Done linking" or
					"Link lamps: click them", function()
				S.linking = S.linking ~= sel.id and sel.id or nil
				refresh_panels()
			end, S.linking == sel.id)
			panel.button(props, "Other side of the wall", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 1)}})
			end)
		elseif p.kind ~= KIND.opening then
			int_field(i.def, "Trim mm", "trim", p.trim)
			int_field(i.def, "Trim depth mm", "trim_depth", p.trim_depth)
			if p.kind == KIND.door then
				panel.check(props, "Double leaf", p.leaf == 1, function()
					set(i.def, {ints = {leaf = 1 - p.leaf}})
				end)
			else
				panel.dropdown(props, "Opens", {{"fixed", 0}, {"casement", 1},
						{"double casement", 2}}, p.leaf, function(v)
					set(i.def, {ints = {leaf = v}})
				end)
			end
			if p.kind == KIND.door then
				panel.check(props, "Glass pane", p.glazed == 1, function()
					set(i.def, {ints = {glazed = 1 - p.glazed}})
				end)
			end
			local r = panel.row(props)
			panel.button(r, "Other hinge", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 1)}})
			end)
			panel.button(r, "Other side", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 2)}})
			end)
			-- In degrees, 0 to 170 (user); stored in thousandths of a right
			-- angle, 90 degrees being 1000
			panel.field(props, "Open deg", math.floor(i.open * 0.09 + 0.5),
					function(t)
				local v = tonumber(t)
				if v then
					v = math.max(0, math.min(170, v))
					set(sel.id, {ints = {open = math.min(1889,
							math.floor(v / 0.09 + 0.5))}})
				end
			end)
			-- The part a palette double click goes on, the palette showing
			-- what it has now; a part with none of its own shows the frame's
			panel.label(props, "Selected part (the palette's double click):")
			local part = DOOR_PARTS[S.sel_face[sel.id]] and S.sel_face[sel.id] or
					"mat"
			local slots = {{"Frame", "mat"}, {"Leaf", "mat_leaf"}}
			if p.kind == KIND.window or p.glazed == 1 then
				slots[3] = {"Glass", "mat_glass"}
			end
			-- Which part's palette entry shows: not an edit
			panel.keep(function() return panel.dropdown(props, "Part", slots,
					part, function(v)
				S.sel_face[sel.id] = v
				editing_selection()
				local m = p[v] ~= 0 and p[v] or p.mat
				if doc.ents[m] then
					S.material = m
				end
				refresh_panels()
			end) end)
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" and
			doc.ents[sel.ints.def].ints.kind == KIND.voxel then
		local i = sel.ints
		local p = doc.ents[i.def].ints
		local links = instances_of(i.def)
		local n = 0
		for _ in pairs(doc.voxels[i.def] or {}) do
			n = n + 1
		end
		panel.label(props, "Voxels " .. sel.id .. ": " .. n .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Voxel mm", "voxel_size", p.voxel_size)
		int_field(sel.id, "X mm", "x", i.x)
		int_field(sel.id, "Z mm", "z", i.z)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		int_field(sel.id, "Offset mm", "offset", i.offset)
		panel.check(props, "From the ceiling down", i.align == 1, function()
			set(sel.id, {ints = {align = 1 - i.align}})
		end)
		local r = panel.row(props)
		-- The turn most often wanted, as the field's value plus 90 (user)
		panel.button(r, "Yaw +90", function()
			set(sel.id, {ints = {yaw = (i.yaw + 90000) % 360000}})
		end)
		panel.button(r, "Pitch +90", function()
			set(sel.id, {ints = {pitch = (i.pitch + 1) % 4}})
		end)
		panel.button(r, "Roll +90", function()
			set(sel.id, {ints = {roll = (i.roll + 1) % 4}})
		end)
		panel.button(props, "Replace a material...", function()
			S.picker = nil
			S.replace = {def = i.def, to = default_material()}
			refresh_panels()
		end)
		panel.label(props, "Voxel tool (" .. keys.name("voxel") ..
				"): a click places, Ctrl+click")
		panel.label(props, "digs, Shift+click gives a voxel the entry")
		if S.tool == "voxel" then
			M.voxel_mode_dropdown()
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "instance" then
		local i = sel.ints
		local def = doc.ents[i.def]
		local p = def.ints
		local links = instances_of(i.def)
		panel.label(props, KIND_NAMES[p.kind] .. " " .. sel.id .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Width mm", "w", p.w)
		if p.kind == KIND.stairs then
			-- **The height keeps the riser, and the steps follow** (user).
			-- The riser is the one before the first height edit, kept while
			-- these stairs stay selected, so that 10 mm at a time adds up
			-- to a step.
			-- simplified: in memory only; a Steps or Riser edit, another
			-- selection or a reload starts from the riser the stairs have
			panel.field(props, "Height mm", p.h, function(t)
				local v = num(t)
				if not v or v <= 0 then
					return
				end
				local r = S.stair_riser
				if not (r and r.inst == sel.id) then
					r = {inst = sel.id, riser = p.h / p.steps}
					S.stair_riser = r
				end
				set(i.def, {ints = {h = v, steps = math.max(1, math.min(200,
						math.floor(v / r.riser + 0.5)))}})
			end)
		else
			int_field(i.def, "Height mm", "h", p.h)
		end
		int_field(i.def, "Depth mm", "d", p.d)
		if p.kind == KIND.stairs then
			-- The riser sets the steps, the height staying; the tread sets
			-- the depth
			panel.field(props, "Steps", p.steps, function(t)
				local v = num(t)
				if v then
					S.stair_riser = nil
					set(i.def, {ints = {steps = v}})
				end
			end)
			panel.field(props, "Riser mm", math.floor(p.h / p.steps * 10 + 0.5) / 10,
					function(t)
				local v = tonumber(t)
				if v and v > 0 then
					S.stair_riser = nil
					set(i.def, {ints = {steps = math.max(1, math.min(200,
							math.floor(p.h / v + 0.5)))}})
				end
			end)
			panel.field(props, "Tread mm", math.floor(p.d / p.steps * 10 + 0.5) / 10,
					function(t)
				local v = tonumber(t)
				if v and v > 0 then
					set(i.def, {ints = {d = math.floor(v * p.steps + 0.5)}})
				end
			end)
			panel.label(props, "Up along its depth (yaw turns it)")
		end
		int_field(sel.id, "X mm", "x", i.x)
		int_field(sel.id, "Z mm", "z", i.z)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		int_field(sel.id, "Offset mm", "offset", i.offset)
		panel.check(props, "From the ceiling down", i.align == 1, function()
			set(sel.id, {ints = {align = 1 - i.align}})
		end)
		local r = panel.row(props)
		-- The turn most often wanted, as the field's value plus 90 (user)
		panel.button(r, "Yaw +90", function()
			set(sel.id, {ints = {yaw = (i.yaw + 90000) % 360000}})
		end)
		panel.button(r, "Pitch +90", function()
			set(sel.id, {ints = {pitch = (i.pitch + 1) % 4}})
		end)
		panel.button(r, "Roll +90", function()
			set(sel.id, {ints = {roll = (i.roll + 1) % 4}})
		end)
		-- The gaps to the walls, typed to move the box
		if inst_data[sel.id] and not inst_data[sel.id].hosted then
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
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
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
		panel.dropdown(props, "Justify", JUSTIFY_CHOICES, w.justify, function(v)
			set(sel.id, {ints = {justify = v}})
		end)
		panel.check(props, "Hangs from the ceiling", w.hang == 1, function()
			set(sel.id, {ints = {hang = 1 - w.hang}})
		end)
		local face = S.sel_face[sel.id]
		local face_mat = face == "left" and w.mat_left or face == "right" and
				w.mat_right or face == "core" and w.mat_core or nil
		panel.label(props, face and ("Selected by its " .. (face == "core" and
				"top" or face .. " face") .. ", #" .. tostring(face_mat)) or
				"Click the wall on a face to pick it")
		if face then
			panel.button(props, "The palette entry on that face (double click)",
					function() apply_material() end)
		end
		panel.button(props, "The palette entry on both faces", function()
			apply_material(true)
		end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "image" then
		local i = sel.ints
		panel.label(props, "Picture: " .. sel.strs.file)
		int_field(sel.id, "mm per 1000 px", "scale", i.scale)
		panel.field(props, "Opacity %", i.opacity / 10, function(t)
			local v = tonumber(t)
			if v then set(sel.id, {ints = {opacity = math.floor(v * 10 + 0.5)}}) end
		end)
		panel.field(props, "Yaw deg", i.yaw / 1000, function(t)
			local v = tonumber(t)
			if v then
				set(sel.id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
			end
		end)
		if S.calib and S.calib.id == sel.id and S.calib.measured then
			panel.label(props, "The two points are " ..
					math.floor(S.calib.measured + 0.5) .. " mm apart; really:")
			panel.field(props, "Distance mm", "", function(t)
				local v = tonumber(t)
				if v and v > 0 then
					set(sel.id, {ints = {scale = math.max(1, math.floor(
							i.scale * v / S.calib.measured + 0.5))}})
				end
				S.calib = nil
			end, nil, true)
		else
			panel.button(props, S.calib and "Click two points on it" or
					"Calibrate: two points and their distance", function()
				S.calib = {id = sel.id, pts = {}}
				refresh_panels()
			end, S.calib ~= nil)
		end
		panel.button(props, "Lock it (a locked one cannot be picked)",
				function()
			set(sel.id, {ints = {locked = 1}})
		end)
		panel.check(props, "Shown in 3D too", i.show3d == 1, function()
			set(sel.id, {ints = {show3d = 1 - i.show3d}})
		end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "room" then
		local r = room_data[sel.id]
		panel.label(props, "Room " .. sel.id)
		panel.field(props, "Name", sel.strs.name, function(t)
			set(sel.id, {strs = {name = t}})
		end, 120, true)
		int_field(sel.id, "Ceiling mm", "ceiling", sel.ints.ceiling)
		panel.label(props, "(ceiling 0: the plan's)")
		if r then
			panel.label(props, "Floor " .. m2(r.net) .. " net")
			panel.label(props, m2(r.gross) .. " to the wall lines")
		end
		local on_ceiling = S.sel_face[sel.id] == "ceiling"
		panel.label(props, "Selected by its " .. (on_ceiling and "ceiling, #" ..
				sel.ints.mat_ceiling or "floor, #" .. sel.ints.mat_floor))
		panel.button(props, "The palette entry on the " .. (on_ceiling and
				"ceiling" or "floor") .. " (double click)",
				function() apply_material() end)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif sel and sel.type == "node" then
		panel.label(props, "Node " .. sel.id)
		int_field(sel.id, "X mm", "x", sel.ints.x)
		int_field(sel.id, "Z mm", "z", sel.ints.z)
		panel.button(props, "Delete (" .. keys.name("delete") .. ")",
				delete_selected)
	elseif S.tool == "hosted" then
		panel.label(props, "Click a wall to put in (I: the next):")
		local kinds = {}
		for _, k in ipairs({KIND.opening, KIND.door, KIND.window, KIND.switch}) do
			kinds[#kinds + 1] = {KIND_NAMES[k], k}
		end
		panel.dropdown(props, "Kind", kinds, S.hosted, function(k)
			S.hosted = k
			refresh_panels()
		end)
		local d = HOSTED[S.hosted]
		for _, f in ipairs({{"Width mm", "w"}, {"Height mm", "h"},
				{"Sill mm", "sill"}}) do
			panel.field(props, f[1], d[f[2]], function(t)
				local v = num(t)
				if v and (v > 0 or f[2] == "sill") then d[f[2]] = v end
			end)
		end
	elseif S.tool == "voxel" then
		panel.label(props, "Select a volume to edit it, or")
		panel.label(props, "place a voxel on the floor or on an")
		panel.label(props, "object's top to start one")
		panel.field(props, "Voxel mm", S.voxel_size, function(t)
			local v = num(t)
			if v and v > 0 then S.voxel_size = v end
		end)
		M.voxel_mode_dropdown()
	elseif S.tool == "box" then
		local stairs = S.shape == "stairs"
		panel.dropdown(props, "Shape", {{"box", "box"}, {"stairs", "stairs"},
				{"plafond lamp", "lamp"}}, S.shape or "box", function(v)
			S.shape = v
			refresh_panels()
		end)
		local lamp = S.shape == "lamp"
		panel.label(props, lamp and "New lamps: click where one goes; on the ceiling, lit" or
				stairs and "New stairs: click, or drag the footprint"
				or "New boxes: drag the footprint")
		if lamp then
		elseif stairs then
			local st = S.stairs
			for _, f in ipairs({{"Width mm", "w"}, {"Height mm (0: a floor)", "h"},
					{"Riser mm", "riser"}, {"Tread mm", "tread"}}) do
				panel.field(props, f[1], st[f[2]], function(t)
					local v = num(t)
					if v and (v > 0 or f[2] == "h" and v == 0) then st[f[2]] = v end
				end)
			end
			local h = st.h > 0 and st.h or settings().floor_step
			local n = math.max(1, math.floor(h / st.riser + 0.5))
			panel.label(props, n .. " steps of " ..
					math.floor(h / n * 10 + 0.5) / 10 .. " mm, " ..
					n * st.tread .. " mm deep")
		end
		for _, f in ipairs(lamp and {} or stairs and {{"Offset mm", "offset"}} or
				{{"Width mm", "w"}, {"Height mm", "h"}, {"Depth mm", "d"},
				{"Offset mm", "offset"}}) do
			panel.field(props, f[1], S.box[f[2]], function(t)
				local v = num(t)
				if v and (v > 0 or f[2] == "offset") then S.box[f[2]] = v end
			end)
		end
		if not lamp then
			panel.check(props, "From the ceiling down", S.box.align == 1, function()
				S.box.align = 1 - S.box.align
				refresh_panels()
			end)
		end
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
		panel.dropdown(props, "Justify", JUSTIFY_CHOICES, S.justify, function(v)
			S.justify = v
			refresh_panels()
		end)
		panel.check(props, "Hang from the ceiling", S.hang == 1, function()
			S.hang = 1 - S.hang
			refresh_panels()
		end)
		panel.check(props, "Rooms get a ceiling lamp", S.room_lamp, function()
			S.room_lamp = not S.room_lamp
			buildat.storage_write("room_lamp", S.room_lamp and "1" or "0")
			refresh_panels()
		end)
		panel.check(props, "Rooms get walls", S.room_walls, function()
			S.room_walls = not S.room_walls
			refresh_panels()
		end)
	end
	if not doc.can("edit") then
		panel.label(props, doc.can("can_edit") and
				"Viewing: Editing is in the menu" or
				"Viewing only: no edit privilege", magic.Color(1, 0.6, 0.4))
	end
end

local build_palette, picker_win, close_picker
do
	local FINISHES = {[0] = "Over its colour", "White undercoat", "Stain"}
	local AXES = {[0] = "Grain along X", "Grain along Y", "Grain along Z"}
	-- Which knobs each type has, beyond the colours and the finish.
	-- Roughness and specular are the type's own (KIND_DEFAULTS, set when
	-- the type is picked), not shown: they only shape a lamp's or the sun's
	-- highlight, which the knobs did not visibly change (user, 2026-09-29)
	local KNOBS = {
		[0] = {"reflect"},
		{"reflect", "scale", "seed", "axis", "contrast"},
		{"reflect", "scale", "seed", "color2"},
		{"scale", "seed", "color2"},
		{"temperature", "brightness"},
		{"opacity", "reflect"},
		{"reflect", "scale"},
		{"reflect", "scale", "grout", "stagger", "color2"},
		{"scale"},
		{"scale", "seed", "speckle"},
		-- Paneling's polish stands for its roughness, specular and reflect
		{"scale", "seed", "angle", "contrast", "polish", "gap_depth",
			"gap_width", "handmade"},
	}
	local KNOB_LABELS = {roughness = "Roughness", specular = "Specular",
		reflect = "Reflective", scale = "Scale mm", seed = "Seed",
		temperature = "Kelvin", brightness = "Brightness", opacity = "Opacity",
		grout = "Grout mm", speckle = "Speckle", angle = "Angle deg",
		contrast = "Grain contrast", polish = "Polish",
		gap_depth = "Gap depth mm", gap_width = "Gap width mm",
		handmade = "Hand made"}
	-- Knobs in thousandths shown as percent
	local PERCENT = {roughness = true, specular = true, reflect = true,
		brightness = true, opacity = true, speckle = true, contrast = true,
		polish = true, handmade = true}
	-- Knobs in tenths of a mm, shown as mm, nudged by one
	local TENTHS = {gap_depth = true, gap_width = true}

	-- Everything that holds palette entry `from`, moved to `to`, and `from`
	-- deleted, in one batch
	local function replace_entry(from, to)
		local ops = {}
		for id, e in pairs(doc.ents) do
			local ints = {}
			for k, v in pairs(e.ints) do
				if v == from and k:sub(1, 3) == "mat" then
					ints[k] = to
				end
			end
			if next(ints) then
				ops[#ops + 1] = {op = "set", ent = {id = id, ints = ints}}
			end
		end
		ops[#ops + 1] = {op = "delete", ent = {id = from}}
		send(ops)
end

-- The colour picker ([FP_COLOR]) on one colour of one palette entry:
-- S.picker = {ent, field, title, groups, query}. Its named colours are
-- client_data/colors.txt's, the groups the field and the type call for.
local named_colours = nil
close_picker = function()
	if picker_win then
		panel.close_picker(picker_win)
		picker_win = nil
	end
	S.picker, S.replace = nil, nil
end

-- **Replacing a material in a voxel volume** (user: a lamp built of the
-- wrong voxels): S.replace = {def, from, to}, from what its voxels use to
-- any palette entry, as one voxel edit and so one undo. The picker's window
-- is its window too; one of the two is up at a time.
local HIGHLIGHT = magic.Color(1.0, 0.85, 0.3)
local build_picker
local function build_replace()
	local rp = S.replace
	local vox = doc.voxels[rp.def]
	if not doc.ents[rp.def] or not vox then
		S.replace = nil
		return
	end
	local counts = {}
	local used = 0
	for _, m in pairs(vox) do
		if not counts[m] then
			used = used + 1
		end
		counts[m] = (counts[m] or 0) + 1
	end
	-- One material in them: that is the one to replace
	if not rp.from and used == 1 then
		rp.from = next(counts)
	end
	local w = panel.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	picker_win = w
	w.minWidth = 320
	panel.label(w, "Replace a material in these voxels")
	-- From and To side by side (user): a palette is ten entries or more
	local cols = panel.row(w)
	local function list(label, want, field)
		local c = panel.column(cols)
		panel.label(c, label)
		for _, p in ipairs(of_type("palette")) do
			if not want or counts[p.id] then
				local picked = rp[field] == p.id
				panel.swatch_row(c, palette_rgb(p.id), "#" .. p.id .. "  " ..
						p.strs.name .. (counts[p.id] and ("  (" .. counts[p.id] ..
						" voxels)") or ""), function()
					rp[field] = p.id
					build_picker()
				end, picked, picked and HIGHLIGHT or nil)
			end
		end
	end
	list("From:", true, "from")
	list("To:", false, "to")
	local r = panel.row(w)
	if rp.from and rp.to and rp.from ~= rp.to and counts[rp.from] then
		panel.button(r, "Replace " .. counts[rp.from] .. " voxels", function()
			local sets = {}
			for key, m in pairs(vox) do
				if m == rp.from then
					sets[key] = rp.to
				end
			end
			doc.set_voxels(rp.def, sets)
			close_picker()
		end)
	end
	panel.button(r, "Cancel (Esc)", close_picker)
end

build_picker = function()
	if picker_win then
		panel.close_picker(picker_win)
		picker_win = nil
	end
	if S.replace then
		return build_replace()
	end
	local pk = S.picker
	local e = pk and doc.ents[pk.ent]
	if not e then
		S.picker = nil
		return
	end
	if not named_colours then
		named_colours = {}
		for _, file in ipairs({"main/colors.txt", "main/colors_tikkurila.txt"}) do
			local text = buildat.get_file_content(file) or ""
			for line in text:gmatch("[^\r\n]+") do
				local g, name, hex, family = line:match(
						"^(%w+)|([^|]+)|(%x%x%x%x%x%x)|?([^|]*)$")
				if g then
					named_colours[#named_colours + 1] = {group = g, name = name,
							rgb = tonumber(hex, 16), family = family ~= "" and family
							or nil}
				end
			end
		end
	end
	local named = {}
	for _, n in ipairs(named_colours) do
		for _, g in ipairs(pk.groups) do
			if n.group == g then
				named[#named + 1] = n
			end
		end
	end
	picker_win = panel.color_picker({title = pk.title, rgb = e.ints[pk.field],
		named = named, query = pk.query,
		on_pick = function(rgb)
			send({{op = "set", ent = {id = pk.ent, ints = {[pk.field] = rgb}}}})
		end,
		on_query = function(q)
			pk.query = q
			build_picker()
		end,
		on_close = close_picker})
end

-- Which named colours fit a field of an entry: a wood's own colour is a
-- wood's, a stain a stain's, paint a paint's -- never the others'
local function colour_groups(p, field)
	if field == "base" then
		return ({[1] = {"wood"}, [2] = {"stone"}, [5] = {"glass"},
				[6] = {"metal"}, [7] = {"tile"}, [10] = {"wood"}})[p.kind] or {"paint"}
	elseif field == "color" then
		return p.finish == 2 and {"stain"} or {"paint"}
	end
	return p.kind == 7 and {"grout"} or p.kind == 2 and {"stone"} or {"paint"}
end

build_palette = function()
	if palette_win then
		-- Where its list was scrolled to, for the one made in its place
		if M.palette_view then
			M.palette_scroll = M.palette_view.viewPosition.y
		end
		palette_win:Remove()
	end
	M.palette_view = nil
	palette_win = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, S.panel_y or 50)
	if panel.folded("palette") then
		palette_win.visible = false
		return
	end
	-- **The palette folds to its title** (user): a click on the title
	-- row, or a right click that clears the selection, folds it, and it
	-- opens by itself when something new is selected or a tool it goes on
	-- is taken. Folded it is a dropdown's button saying the entry.
	local sel_now = S.primary or next(S.sel)
	if (sel_now and sel_now ~= S.palette_sel) or (S.tool ~= S.palette_tool and
			S.tool ~= "select" and S.tool ~= "node") or S.replacing then
		S.palette_collapsed = false
	end
	S.palette_sel, S.palette_tool = sel_now, S.tool
	local cur = default_material()
	if S.replacing then
		panel.label(palette_win, "Pick the entry to use instead:")
	else
		local ce = doc.ents[cur]
		panel.keep(function() return panel.mark(panel.button(palette_win,
				S.palette_collapsed and ce and
				("Palette: #" .. cur .. "  " .. ce.strs.name) or "Palette",
				function()
			S.palette_collapsed = not S.palette_collapsed
			refresh_panels()
		end), S.palette_collapsed and "▼" or "▲") end)
		if S.palette_collapsed then
			-- The colour picker goes with it; a voxel replace keeps its own
			if S.picker and not S.replace then
				close_picker()
			end
			return
		end
	end
	local entries = of_type("palette")
	-- **Over PALETTE_ROWS entries, a list that scrolls** (user: a plan of
	-- twenty materials made a column taller than the screen): the rows in a
	-- column of their own in a ScrollView of that many rows, the wheel and
	-- its bar scrolling it; where it was scrolled to is kept over the
	-- panel's rebuilds, and an entry newly picked is scrolled into view
	local PALETTE_ROWS = 8
	local ROW = 30 + 4
	local list, view = palette_win, nil
	if #entries > PALETTE_ROWS then
		-- Made first, so that it is where the entries were; the column it
		-- is given moves into it
		view = palette_win:CreateChild("ScrollView")
		list = palette_win:CreateChild("UIElement")
		list:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	end
	local cur_index, widest = nil, 0
	for i, p in ipairs(entries) do
		if p.id == cur then
			cur_index = i
		end
		local row = panel.swatch_row(list, palette_rgb(p.id), "#" .. p.id .. "  " ..
				p.strs.name .. "  (" .. MATERIAL_KINDS[p.ints.kind] .. ")",
				function()
			-- A second click on the same entry soon after is a double click:
			-- the entry goes on what is selected, as Apply does
			local now = buildat.get_time_us()
			local double = S.last_swatch == p.id and
					now - (S.last_swatch_us or 0) < 400000
			S.last_swatch, S.last_swatch_us = p.id, now
			if double and not S.replacing and next(S.sel) then
				S.material = p.id
				apply_material()
				refresh_panels()
				return
			end
			if S.replacing then
				if p.id ~= S.replacing then
					replace_entry(S.replacing, p.id)
				end
				S.replacing = nil
			end
			S.material = p.id
			refresh_panels()
		end, p.id == cur, p.id == cur and magic.Color(1.0, 0.85, 0.3) or nil)
		widest = math.max(widest, row.minWidth)
		if view then
			-- One height for all, which the scrolling counts in
			row:SetFixedHeight(30)
		end
	end
	if view then
		view:SetStyleAuto()
		-- Out of Tab's way, as the fields are what the keyboard is for
		view:SetFocusMode(magic.FM_NOTFOCUSABLE)
		view:SetScrollBarsVisible(false, true)
		view.scrollBarsAutoVisible = false
		view:SetFixedHeight(PALETTE_ROWS * ROW - 4)
		view:SetFixedWidth(widest + 20)
		list:SetFixedWidth(widest)
		view.contentElement = list
		-- At the panel's top left: it keeps where the window's layout had
		-- put it before it moved, which is below what the view shows
		list:SetPosition(0, 0)
		local y = M.palette_scroll or 0
		if cur_index and cur ~= M.palette_scrolled_to then
			local top = (cur_index - 1) * ROW
			local h = PALETTE_ROWS * ROW - 4
			if top < y or top + ROW > y + h then
				y = math.max(0, top - math.floor(h / 2))
			end
		end
		M.palette_scrolled_to = cur
		view.viewPosition = magic.IntVector2(0, y)
		M.palette_view = view
	end
	local e = doc.ents[cur]
	if S.picker and S.picker.ent ~= cur then
		close_picker()
	end
	build_picker()
	local function set(ints, strs)
		send({{op = "set", ent = {id = cur, ints = ints, strs = strs}}})
	end
	if e then
		local p = e.ints
		panel.field(palette_win, "Name", e.strs.name, function(t)
			set(nil, {name = t})
		end, 120, true)
		-- The types as a grid of their previews, opened under the button
		-- ([FP_TYPES]); Esc or the button again closes it
		if panel.view_only then
			panel.label(palette_win, "Type: " .. MATERIAL_KINDS[p.kind])
		else
			panel.mark(panel.button(palette_win, "Type: " .. MATERIAL_KINDS[p.kind],
					function()
				S.type_open = not S.type_open
				refresh_panels()
			end, S.type_open), S.type_open and "▲" or "▼")
		end
		if S.type_open and not panel.view_only then
			local tex = kind_previews()
			local r
			for k = 0, #MATERIAL_KINDS do
				if k % 4 == 0 then
					r = panel.row(palette_win)
				end
				panel.preview_button(r, tex, magic.IntRect(k * PREVIEW_PX, 0,
						(k + 1) * PREVIEW_PX, PREVIEW_PX), MATERIAL_KINDS[k],
						function()
					S.type_open = false
					if k ~= p.kind then
						-- A new type starts from its own look
						local d = KIND_DEFAULTS[k]
						set({kind = k, base = d.base, color2 = d.color2,
								scale = d.scale, roughness = d.roughness,
								specular = d.specular})
					end
					refresh_panels()
				end, k == p.kind)
			end
		end
		local function colour(label, name)
			local _, r = panel.field(palette_win, label,
					string.format("%06x", p[name]), function(t)
				local v = tonumber(t, 16)
				if v and v >= 0 and v <= 0xffffff then set({[name] = v}) end
			end, 90, true)
			panel.chip(r, p[name], 14, function()
				S.picker = {ent = cur, field = name, groups = colour_groups(p, name),
						title = e.strs.name .. ": " .. label}
				build_picker()
			end)
		end
		if p.kind ~= 4 then
			colour("Own colour", "base")
			colour("Paint", "color")
			panel.dropdown(palette_win, "Finish", {{FINISHES[0], 0},
					{FINISHES[1], 1}, {FINISHES[2], 2}}, p.finish, function(v)
				set({finish = v})
			end)
			if p.finish == 2 and p.kind ~= 5 then
				panel.field(palette_win, "Stain %", p.opacity / 10, function(t)
					local v = tonumber(t)
					if v then set({opacity = math.floor(v * 10 + 0.5)}) end
				end, 120)
			end
		end
		for _, k in ipairs(KNOBS[p.kind]) do
			if k == "color2" then
				colour(p.kind == 7 and "Grout colour" or p.kind == 3 and
						"Pattern" or "Veins", "color2")
			elseif k == "axis" then
				panel.dropdown(palette_win, "Grain", {{"along X", 0},
						{"along Y", 1}, {"along Z", 2}}, p.axis, function(v)
					set({axis = v})
				end)
			elseif k == "stagger" then
				panel.check(palette_win, "Staggered", p.stagger == 1, function()
					set({stagger = 1 - p.stagger})
				end)
			else
				local tenth = PERCENT[k] or TENTHS[k]
				local shown = tenth and p[k] / 10 or p[k]
				panel.field(palette_win, (k == "scale" and p.kind == 10 and
						"Board mm" or KNOB_LABELS[k]) .. (PERCENT[k] and " %"
						or ""), shown, function(t)
					local v = tonumber(t)
					if v then
						set({[k] = math.floor((tenth and v * 10 or v) + 0.5)})
					end
				end, 120, nil, TENTHS[k] and 1)
			end
		end
	end
	local r = panel.row(palette_win)
	panel.button(r, "New entry", function()
		local ph = doc.placeholder()
		local ints = e and copy_fields(e.ints) or {}
		send({{op = "create", ent = {id = ph, type = "palette", ints = ints,
				strs = {name = "material " .. (#entries + 1)}}}}, function(err)
			if err == "" then
				S.material = S.real[ph]
				refresh_panels()
			end
		end)
	end)
	if e and #entries > 1 then
		panel.button(r, "Replace", function()
			S.replacing = cur
			refresh_panels()
		end)
	end
end

end

-- The layouts window ([FP_LAYOUTS]), from the toolbar: each layout by its
-- group, to pick the one edited; the current one's own fields; a new floor
-- or building
place.build_window = function()
	if place.win then
		place.win:Remove()
		place.win = nil
	end
	if not S.layouts_open then
		return
	end
	local w = panel.window(magic.HA_CENTER, magic.VA_TOP, 0, S.panel_y or 50)
	place.win = w
	local function set(id, fields)
		send({{op = "set", ent = {id = id, ints = fields.ints,
				strs = fields.strs}}})
	end
	local function int_field(id, label, name, value)
		panel.field(w, label, value, function(t)
			local v = tonumber(t)
			if v then set(id, {ints = {[name] = math.floor(v + 0.5)}}) end
		end)
	end
	local top = panel.row(w)
	panel.label(top, "Layouts: click one to edit it")
	panel.keep(function() return panel.button(top, "Close", function()
		S.layouts_open = false
		refresh_panels()
	end) end)
	local list = doc.of_type("layout")
	table.sort(list, function(a, b)
		if a.strs.group ~= b.strs.group then
			return a.strs.group < b.strs.group
		end
		if a.ints.y ~= b.ints.y then
			return a.ints.y < b.ints.y
		end
		return a.id < b.id
	end)
	local groups, in_group = {}, 0
	local e = doc.ents[S.layout]
	for _, l in ipairs(list) do
		groups[l.strs.group] = true
		if e and l.strs.group == e.strs.group then
			in_group = in_group + 1
		end
		panel.keep(function() return panel.button(w, l.strs.group .. ": " ..
				l.strs.name, function()
			place.switch(l.id)
			refresh_panels()
		end, l.id == S.layout) end)
	end
	-- At the bottom for everyone: what the 3D view shows of the floors
	-- over this one (user)
	local function above_toggle()
		panel.keep(function() return panel.check(w, "Hide the floors above in 3D",
				S.hide_above, function()
			S.hide_above = not S.hide_above
			buildat.storage_write("hide_above", S.hide_above and "1" or "0")
			refresh_panels()
		end) end)
	end
	if not e or not doc.can("edit") then
		above_toggle()
		return
	end
	panel.label(w, "This one")
	local id, c = e.id, e.ints
	local function create(ints, strs)
		local ph = doc.placeholder()
		send({{op = "create", ent = {id = ph, type = "layout", ints = ints,
				strs = strs}}}, function(err)
			if err == "" then
				place.switch(real_id(ph))
				refresh_panels()
			end
		end)
	end
	panel.field(w, "Name", e.strs.name, function(t)
		set(id, {strs = {name = t}})
	end, nil, true)
	panel.field(w, "Group", e.strs.group, function(t)
		set(id, {strs = {group = t}})
	end, nil, true)
	int_field(id, "X mm", "x", c.x)
	int_field(id, "Y mm", "y", c.y)
	-- Under the building's lowest floor when it is above the ground
	local fm = doc.ents[c.mat_foundation]
	panel.label(w, "Foundation: " .. (fm and "'" .. fm.strs.name .. "' #" ..
			c.mat_foundation or "plain grey"))
	panel.button(w, "Foundation: the palette entry", function()
		set(id, {ints = {mat_foundation = default_material()}})
	end)
	int_field(id, "Z mm", "z", c.z)
	panel.field(w, "Yaw deg", c.yaw / 1000, function(t)
		local v = tonumber(t)
		if v then
			set(id, {ints = {yaw = math.floor(v * 1000 + 0.5) % 360000}})
		end
	end)
	local st = settings()
	int_field(doc.settings().id, "Floor to floor mm", "floor_step",
			st.floor_step)
	panel.button(w, "Add a floor above", function()
		-- Over the group's top one
		local top = c
		for _, l in ipairs(list) do
			if l.strs.group == e.strs.group and l.ints.y > top.y then
				top = l.ints
			end
		end
		create({x = top.x, y = top.y + st.floor_step, z = top.z, yaw = top.yaw},
				{name = "Floor " .. in_group, group = e.strs.group})
	end)
	-- **The lamps of a floor, or of all of them, at once** (user: lighting
	-- without wiring switches when the switches are not what is studied):
	-- as a switch does, off if any is on. A viewer's too, for themselves.
	local function lamps_button(text, layout)
		panel.keep(function() return panel.button(w, text, function()
			local lamps = {}
			for _, x in ipairs(doc.of_type("instance")) do
				if (not layout or x.ints.layout == layout) and is_lamp(x.id) then
					lamps[#lamps + 1] = x.id
				end
			end
			if #lamps == 0 then
				doc.notice(layout and "No lamps on this floor" or "No lamps")
				return
			end
			M.flip_lamps(lamps)
		end) end)
	end
	lamps_button("Lamps on this floor on/off", id)
	lamps_button("All lamps on/off", nil)
	panel.button(w, "New building", function()
		-- Beside the others, 20 m past the furthest
		local x, n = 0, 1
		for _, l in ipairs(list) do
			x = math.max(x, l.ints.x)
		end
		while groups["Building " .. n] or n == 1 and groups.Building do
			n = n + 1
		end
		create({x = x + 20000, y = 0, z = 0, yaw = 0},
				{name = "Ground floor", group = "Building " .. n})
	end)
	local empty = #list > 1
	for _, t in ipairs({"node", "instance", "image"}) do
		for _, x in ipairs(doc.of_type(t)) do
			if x.ints.layout == id then
				empty = false
			end
		end
	end
	if empty then
		panel.button(w, "Delete this layout", function()
			send({{op = "delete", ent = {id = id}}})
		end)
	end
	above_toggle()
end

refresh_panels = function()
	-- Nothing to show between plans; resume() draws them again
	if S.suspended then
		return
	end
	-- A field being typed in is not pulled from under the typing; the
	-- rebuild waits for the next change after it
	if doc.typing() then
		S.panels_stale = true
		return
	end
	S.panels_stale = false
	build_toolbar()
	-- Viewing ([FP_VIEW_EDIT]): the panels show everything and change
	-- nothing
	panel.view_only = not doc.can("edit")
	build_props()
	build_palette()
	place.build_window()
	panel.view_only = false
end
M.refresh_panels = function() refresh_panels() end

-- The pause menu ([FP_ESC]): what Esc opens at the bottom of any view, and
-- a level of its own, so Esc on it is Continue. Its Settings are the
-- planner's; the engine's are the launcher's.
local pause_win = nil
local open_pause, close_pause
-- For the toolbar's Menu, built before these are
M.open_pause = function() open_pause() end
do
	local function dialog(title)
		if pause_win then
			pause_win:Remove()
		end
		pause_win = panel.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
		pause_win.minWidth = 300
		panel.label(pause_win, title)
		return pause_win
	end

	-- **The plan's settings**, everyone's in it (user: out of the
	-- properties panel, which is for the selection and the tools, and a
	-- page of their own). A viewer gets the export.
	local function plan_settings_page()
		local w = dialog("Plan settings")
		local st = settings()
		local sid = doc.settings().id
		local edit = doc.can("edit")
		local function plan_int(label, name)
			panel.field(w, label, st[name], function(t)
				local v = tonumber(t)
				if v then
					send({{op = "set", ent = {id = sid,
							ints = {[name] = math.floor(v + 0.5)}}}})
				end
			end)
		end
		-- The plan's own, which a viewer reads
		panel.view_only = not edit
		do
			-- The grid's choice shows before the plan comes back with it
			local grids = {}
			for i, g in ipairs(GRID_STEPS) do
				grids[i] = {M.grid_text(g), g}
			end
			panel.dropdown(w, "Grid (" .. keys.name("grid") .. ")", grids, grid_step(), function(g)
				send({{op = "set", ent = {id = sid, ints = {grid = g}}}})
				st.grid = g
				plan_settings_page()
			end)
			plan_int("Ceiling mm", "ceiling")
			plan_int("Plan cut mm", "cut")
			-- The trees on the horizon (PBR): their height over their
			-- distance, 15 m at 200 m being 7.5
			panel.field(w, "Treeline %", st.treeline / 10, function(t)
				local v = tonumber(t)
				if v and v >= 0 then
					send({{op = "set", ent = {id = sid,
							ints = {treeline = math.floor(v * 10 + 0.5)}}}})
				end
			end)
			-- **The site and the moment the 3D view is lit for**
			-- ([FP_DAYLIGHT]): north, with where it is now said beside it
			-- -- where the camera points in 3D, where north is on the
			-- screen in the plan view -- the latitude, the date and the
			-- hour, a time-lapse and the ground
			local dl = M.daylight
			local nr = panel.row(w)
			panel.field(nr, "North deg", st.north, function(t)
				local v = tonumber(t)
				if v then
					send({{op = "set", ent = {id = sid,
							ints = {north = math.floor(v + 0.5) % 360}}}})
				end
			end)
			local where
			if S.view == "2d" then
				where = "North is at " .. dl.north_clock(st.north) .. " o'clock"
			else
				local fx, _, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
				where = "Pointing " .. dl.compass(st.north, fx, fz)
			end
			panel.label(nr, where)
			plan_int("Latitude deg", "latitude")
			-- The moment: saved, which only editing changes, or this
			-- client's own, which anyone does
			local temp = S.sun_temp ~= nil and S.sun_temp.plan == doc.plan_name
			panel.view_only = false
			panel.dropdown(w, "Daylight", {{"Saved", false},
					{"Temporary", true}}, temp, function(v)
				if v then
					S.sun_temp = {plan = doc.plan_name, day = M.plan_day(),
							minute = math.floor(M.plan_minute()),
							lapse = st.lapse, ground = st.ground}
				else
					S.sun_temp = nil
				end
				S.dirty = true
				plan_settings_page()
			end)
			panel.view_only = not edit and not temp
			local sun = M.sun()
			local function set_ints(ints)
				if temp then
					for k, v in pairs(ints) do
						S.sun_temp[k] = v
					end
					S.dirty = true
				else
					send({{op = "set", ent = {id = sid, ints = ints}}})
				end
			end
			-- A date or an hour typed in takes over from the real clock
			panel.field(w, "Date (d.m.)", dl.date_text(M.plan_day()), function(t)
				local d = dl.parse_date(t)
				if d then
					set_ints({day = d, minute = math.floor(M.plan_minute()),
							lapse = sun.lapse == -2 and 0 or sun.lapse})
				end
			end)
			local tr = panel.row(w)
			panel.field(tr, "Time (h:mm)", dl.time_text(math.floor(M.plan_minute())),
					function(t)
				local m = dl.parse_time(t)
				if m then
					set_ints({minute = m, day = M.plan_day(),
							lapse = sun.lapse < 0 and 0 or sun.lapse})
				end
			end)
			-- The time-lapse goes on from the hour and date it shows now
			-- A dropdown's choice shows before the plan comes back with it,
			-- as the grid's
			local function choose(ints)
				set_ints(ints)
				if not temp then
					for k, v in pairs(ints) do
						st[k] = v
					end
				end
				plan_settings_page()
			end
			panel.dropdown(tr, "Time-lapse", dl.LAPSES, sun.lapse, function(v)
				choose({lapse = v, minute = math.floor(M.plan_minute()),
						day = M.plan_day()})
			end)
			panel.dropdown(w, "Ground", dl.GROUNDS, sun.ground, function(v)
				choose({ground = v})
			end)
			panel.view_only = not edit
			-- The pictures in the save's images/, and the ones placed, locked
			for _, file in ipairs(doc.images) do
				panel.button(w, "Trace over " .. file, function()
					send({{op = "create", ent = {id = doc.placeholder(),
							type = "image", ints = {x = math.floor(S.cx),
							z = math.floor(S.cz)}, strs = {file = file}}}})
				end)
			end
			for _, im in ipairs(of_type("image")) do
				if im.ints.locked == 1 then
					panel.button(w, "Unlock " .. im.strs.file, function()
						send({{op = "set", ent = {id = im.id,
								ints = {locked = 0}}}})
						plan_settings_page()
					end)
				end
			end
		end
		panel.view_only = false
		panel.button(w, "Back", function() open_pause() end)
	end

	-- **This client's own settings**, kept here and nobody else's
	-- **The keys** (user: a key mapping menu like vanilla's): a row per
	-- action, its key a button; pressed, the next key down binds it --
	-- Escape leaves it, Backspace puts the default back. A key bound to
	-- two actions shows red on both, and either can be the one it does.
	-- Saved at once, in this client's storage (keys.lua).
	local function keys_page()
		local w = dialog("Keys")
		panel.label(w, "Press a key's button, then the new key.")
		panel.label(w, "Escape leaves it, Backspace puts back the default.")
		local cols = panel.row(w)
		local half = math.ceil(#keys.BINDINGS / 2)
		local col = panel.column(cols)
		for i, b in ipairs(keys.BINDINGS) do
			if i == half + 1 then
				col = panel.column(cols)
			end
			local r = panel.row(col)
			panel.label(r, b.what):SetFixedWidth(230)
			if b.action then
				local bt = panel.button(r, S.binding == b.action and "Press a key..." or
						keys.name(b.action), function()
					S.binding = b.action
					S.binding_t = buildat.get_time_us()
					keys_page()
				end, S.binding == b.action, 110)
				bt:SetFixedWidth(110)
				if keys.taken(b) then
					bt:GetChild(0):SetColor(magic.Color(1.0, 0.35, 0.3))
				end
			else
				panel.label(r, b.name, magic.Color(0.7, 0.7, 0.7)):SetFixedWidth(110)
			end
		end
		local r = panel.row(w)
		panel.button(r, "Defaults", function()
			S.binding = nil
			keys.defaults()
			refresh_panels()
			keys_page()
		end)
		panel.button(r, "Back", function()
			S.binding = nil
			open_pause()
		end)
	end
	M.keys_page = keys_page

	-- **The plan's viewports** (user, 2026-10-01): each one's name, a way
	-- to it, whether it brings its date and time with it and what they
	-- are; an editor also puts it where the camera is now, or deletes it.
	-- A viewer goes to them.
	local function viewports_page()
		local w = dialog("Viewports")
		local edit = doc.can("edit")
		local dl = M.daylight
		local list = M.viewports()
		if #list == 0 then
			panel.label(w, "None yet: \"Save viewport\" in the view dropdown,")
			panel.label(w, "in 3D or walking, saves the camera as one")
		end
		local function set(id, ints, strs)
			send({{op = "set", ent = {id = id, ints = ints, strs = strs}}},
					function() viewports_page() end)
		end
		for _, e in ipairs(list) do
			local v = e.ints
			panel.view_only = not edit
			panel.field(w, "Name", e.strs.name, function(t)
				if t ~= "" then
					set(e.id, nil, {name = t})
				end
			end, 160, true)
			panel.view_only = false
			local r = panel.row(w)
			panel.label(r, v.walk == 1 and "Walking" or "3D")
			-- (user) The camera there, the menu left open; Go to below goes
			-- to the one previewed
			panel.keep(function() return panel.button(r, "Preview", function()
				M.previewed = e.id
				M.go_viewport(e.id, true)
				viewports_page()
			end, M.previewed == e.id) end)
			if edit then
				if S.view ~= "2d" and not S.vp then
					panel.button(r, "Use this camera", function()
						local walk = S.view == "walk"
						set(e.id, {layout = S.layout,
								x = math.floor(S.pos.x * 1000 + 0.5),
								y = math.floor(S.pos.y * 1000 + 0.5),
								z = math.floor(S.pos.z * 1000 + 0.5),
								yaw = math.floor(S.yaw % 360 * 1000 + 0.5) % 360000,
								pitch = math.floor(S.pitch * 1000 + 0.5),
								walk = walk and 1 or 0,
								fov = math.floor((walk and S.walk_fov or 60) + 0.5)})
					end)
				end
				panel.button(r, "Delete", function()
					send({{op = "delete", ent = {id = e.id}}},
							function() viewports_page() end)
				end)
			end
			panel.view_only = not edit
			panel.check(w, "Recall its date and time", v.recall == 1, function()
				set(e.id, {recall = 1 - v.recall})
			end)
			local tr = panel.row(w)
			panel.field(tr, "Date (d.m.)", dl.date_text(v.day), function(t)
				local d = dl.parse_date(t)
				if d then
					set(e.id, {day = d})
				end
			end)
			panel.field(tr, "Time (h:mm)", dl.time_text(v.minute), function(t)
				local m = dl.parse_time(t)
				if m then
					set(e.id, {minute = m})
				end
			end)
			panel.view_only = false
			panel.label(w, " ")
		end
		local br = panel.row(w)
		panel.button(br, "Back", function() open_pause() end)
		local pv = M.previewed and doc.ents[M.previewed]
		if pv then
			panel.keep(function() return panel.button(br, "Go to " ..
					pv.strs.name, function()
				close_pause()
				M.go_viewport(pv.id)
			end) end)
		end
	end

	local function client_settings_page()
		local w = dialog("Client settings")
		local angles = {}
		for i = 1, #ANGLE_STEPS do
			angles[i] = {M.angle_text(i), i}
		end
		panel.dropdown(w, "Angle (" .. keys.name("angle") .. ")", angles, S.angle, function(i)
			S.angle = i
			client_settings_page()
		end)
		-- Muted, or full down to -30 dB, 6 dB at a time
		local mute, db = buildat.get_sound()
		local sounds = {{"muted", "muted"}}
		for v = 0, -30, -6 do
			sounds[#sounds + 1] = {v .. " dB", v}
		end
		panel.dropdown(w, "Sound", sounds, mute and "muted" or
				math.max(-30, math.floor(db / 6 + 0.5) * 6), function(v)
			if v == "muted" then
				buildat.set_sound(true, 0)
			else
				buildat.set_sound(false, v)
			end
			client_settings_page()
		end)
		-- The engine's render_scale: the 3D drawn at a share of the
		-- window's pixels, the UI sharp; the web has no launcher to set it
		-- in. Automatic is the client's choice, made again on each start
		-- and resize. A value not on the list is shown as the nearest one.
		local scale, auto = buildat.get_render_scale()
		local function pct(v)
			return math.floor(v * 100 + 0.5) .. " %"
		end
		local scales, near = {{"automatic (" .. pct(scale) .. ")", "auto"}}, 1
		for _, v in ipairs({0.25, 0.33, 0.5, 0.67, 0.75, 1}) do
			scales[#scales + 1] = {pct(v), v}
			if math.abs(v - scale) < math.abs(near - scale) then
				near = v
			end
		end
		panel.dropdown(w, "Render scale", scales, auto and "auto" or near,
				function(v)
			buildat.set_render_scale(v)
			client_settings_page()
		end)
		-- How the 3D view and walking are lit ([FP_DAYLIGHT])
		-- Lightest first
		panel.dropdown(w, "3D lighting", {{"Unlit: plain, and lighter", "unlit"},
				{"PBR: the plan's sun and sky", "pbr"},
				{"PBR + room cube maps", "pbr_cube"}}, S.lighting, function(v)
			S.lighting = v
			buildat.storage_write("lighting", v)
			set_view(S.view)
			client_settings_page()
		end)
		panel.check(w, "The plan in flat colours (" .. keys.name("flat") .. ")",
				S.plan_look, function()
			S.plan_look = not S.plan_look
			set_view(S.view)
			client_settings_page()
		end)
		panel.check(w, "Material ids shown", S.show_ids, function()
			S.show_ids = not S.show_ids
			S.dirty = true
			client_settings_page()
		end)
		panel.field(w, "Eye mm", S.eye, function(t)
			local v = tonumber(t)
			if v and v > 0 then
				S.eye = math.floor(v)
			end
		end)
		panel.field(w, "Walk FOV deg", S.walk_fov, function(t)
			local v = tonumber(t)
			if v then
				S.walk_fov = math.max(30, math.min(120, math.floor(v + 0.5)))
				buildat.storage_write("walk_fov", tostring(S.walk_fov))
			end
		end)
		panel.field(w, "Mouse sens. %", S.mouse_sens, function(t)
			local v = tonumber(t)
			if v then
				S.mouse_sens = math.max(10, math.min(500, math.floor(v + 0.5)))
				buildat.storage_write("mouse_sens", tostring(S.mouse_sens))
			end
		end)
		panel.field(w, "3D pan %", S.pan_speed, function(t)
			local v = tonumber(t)
			if v then
				S.pan_speed = math.max(10, math.min(1000, math.floor(v + 0.5)))
				buildat.storage_write("pan_speed", tostring(S.pan_speed))
			end
		end)
		panel.field(w, "Wheel zoom %", S.wheel_speed, function(t)
			local v = tonumber(t)
			if v then
				S.wheel_speed = math.max(10, math.min(500, math.floor(v + 0.5)))
				buildat.storage_write("wheel_speed", tostring(S.wheel_speed))
			end
		end)
		panel.check(w, "3D: the middle drag moves along the ground", S.pan_xz,
				function()
			S.pan_xz = not S.pan_xz
			buildat.storage_write("pan_xz", S.pan_xz and "1" or "0")
			client_settings_page()
		end)
		panel.check(w, "3D: the wheel zooms toward the cursor", S.zoom_to_cursor,
				function()
			S.zoom_to_cursor = not S.zoom_to_cursor
			buildat.storage_write("zoom_to_cursor", S.zoom_to_cursor and "1" or "0")
			client_settings_page()
		end)
		panel.button(w, "Back", function() open_pause() end)
	end

	-- **A copy of the plan** ([FP_COPY]): under a name no plan has, which
	-- is then the plan open; the server says so if the name is taken
	local function copy_page()
		local w = dialog("Copy this plan")
		panel.label(w, (doc.backup and "The backup of \"" .. doc.backup.of ..
				"\" from " .. doc.backup.label or "\"" .. doc.plan_name .. "\"") ..
				" as:")
		local e
		local function copy()
			local n = e:GetText()
			if n ~= "" then
				close_pause()
				doc.copy_plan(n)
			end
		end
		e = panel.field(w, "Name", doc.copy_name(), copy, 180)
		local r = panel.row(w)
		panel.button(r, "Copy", copy)
		panel.button(r, "Back", function() open_pause() end)
		e:SetFocus(true)
	end

	-- **Who may use the server** ([FP_ACCESS] 4), the admin's, and a
	-- user's own password: builtin/accounts' pages, which vanilla has too.
	-- The pause menu makes way for one, and its Back brings it back.
	local function account_page(open)
		if pause_win then
			pause_win:Remove()
			pause_win = nil
		end
		open(function() open_pause() end)
	end

	-- **Who may use this plan** ([FP_PLANS] 5): its owner's and an admin's.
	-- The server sends the list when they enter it and after every change.
	local members_page
	local PUBLIC_CHOICES = {{"cannot see it", 0}, {"can read", 1},
			{"can edit", 2}}
	local ROLE_CHOICES = {{"others'", ""}, {"reader", "viewer"},
			{"editor", "editor"}}

	local function delete_plan_page()
		local w = dialog("Delete the plan " .. doc.plan_name .. "?")
		panel.label(w, "Everyone in it goes back to the plans.")
		local r = panel.row(w)
		panel.button(r, "Delete", function()
			close_pause()
			doc.plan_admin("delete")
		end)
		panel.button(r, "Back", function() members_page() end)
	end

	members_page = function()
		S.pause_page = "members"
		local w = dialog("Members of " .. doc.plan_name)
		local message = doc.admin_message or ""
		local l = panel.label(w, message ~= "" and message or " ",
				magic.Color(1.0, 0.8, 0.4))
		l.minHeight = 22
		local m = doc.members
		if not m then
			panel.label(w, "Waiting for the server...")
			panel.button(w, "Back", function() open_pause() end)
			return
		end
		panel.label(w, "Owner: " .. (m.owner ~= "" and m.owner or "(none)"))
		panel.dropdown(w, "Others", PUBLIC_CHOICES, m.pub, function(v)
			doc.plan_admin("public", "", tostring(v))
		end)
		for _, member in ipairs(m.members) do
			if member.name ~= m.owner then
				local r = panel.row(w)
				local n = panel.label(r, member.name)
				n.minWidth = 140
				panel.dropdown(r, "Role", ROLE_CHOICES, member.role, function(v)
					doc.plan_admin("role", member.name, v)
				end)
			end
		end
		panel.button(w, "Delete this plan...", delete_plan_page)
		panel.button(w, "Back", function()
			doc.admin_message = nil
			open_pause()
		end)
	end
	M.members_changed = function()
		if pause_win and S.pause_page == "members" then
			members_page()
		end
	end

	-- **The plan's backups** ([FP_BACKUPS]), newest first: one opens to
	-- look at, and Copy this plan keeps it
	local function backups_page()
		S.pause_page = "backups"
		local w = dialog("Backups of " .. (doc.backup and doc.backup.of or
				doc.plan_name))
		local b = doc.backups
		if not b then
			panel.label(w, "Waiting for the server...")
		elseif #b.rows == 0 then
			panel.label(w, "None yet: one is made when the plan opens changed,")
			panel.label(w, "and each hour it is open and changes.")
		else
			panel.label(w, "Each opens view only.")
			for _, r in ipairs(b.rows) do
				local here = doc.backup and doc.plan_name:sub(-#r.id - 1) ==
						"-" .. r.id
				panel.button(w, r.label, function()
					close_pause()
					doc.open_backup(r.id)
				end, here)
			end
		end
		panel.button(w, "Back", function() open_pause() end)
	end
	-- Put back as the plan, after a yes: the plan as it is goes into a
	-- backup first
	local function restore_page()
		local w = dialog("Restore " .. doc.backup.of .. " to this backup?")
		panel.label(w, "It becomes as it was " .. doc.backup.label)
		panel.label(w, "for everyone in it. How it is now is kept")
		panel.label(w, "as a backup, which can be restored in turn.")
		local r = panel.row(w)
		panel.button(r, "Restore", function()
			close_pause()
			doc.restore_backup()
		end)
		panel.button(r, "Back", function() open_pause() end)
	end
	M.backups_changed = function()
		if pause_win and S.pause_page == "backups" then
			backups_page()
		end
	end

	open_pause = function()
		S.pause_page = nil
		S.paused = true
		-- A phone's address bar back with the menu, away without it
		buildat.set_web_fullscreen(false)
		S.press, S.drag = nil, nil
		update_capture()
		local version, hash = buildat.version()
		local w = dialog("Floor planner v." .. tostring(version) .. (hash and hash ~= "" and ("-" .. hash) or ""))
		-- Which plan this is, at a glance (user); a backup says so
		if doc.backup then
			local c = magic.Color(1.0, 0.85, 0.3)
			panel.label(w, "Backup of " .. doc.backup.of, c)
			panel.label(w, doc.backup.label, c)
			panel.label(w, "View only", c)
		else
			panel.label(w, "Plan: " .. (doc.plan_name or "?"),
					magic.Color(1.0, 0.85, 0.3))
		end
		S.pause_top = w
		panel.button(w, "Continue (Esc)", function() close_pause() end)
		-- Viewing or editing ([FP_VIEW_EDIT]): a plan opens for viewing, and
		-- editing goes back to it after 30 minutes without an edit
		local modes = {{"Viewing", false}}
		if doc.can("can_edit") then
			modes[2] = {"Editing", true}
		end
		panel.dropdown(w, "Mode", modes, doc.can("edit"), function(v)
			doc.set_editing(v)
		end)
		panel.button(w, "Plan settings...", plan_settings_page)
		panel.button(w, "Client settings...", client_settings_page)
		panel.button(w, "Keys...", keys_page)
		panel.button(w, "Viewports...", viewports_page)
		panel.button(w, "Chat...", function()
			account_page(doc.accounts.chat_page)
		end)
		if doc.privs.admin then
			panel.button(w, "Users...", function()
				account_page(doc.accounts.users_page)
			end)
		end
		if doc.privs.manage then
			panel.button(w, "Plan members...", function()
				doc.plan_admin("list")
				members_page()
			end)
		end
		if not doc.is_local then
			panel.button(w, "Change password...", function()
				account_page(doc.accounts.password_page)
			end)
		end
		-- Anyone makes a copy, which is theirs, and goes back to the plans
		-- ([FP_PLANS] 4, 5)
		panel.button(w, "Copy this plan...", copy_page)
		panel.button(w, "Backups...", function()
			doc.request_backups()
			backups_page()
		end)
		if doc.backup and doc.backup.restore == 1 then
			panel.button(w, "Restore this backup...", restore_page)
		end
		if doc.backup then
			panel.button(w, "Back to " .. doc.backup.of, function()
				close_pause()
				doc.open_plan(doc.backup.of)
			end)
		end
		panel.button(w, "Export this plan", function()
			close_pause()
			doc.export_plan()
		end)
		panel.button(w, "Other plan...", function()
			close_pause()
			doc.close_plan()
		end)
		-- A browser tab has no launcher to leave to, and is closed as a tab
		-- (only the web page sets BUILDAT_PAGE_HTTPS)
		if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
			panel.button(w, "Leave to the launcher", function() buildat.leave() end)
			panel.button(w, "Quit", function() buildat.quit() end)
		elseif not doc.is_local then
			-- The tab's way out, which also ends a kept login ([ACC_KEEP])
			panel.button(w, "Log out", doc.accounts.logout)
		end
	end

	close_pause = function()
		doc.accounts.close_page()
		if pause_win then
			pause_win:Remove()
			pause_win = nil
		end
		S.paused = false
		buildat.set_web_fullscreen(true)
		update_capture()
	end
	-- Whether the menu's first page is what is up
	function M.pause_top()
		return pause_win ~= nil and pause_win == S.pause_top
	end
	M.open_pause = function() open_pause() end
end

local function over_ui()
	local s = magic.ui.scale
	return panel.over({toolbar, props, palette_win, pause_win, picker_win,
			place.win, S.touch_bar, doc.accounts.page, panel.popup}, S.mx / s,
			S.my / s)
end

local press_target, plan_facing, plan_aligned, stream_drag, use, use_target, walk
-- For the touch bar, built before use is
M.use = function() use() end
do
	--
	-- Input
	--
	-- What a left press would take, for the select and node tools: the same
	-- pick for the click and for what the guide shows. In the select tool an
	-- object under the cursor wins, then a node near it, then the wall,
	-- picture or room it is on.
	-- **Leeway round the selection** (user): with something selected, a
	-- press that misses it by up to LEEWAY_PX still takes it; tried at
	-- points round the pointer, nearest first
	M.LEEWAY_PX = 12
	function M.near_selection()
		if not next(S.sel) then
			return nil
		end
		local mx, my = S.mx, S.my
		local found = nil
		for _, r in ipairs({M.LEEWAY_PX / 2, M.LEEWAY_PX}) do
			local d = M.px(r)
			for i = 0, 7 do
				local a = i * math.pi / 4
				S.mx, S.my = mx + math.cos(a) * d, my + math.sin(a) * d
				local s = pick_surface()
				if s and S.sel[s.id] then
					found = {kind = S.sel[s.id], id = s.id, side = S.sel_face[s.id]}
					break
				end
			end
			if found then
				break
			end
		end
		S.mx, S.my = mx, my
		return found
	end

	press_target = function()
		local x, z = cursor_floor()
		if S.tool == "select" then
			local s = pick_surface()
			if not (s and S.sel[s.id]) then
				local near = M.near_selection()
				if near then
					return near
				end
			end
			if s and s.kind == "instance" then
				-- With the part: a door's leaf is selected as its leaf
				return {kind = "instance", id = s.id, side = s.side}
			end
			local n = x and nearest_node(x, z, snap_radius())
			if n then
				return {kind = "node", id = n}
			elseif s then
				return {kind = (s.kind == "wall" or s.kind == "image") and s.kind or
						"room", id = s.id,
						-- A room is selected by its floor or, from under it, its
						-- ceiling, as a wall is by a face
						side = s.kind == "ceiling" and "ceiling" or
						s.kind == "floor" and "floor" or s.side}
			end
		elseif S.tool == "node" then
			local n = x and nearest_node(x, z, snap_radius())
			if n then
				return {kind = "node", id = n}
			end
		elseif S.tool == "box" then
			-- The selected object, to be moved by a drag
			local s = pick_surface()
			if s and s.kind == "instance" and S.sel[s.id] then
				return {kind = "instance", id = s.id, side = s.side}
			end
		end
		return nil
	end

	-- The material of what a click selected: a wall's by the face it was
	-- selected by, a room's floor, an object's own; nil for what has none of
	-- one (a voxel volume, a node, a picture)
	local function material_of(t)
		local e = t and doc.ents[t.id]
		if not e then
			return nil
		end
		if t.kind == "wall" then
			local w = e.ints
			local m = t.side == "left" and w.mat_left or t.side == "right" and
					w.mat_right or (w.mat_core ~= 0 and w.mat_core or w.mat_left)
			return m
		elseif t.kind == "room" then
			return t.side == "ceiling" and e.ints.mat_ceiling or e.ints.mat_floor
		elseif t.kind == "instance" then
			local def = doc.ents[e.ints.def].ints
			local m = DOOR_PARTS[t.side] and def[t.side] or 0
			return def.kind ~= KIND.voxel and (m ~= 0 and m or def.mat) or nil
		end
		return nil
	end

	-- A selection shows its material in the palette, to see and edit it
	local function palette_follows(t)
		local m = material_of(t)
		if m and m ~= 0 and doc.ents[m] then
			S.material = m
		end
	end

	local function begin_press(button)
		if button ~= magic.MOUSEB_LEFT or over_ui() then
			return
		end
		local x, z = cursor_floor()
		S.press = {mx = S.mx, my = S.my, x = x, z = z}
		if S.calib then
			return
		end
		if S.linking then
			local s = pick_surface()
			if s and s.kind == "instance" then
				S.press.target = {kind = "instance", id = s.id}
			end
			return
		end
		S.press.target = press_target()
	end

	local function start_drag()
		local t = S.press.target
		-- **With something selected, the Object tool places nothing** (user,
		-- 2026-10-01: a click to check what was just put in put in another):
		-- a drag of the selected object moves it, as Select's does, and one
		-- elsewhere ends as a click that lets go of the selection
		if S.tool == "box" and sel_count() > 0 and not t then
			return
		end
		if S.tool == "box" and not t then
			-- A lamp is placed with a click, its size its own
			local x, z = snapped_point(nil)
			if x and S.shape ~= "lamp" then
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
		-- The select tool: the drag moves the selection, and only what was
		-- selected before the press (user, 2026-10-01: a press that missed
		-- the selected object moved the room under it). A drag that starts
		-- on anything else is the box over what to select, as on nothing;
		-- a click selects it. A lone node drags alone.
		if not S.sel[t.id] then
			S.drag = {kind = "box"}
			return
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

	-- What a drag moves, as entity ids: what it locks and previews
	local function drag_ids(d)
		local ids = {}
		if d.kind == "node" then
			ids[1] = d.id
		elseif d.kind == "move" then
			for id in pairs(d.nodes) do
				ids[#ids + 1] = id
			end
			for id in pairs(d.inst) do
				ids[#ids + 1] = id
			end
		end
		return ids
	end

	-- The dragged things where the drag has them, for the others
	local function drag_preview(d)
		local ents = {}
		if d.kind == "node" then
			ents[1] = {id = d.id, ints = {x = d.x, z = d.z}}
		elseif d.kind == "move" then
			for id in pairs(d.nodes) do
				local x, z = node_pos(id)
				ents[#ents + 1] = {id = id, ints = {x = x, z = z}}
			end
			for id in pairs(d.inst) do
				local it = inst_data[id]
				if it and it.hosted then
					ents[#ents + 1] = {id = id, ints = {along = math.floor(
							it.along + 0.5)}}
				elseif it then
					ents[#ents + 1] = {id = id, ints = {x = math.floor(it.x + 0.5),
							z = math.floor(it.z + 0.5)}}
				end
			end
		end
		return ents
	end

	-- A drag of what can be moved takes its lock; refused, it is dropped
	local function lock_drag()
		local d = S.drag
		if not d or (d.kind ~= "node" and d.kind ~= "move") then
			return
		end
		doc.lock(drag_ids(d), function(why)
			if S.drag == d then
				S.drag = nil
				S.press = nil
				S.dirty = true
			end
			doc.notice(why)
		end)
	end

	local PREVIEW_SECONDS = 0.05
	local preview_timer = 0

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
			d.angle_lines = nil
			-- Off nodes and edges, the walls' angles before the grid
			if x and not ref.node and not ref.edge then
				local ends = {}
				for _, w in pairs(wall_data) do
					local other = w.a_node == d.id and w.b_node or
							w.b_node == d.id and w.a_node or nil
					if other and other ~= d.id then
						local ox, oz = node_pos(other)
						ends[#ends + 1] = {ox, oz}
					end
				end
				local cx, cz = cursor_floor()
				local ax, az, lines = M.angle_snap(cx, cz, ends)
				if ax then
					x, z, d.angle_lines = ax, az, lines
				end
			end
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
			-- **A door, window or opening dragged onto another wall goes
			-- into it** (user): where the pointer is on that wall
			d.rehost = nil
			local one, n = nil, 0
			for id in pairs(d.inst or {}) do
				one, n = id, n + 1
			end
			local oe = n == 1 and not next(d.nodes or {}) and doc.ents[one]
			if oe and oe.ints.host ~= 0 then
				local ps = pick_surface()
				local f = ps and ps.kind == "wall" and ps.id ~= oe.ints.host and
						wall_frame(ps.id)
				if f then
					local w = doc.ents[oe.ints.def].ints.w
					local along = geom.snap((ps.x - f.ax) * f.ux +
							(ps.z - f.az) * f.uz, grid_step())
					d.rehost = {wall = ps.id, along = math.max(w / 2,
							math.min(f.len - w / 2, along))}
				end
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
		if d.kind == "node" or d.kind == "move" then
			-- After the drag's batch, which the server takes first
			M.after_drag = true
		end
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
				for _, n in ipairs(of_type("node")) do
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
						S.sel_face[id] = nil
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
		elseif d.dx ~= 0 or d.dz ~= 0 or d.rehost then
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
				local it = inst_data[id]
				if i and it and it.hosted and d.rehost then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {host = d.rehost.wall,
							along = math.floor(d.rehost.along + 0.5)}}}
				elseif i and it and it.hosted then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {along = math.floor(it.along + 0.5)}}}
				elseif i then
					ops[#ops + 1] = {op = "set", ent = {id = id,
							ints = {x = i.x + d.dx, z = i.z + d.dz}}}
				end
			end
			send(ops)
		end
	end

	local function click()
		local t = S.press.target
		if S.calib and not S.calib.measured then
			local x, z = cursor_floor()
			if x then
				local c = S.calib
				c.pts[#c.pts + 1] = {x, z}
				if #c.pts == 2 then
					c.measured = geom.len(c.pts[2][1] - c.pts[1][1],
							c.pts[2][2] - c.pts[1][2])
					refresh_panels()
				end
			end
			return
		end
		if S.linking then
			-- A lamp clicked joins the switch's lamps, or leaves them
			local sw = doc.ents[S.linking]
			if t and t.kind == "instance" and sw and is_lamp(t.id) then
				local l, found = {}, false
				for _, v in ipairs(sw.lists.lamps) do
					if v == t.id then
						found = true
					else
						l[#l + 1] = v
					end
				end
				if not found then
					l[#l + 1] = t.id
				end
				send({{op = "set", ent = {id = S.linking, lists = {lamps = l}}}})
				doc.notice(found and "Unlinked" or "Linked")
			elseif t then
				doc.notice("That is not a lamp: a lamp is a box or voxels of a " ..
						"lamp material")
			end
			return
		end
		if S.tool == "select" then
			-- **What is selected, tapped again, opens its properties** when
			-- they are folded away (user, the sixth round): a phone has no
			-- other way to them from the view
			if t and S.sel[t.id] and not S.shift and panel.folded("props") then
				panel.toggle_fold("props")
			end
			if not S.shift then
				S.sel = {}
				S.primary = nil
			end
			if t then
				if S.sel[t.id] and S.shift then
					S.sel[t.id] = nil
				else
					S.sel[t.id] = t.kind
					S.sel_face[t.id] = t.side
					S.primary = t.id
					palette_follows(t)
				end
			end
			refresh_panels()
		elseif S.tool == "node" then
			-- A double click on an edge, off its nodes: a node into it
			local now = buildat.get_time_us()
			local double = S.last_node_click and
					now - S.last_node_click.t < 400000 and
					geom.len(S.mx - S.last_node_click.mx,
							S.my - S.last_node_click.my) < M.px(8)
			S.last_node_click = {t = now, mx = S.mx, my = S.my}
			if double and not t and doc.can("edit") then
				local x, z, ref = snapped_point(nil)
				if x and ref.edge and M.insert_node(x, z, ref) then
					S.last_node_click = nil
					return
				end
			end
			if not S.shift then
				S.nodes = {}
			end
			if t and t.kind == "node" then
				S.nodes[t.id] = not S.nodes[t.id] or nil
			end
			refresh_panels()
		elseif S.tool == "box" and sel_count() > 0 then
			-- The selected object clicked: nothing; elsewhere: let go of it,
			-- and the next click places
			if not t then
				S.sel, S.sel_face, S.primary = {}, {}, nil
				refresh_panels()
			end
		elseif S.tool == "box" then
			if not doc.can("edit") then
				doc.notice("Viewing only: no edit privilege")
				return
			end
			local x, z = snapped_point(nil)
			if x then
				if S.shape == "stairs" then
					add_box(x, z, S.stairs.w, nil)
				elseif S.shape == "lamp" then
					add_box(x, z, 250, 250)
				else
					add_box(x, z, S.box.w, S.box.d)
				end
			end
		elseif S.tool == "hosted" then
			-- **What is put in is not selected** (user, the tutorial: the
			-- door's properties hid the Kind of the next one). One clicked
			-- is, for its properties; any other click lets go of it.
			local s = pick_surface()
			local e = s and s.kind == "instance" and doc.ents[s.id]
			S.sel, S.sel_face, S.primary = {}, {}, nil
			if e and e.ints.host ~= 0 then
				S.sel[s.id] = "instance"
				S.sel_face[s.id] = s.side
				S.primary = s.id
				palette_follows({kind = "instance", id = s.id, side = s.side})
			elseif s and s.kind == "wall" and doc.can("edit") then
				add_hosted(s.id, s.x, s.z, s.side)
			end
			refresh_panels()
		elseif S.tool == "voxel" then
			voxel_edit(S.ctrl, S.shift)
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
				if s.kind == "instance" and inst_data[s.id].voxel then
					-- One voxel takes the material
					local hit = voxel_ray(s.id)
					if hit then
						doc.set_voxels(doc.ents[s.id].ints.def, {[doc.voxel_key(hit[1],
								hit[2], hit[3])] = default_material()})
					end
					return
				elseif s.kind == "instance" then
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

	-- The use key's, defined with it below

	-- Whether the 3D camera looks as the plan does: straight down, and north
	-- up within 10 degrees -- the plan has no other way up
	plan_facing = function()
		return S.pitch >= 89.5
	end

	plan_aligned = function()
		local off = (S.yaw % 360 + 180) % 360 - 180
		return plan_facing() and math.abs(off) <= 10
	end

	-- What a right or middle drag in 3D turns about or pans by: the point the
	-- pointer is on, in world metres -- the thing under it, or where its ray
	-- meets the floor -- or nil when it points at the sky. orbit: pointing
	-- at none of the plan, the middle of the box round the current
	-- layout's rooms, up to
	-- half their highest ceiling (user). An orbit about the floor, or the
	-- ground, turns about half the room's height over it (user)
	-- The middle of the box round the current layout's rooms (room_data is
	-- its, being built last), up to half their highest ceiling; nil
	-- without rooms
	function M.plan_middle()
		if not next(room_data) then
			return nil
		end
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		local top = 0
		for id, r in pairs(room_data) do
			for _, p in ipairs(r.pts) do
				x0, z0 = math.min(x0, p[1]), math.min(z0, p[2])
				x1, z1 = math.max(x1, p[1]), math.max(z1, p[2])
			end
			top = math.max(top, room_ceiling(doc.ents[id]))
		end
		return {x = W((x0 + x1) / 2), y = W(top / 2), z = W((z0 + z1) / 2)}
	end

	local function camera_pivot(orbit)
		local o, d = cursor_ray()
		local s = pick_surface()
		if s and s.t then
			local p = {x = o.x + d.x * s.t, y = o.y + d.y * s.t, z = o.z + d.z * s.t}
			if orbit and s.kind == "floor" then
				p.y = W(room_ceiling(doc.ents[s.id]) / 2)
			end
			return p
		end
		if orbit and next(room_data) then
			return M.plan_middle()
		end
		local x, z, t = ray_at_height(0)
		if x then
			return {x = o.x + d.x * t, z = o.z + d.z * t,
					y = orbit and W(settings().ceiling / 2) or 0}
		end
		return nil
	end

	function M.mouse_down(button)
		if S.paused then
			return
		end
		-- Walking on a touchscreen is the fingers' (M.touch_begin)
		if S.touch and S.view == "walk" and not over_ui() then
			return
		end
		-- A copy being put into a wall (copy_selected): a click on one puts
		-- it there, and a click on nothing does nothing
		if S.place_copy and button == magic.MOUSEB_LEFT and not over_ui() and
				not S.captured then
			local s = pick_surface()
			if s and s.kind == "wall" and doc.can("edit") then
				M.place_copy(s.id, s.x, s.z, s.side)
			end
			S.swallow_up = true
			return
		end
		if crosshair_view() and not S.captured and not over_ui() and
				button == magic.MOUSEB_LEFT then
			-- A click on the view goes up into the crosshair
			S.crosshair = true
			update_capture()
			S.swallow_up = true
			return
		end
		if S.captured and S.tool ~= "voxel" and button == magic.MOUSEB_RIGHT then
			-- Walking: the right button is Luanti's use, a door or a switch;
			-- with neither at the crosshair, it clears the selection as a
			-- right click does elsewhere (user)
			-- (the target at the crosshair, not the selected switch E takes)
			local s = pick_surface(true)
			if S.tool ~= "select" or s and s.kind == "instance" and
					use_target() == s.id then
				use()
			else
				S.sel, S.primary = {}, nil
				S.palette_collapsed = true
				S.dirty = true
				refresh_panels()
			end
			return
		end
		if S.captured and S.tool == "voxel" then
			-- Luanti's: the left button digs, the right one places -- and
			-- **held, a box** (user): from the cell pressed to the one let go
			-- on, both in; released where nothing is, nothing. A new volume
			-- when none is selected, on the press, as before.
			if button ~= magic.MOUSEB_LEFT and button ~= magic.MOUSEB_RIGHT then
				return
			end
			-- The other button while a box is held gives the box up, as Esc
			-- does (user); its own release is then nothing either
			if S.voxel_box then
				S.voxel_box.cancelled = true
				S.dirty = true
				return
			end
			if not voxel_target() then
				voxel_edit(button == magic.MOUSEB_LEFT, S.shift)
				return
			end
			local mode = button == magic.MOUSEB_RIGHT and "place" or
					S.shift and "paint" or "dig"
			local id, c = M.voxel_cell(mode)
			if id then
				S.voxel_box = {mode = mode, id = id, a = c, button = button}
				S.dirty = true
			end
			return
		end
		-- **The voxel tool at the pointer in 3D** (user): the left button
		-- does what the panel's Click says -- place, dig or paint -- Ctrl
		-- digs and Shift paints; held, a box. The right one orbits as ever.
		-- Pressed on nothing of the volume, it is a press as any other, so
		-- a finger's drag moves the view.
		if S.tool == "voxel" and S.view == "3d" and not S.captured and
				button == magic.MOUSEB_LEFT and not over_ui() then
			local mode = S.ctrl and "dig" or S.shift and "paint" or S.voxel_mode
			if S.voxel_box then
				S.voxel_box.cancelled = true
				S.dirty = true
				return
			end
			if not voxel_target() then
				if mode == "place" then
					voxel_edit(false, false)
					return
				end
			else
				local id, c = M.voxel_cell(mode)
				if id then
					S.voxel_box = {mode = mode, id = id, a = c, button = button}
					S.dirty = true
					return
				end
			end
		end
		if button == magic.MOUSEB_RIGHT then
			if S.draw or S.corners then
				S.draw = nil
				S.corners = nil
				S.typed = ""
				return
			end
			-- **A right click on a door's or a window's leaf opens or shuts
			-- it** (user): in 3D and walking, a right press that the mouse
			-- then hardly moves -- orbiting and turning are the right drag
			if not over_ui() then
				local s = pick_surface()
				S.right_click = {moved = 0,
						leaf = s and s.side == "mat_leaf" and s.id or nil,
						lamp = s and s.kind == "instance" and is_lamp(s.id) and
						s.id or nil}
			end
			if S.view == "2d" and not over_ui() then
				-- Into 3D as if it had been 3D all along ([FP_ORBIT_2D]): the
				-- camera straight above the plan's middle, looking down, as
				-- high as makes its floor the plan's; then this is an orbit
				local d = S.span / (2 * math.tan(math.rad(cam3d.fov) / 2))
				S.pos = {x = W(S.cx), y = W(d), z = W(S.cz)}
				S.yaw, S.pitch = 0, 90
				set_view("3d")
			end
			if S.view == "walk" and not over_ui() then
				-- Walking at the pointer: a right drag turns, as the mouse does
				-- in the crosshair
				S.looking = true
				magic.input:SetMouseMode(magic.MM_RELATIVE)
			end
			if S.view == "3d" then
				-- Orbiting what is pointed
				local p = camera_pivot(true)
				if p then
					S.orbit = p
					magic.input:SetMouseMode(magic.MM_RELATIVE)
				end
			end
			return
		end
		if button == magic.MOUSEB_MIDDLE then
			-- The plan and the 3D camera pan
			if S.view == "2d" then
				S.panning = true
			elseif S.view == "walk" and not S.captured then
				-- And a middle drag walks, as WASD do: up is forward
				if not over_ui() then
					S.walk_drag = true
					magic.input:SetMouseMode(magic.MM_RELATIVE)
				end
			elseif not S.captured then
				local p = camera_pivot()
				S.pan3d = {dist = p and geom.len(geom.len(p.x - S.pos.x,
						p.y - S.pos.y), p.z - S.pos.z) or 5}
				magic.input:SetMouseMode(magic.MM_RELATIVE)
			end
			return
		end
		begin_press(button)
	end

	function M.mouse_up(button)
		local vb = S.voxel_box
		if vb and vb.cancelled then
			-- Given up by the other button: both buttons' releases are
			-- nothing, and the box goes with the one that started it
			if button == vb.button then
				S.voxel_box = nil
			end
			return
		end
		if vb and button == vb.button then
			S.voxel_box = nil
			S.dirty = true
			local id, c = M.voxel_box_end(vb)
			if id == vb.id then
				M.voxel_box(vb.mode, id, vb.a, c)
			end
			return
		end
		if button == magic.MOUSEB_RIGHT and S.right_click then
			local rc = S.right_click
			S.right_click = nil
			if rc.leaf and rc.moved < 5 and doc.ents[rc.leaf] then
				S.orbit, S.pan3d = nil, nil
				if S.looking then
					S.looking = false
				end
				magic.input:SetMouseMode(magic.MM_ABSOLUTE)
				M.toggle_open(rc.leaf)
				return
			end
			-- And on a lamp switches it (user)
			if rc.lamp and rc.moved < 5 and doc.ents[rc.lamp] then
				S.orbit, S.pan3d = nil, nil
				if S.looking then
					S.looking = false
				end
				magic.input:SetMouseMode(magic.MM_ABSOLUTE)
				M.flip_lamps({rc.lamp})
				return
			end
			-- **A right click on what has no right click action clears the
			-- selection** (user), and folds the palette: the view cleared
			-- of its panels. The drag it may have started ends below.
			if rc.moved < 5 and S.tool == "select" and not S.captured then
				S.sel, S.primary = {}, nil
				S.palette_collapsed = true
				S.dirty = true
				refresh_panels()
			end
		end
		if S.swallow_up then
			S.swallow_up = false
			return
		end
		-- The first finger's lift: a drag of the view, or a gesture of two,
		-- ends without a click
		if S.touch_cam or S.gesture then
			S.touch_cam, S.panning, S.orbit, S.press = nil, false, nil, nil
			S.pan3d = nil
			return
		end
		if S.captured and (S.tool == "voxel" or button ~= magic.MOUSEB_LEFT) then
			return
		end
		if button == magic.MOUSEB_MIDDLE and S.walk_drag then
			S.walk_drag = false
			magic.input:SetMouseMode(magic.MM_ABSOLUTE)
			return
		end
		if (button == magic.MOUSEB_RIGHT and S.orbit) or
				(button == magic.MOUSEB_MIDDLE and S.pan3d) then
			local orbited = S.orbit
			S.orbit, S.pan3d = nil, nil
			magic.input:SetMouseMode(magic.MM_ABSOLUTE)
			if orbited and plan_aligned() then
				-- Back to the plan, where its floor is the view's: the middle
				-- where the view's middle meets the floor, the span what the
				-- camera's height sees
				local o = S.pos
				local f = {geom.rot(0, 0, 1, S.pitch, S.yaw, 0)}
				local t = f[2] < -1e-6 and -o.y / f[2] or 0
				S.cx = (o.x + f[1] * t) * 1000
				S.cz = (o.z + f[3] * t) * 1000
				S.span = math.max(500, math.min(200000, math.abs(o.y) * 1000 * 2 *
						math.tan(math.rad(cam3d.fov) / 2)))
				set_view("2d")
			end
			return
		end
		if button == magic.MOUSEB_RIGHT or (button == magic.MOUSEB_MIDDLE and
				S.looking) then
			S.panning = false
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
		if M.after_drag then
			M.after_drag = false
			doc.unlock()
		end
		S.press = nil
	end

	function M.mouse_move(x, y, dx, dy)
		if S.right_click then
			S.right_click.moved = S.right_click.moved + math.abs(dx) + math.abs(dy)
		end
		if S.orbit then
			-- The camera goes round the point with the view: its offset from
			-- the point is held in the camera's own frame, so the point stays
			-- where it was on the screen
			local p = S.orbit
			local ox, oy, oz = geom.unrot(S.pos.x - p.x, S.pos.y - p.y,
					S.pos.z - p.z, S.pitch, S.yaw, 0)
			-- A finger's orbit (the emulated mouse's) at half the mouse's
			-- speed (user)
			local k = 0.3 * S.mouse_sens / 100 * (S.touch and 0.5 or 1)
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-90, math.min(90, S.pitch + dy * k))
			local wx, wy, wz = geom.rot(ox, oy, oz, S.pitch, S.yaw, 0)
			S.pos = {x = p.x + wx, y = p.y + wy, z = p.z + wz}
			return
		end
		if S.pan3d then
			-- Across the view, as far as the pointed point moves under the
			-- pointer
			local _, h = screen_size()
			local k = S.pan3d.dist * 2 * math.tan(math.rad(cam3d.fov) / 2) / h *
					S.pan_speed / 100
			local rx, ry, rz = geom.rot(1, 0, 0, S.pitch, S.yaw, 0)
			local ux, uy, uz = geom.rot(0, 1, 0, S.pitch, S.yaw, 0)
			if S.pan_xz then
				-- Along the ground: the view's right and its forward, both
				-- level, the ground grabbed and pulled
				local fx, _, fz = geom.rot(0, 0, 1, 0, S.yaw, 0)
				local rl = geom.len(rx, rz)
				if rl > 1e-6 then
					rx, rz = rx / rl, rz / rl
				end
				ry = 0
				ux, uy, uz = fx, 0, fz
			end
			S.pos = {x = S.pos.x - (rx * dx - ux * dy) * k,
					y = S.pos.y - (ry * dx - uy * dy) * k,
					z = S.pos.z - (rz * dx - uz * dy) * k}
			return
		end
		if S.looking then
			local k = 0.15 * S.mouse_sens / 100
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-89, math.min(89, S.pitch + dy * k))
			return
		end
		if S.walk_drag then
			-- 10 mm a pixel, Shift two and a half times that as it runs
			local mm = S.shift and 25 or 10
			walk(0, -dy, dx, mm)
			return
		end
		S.mx, S.my = x, y
		if S.gesture then
			return
		end
		-- [FP_TOUCH] 3: a finger dragged anywhere but on the selection moves
		-- the view: the plan pans, the 3D camera orbits. The object tool's
		-- drag is its footprint's.
		if S.touch and S.press and not S.drag and S.tool ~= "box" and
				geom.len(x - S.press.mx, y - S.press.my) > M.px(DRAG_PX) then
			local t = S.press.target
			if not (t and (S.sel[t.id] or S.nodes[t.id])) then
				S.press = nil
				S.touch_cam = true
				if S.view == "2d" then
					S.panning = true
				else
					-- One finger pans, as the middle drag does (user: two
					-- orbit, which is the less often wanted)
					local p = camera_pivot()
					S.pan3d = {dist = p and geom.len(geom.len(p.x - S.pos.x,
							p.y - S.pos.y), p.z - S.pos.z) or 5}
				end
			end
		end
		if S.panning and S.view == "2d" then
			local k = mm_per_px()
			S.cx = S.cx - dx * k
			S.cz = S.cz + dy * k
		end
		if S.press and not S.drag and geom.len(x - S.press.mx, y - S.press.my) >
				M.px(DRAG_PX) then
			start_drag()
			lock_drag()
		end
		if S.drag then
			update_drag()
		end
	end

	-- The previews go out at most every PREVIEW_SECONDS
	stream_drag = function(dt)
		preview_timer = preview_timer + dt
		local d = S.drag
		if d and d.moved and (d.kind == "node" or d.kind == "move") and
				preview_timer >= PREVIEW_SECONDS then
			preview_timer = 0
			doc.preview(drag_preview(d))
		end
	end

	function M.mouse_wheel(wheel)
		if over_ui() then
			local sc = magic.ui.scale
			panel.nudge_at({toolbar, props, palette_win, pause_win, picker_win},
					S.mx / sc, S.my / sc, wheel > 0 and 1 or -1, S.shift)
			return
		end
		-- **A notch is a share of the distance** (user): 0.8 of it in and
		-- 1.25 out, to the speed setting's power -- the wheel is in notches,
		-- the web's in tenths (its SDL port counts them so)
		local notches = math.max(-10, math.min(10,
				S.web and wheel / 10 or wheel))
		local f = 0.8 ^ (notches * S.wheel_speed / 100)
		if S.view == "walk" then
			-- Walking: a metre a notch along the look, as it was
			local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
			S.pos = {x = S.pos.x + math.sin(yaw) * math.cos(pitch) * notches,
					y = S.pos.y - math.sin(pitch) * notches,
					z = S.pos.z + math.cos(yaw) * math.cos(pitch) * notches}
		elseif S.view == "2d" then
			-- Zoom about the cursor: the point under it stays under it
			local x0, z0 = cursor_floor()
			S.span = math.max(500, math.min(200000, S.span * f))
			local x1, z1 = cursor_floor()
			S.cx, S.cz = S.cx + x0 - x1, S.cz + z0 - z1
		else
			-- The distance: to what the pointer is on, else to the middle
			-- of the layout's rooms
			local o, d = cursor_ray()
			local s = pick_surface()
			local dist = s and s.t
			if not dist and next(room_data) then
				local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
				for _, rd in pairs(room_data) do
					for _, p in ipairs(rd.pts) do
						x0, z0 = math.min(x0, p[1]), math.min(z0, p[2])
						x1, z1 = math.max(x1, p[1]), math.max(z1, p[2])
					end
				end
				dist = geom.len(geom.len(W((x0 + x1) / 2) - S.pos.x, S.pos.y),
						W((z0 + z1) / 2) - S.pos.z)
			end
			dist = dist or 5
			-- Not through what is pointed at: 0.3 m short of it at most
			local step = math.min(dist * (1 - f), math.max(0, dist - 0.3))
			-- Along the view as it always was, or toward the cursor
			local dx, dy, dz = d.x, d.y, d.z
			if not S.zoom_to_cursor then
				local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
				dx, dy, dz = math.sin(yaw) * math.cos(pitch), -math.sin(pitch),
						math.cos(yaw) * math.cos(pitch)
			end
			S.pos = {x = S.pos.x + dx * step, y = S.pos.y + dy * step,
					z = S.pos.z + dz * step}
		end
	end

	-- **Fingers** ([FP_TOUCH] 3). The first is also the left mouse button,
	-- which SDL makes of it; these see every finger. Two pinch to zoom and
	-- move together to pan, and whatever the first began as the mouse is
	-- dropped. Walking: a finger put down at the lower left is a stick, and
	-- any other turns the view.
	function M.touch_begin(id, x, y)
		if doc.ui_hidden then
			M.show_ui()
			return
		end
		local sc = magic.ui.scale
		local on_ui = panel.over({toolbar, props, palette_win, pause_win,
				picker_win, place.win, S.touch_bar, doc.accounts.page,
				panel.popup},
				x / sc, y / sc)
		S.fingers[id] = {x = x, y = y, x0 = x, y0 = y, t0 = buildat.get_time_us(),
				ui = on_ui}
		if on_ui or S.paused then
			return
		end
		local w, h = screen_size()
		if S.view == "walk" then
			if not S.stick and x < w * 0.45 and y > h * 0.55 then
				S.fingers[id].stick = true
				S.stick = {f = 0, r = 0}
			end
			return
		end
		local n = 0
		for _, f in pairs(S.fingers) do
			if not f.ui then
				n = n + 1
			end
		end
		if n == 2 then
			if S.drag then
				S.drag = nil
				doc.unlock()
			end
			S.press, S.touch_cam, S.panning, S.orbit = nil, nil, false, nil
			S.pan3d = nil
			if S.voxel_box then
				S.voxel_box = nil
			end
			S.dirty = true
			-- Two fingers in 3D orbit round the plan's middle (a finger's
			-- own point is what should move, user) and pinch toward it
			local p = S.view == "3d" and (M.plan_middle() or camera_pivot(true))
			S.gesture = {pivot = p or nil, dist = p and geom.len(geom.len(
					p.x - S.pos.x, p.y - S.pos.y), p.z - S.pos.z) or 5}
		end
	end

	function M.touch_move(id, x, y, dx, dy)
		local f = S.fingers[id]
		if not f or f.ui then
			return
		end
		local px, py = f.x, f.y
		f.x, f.y = x, y
		if geom.len(x - f.x0, y - f.y0) > M.px(DRAG_PX) then
			f.moved = true
		end
		local w, h = screen_size()
		if f.stick then
			-- A tenth of the screen's short side is full speed
			local r = math.min(w, h) * 0.1
			S.stick.r = math.max(-1, math.min(1, (x - f.x0) / r))
			S.stick.f = math.max(-1, math.min(1, -(y - f.y0) / r))
			return
		end
		if S.view == "walk" then
			-- The mouse sensitivity setting's, at half of 0.2 (user)
			local k = 0.1 * S.mouse_sens / 100
			S.yaw = S.yaw + dx * k
			S.pitch = math.max(-89, math.min(89, S.pitch + dy * k))
			return
		end
		if not S.gesture then
			return
		end
		local o = nil
		for oid, of in pairs(S.fingers) do
			if oid ~= id and not of.ui then
				o = of
			end
		end
		if not o then
			return
		end
		-- The pair's middle moves half as far as this finger did, and their
		-- distance changes by the pinch
		local d0 = math.max(1, geom.len(px - o.x, py - o.y))
		local d1 = math.max(1, geom.len(x - o.x, y - o.y))
		local mdx, mdy = (x - px) / 2, (y - py) / 2
		if S.view == "2d" then
			S.mx, S.my = (x + o.x) / 2, (y + o.y) / 2
			local x0, z0 = cursor_floor()
			S.span = math.max(500, math.min(200000, S.span * d0 / d1))
			local x1, z1 = cursor_floor()
			local k = mm_per_px()
			S.cx = S.cx + (x0 or 0) - (x1 or 0) - mdx * k
			S.cz = S.cz + (z0 or 0) - (z1 or 0) + mdy * k
		else
			-- The pair's move orbits, as the right drag does, at a
			-- finger's speed
			local p = S.gesture.pivot
			if p then
				local ox, oy, oz = geom.unrot(S.pos.x - p.x, S.pos.y - p.y,
						S.pos.z - p.z, S.pitch, S.yaw, 0)
				local k = 0.15 * S.mouse_sens / 100
				S.yaw = S.yaw + mdx * k
				S.pitch = math.max(-90, math.min(90, S.pitch + mdy * k))
				local wx, wy, wz = geom.rot(ox, oy, oz, S.pitch, S.yaw, 0)
				S.pos = {x = p.x + wx, y = p.y + wy, z = p.z + wz}
			end
			-- Toward what the pair looks at, by as much as the pinch spreads:
			-- twice apart is half as far
			local fx, fy, fz = geom.rot(0, 0, 1, S.pitch, S.yaw, 0)
			local zoom = S.gesture.dist * (1 - d0 / d1)
			S.gesture.dist = S.gesture.dist - zoom
			S.pos = {x = S.pos.x + fx * zoom, y = S.pos.y + fy * zoom,
					z = S.pos.z + fz * zoom}
		end
	end

	-- A finger held still: the right button's, for what a finger can do
	-- with it -- a wall or a room being drawn ends, and a door or a switch
	-- is used
	function M.long_press()
		S.press = nil
		S.swallow_up = true
		if S.draw or S.corners then
			S.draw, S.corners, S.typed = nil, nil, ""
			doc.notice("Drawing ended")
		else
			use()
		end
	end

	function M.touch_end(id, x, y)
		local f = S.fingers[id]
		S.fingers[id] = nil
		if f and f.stick then
			S.stick = nil
		end
		-- Walking, a tap on a door, a window or a switch uses it (user: a
		-- touchscreen had no way to)
		if f and S.view == "walk" and not f.stick and not f.ui and
				not f.moved and not S.paused and
				buildat.get_time_us() - f.t0 < 500000 then
			S.mx, S.my = x, y
			local s = pick_surface(true)
			if s and s.kind == "instance" and use_target() then
				use()
			end
		end
		if not next(S.fingers) then
			S.gesture = nil
		end
	end

	-- The next other user's view becomes this one's
	local go_to_index = 0
	local function go_to_next_user()
		local peers = {}
		for peer, o in pairs(doc.others) do
			if o.p then
				peers[#peers + 1] = peer
			end
		end
		if #peers == 0 then
			doc.notice("Nobody else is here")
			return
		end
		table.sort(peers)
		go_to_index = go_to_index % #peers + 1
		local o = doc.others[peers[go_to_index]]
		local p = place.presence(o.p, true)
		if p.view >= 1 then
			S.pos = {x = p.px / 1000, y = p.py / 1000, z = p.pz / 1000}
			S.yaw, S.pitch = p.yaw / 1000, p.pitch / 1000
			set_view("3d")
		else
			S.cx, S.cz, S.span = p.px, p.pz, math.max(500, p.py)
			set_view("2d")
		end
		doc.notice("At " .. o.name .. "'s view")
	end

	-- Lamps all on or all off: off if any of them is on, else on. For the
	-- plan's editors for everybody; a viewer switches them for themselves.
	function M.flip_lamps(lamps)
		local any = false
		for _, l in ipairs(lamps) do
			any = any or lamp_on(l)
		end
		if doc.can("edit") then
			local ops = {}
			for _, l in ipairs(lamps) do
				S.local_on[l] = nil
				ops[#ops + 1] = {op = "set", ent = {id = l, ints = {on = any and 0 or 1}}}
			end
			send(ops)
		else
			for _, l in ipairs(lamps) do
				S.local_on[l] = not any
			end
			S.dirty = true
		end
	end

	-- A switch's lamps
	local function flip_switch(id)
		local lamps = doc.ents[id].lists.lamps
		if #lamps == 0 then
			doc.notice("This switch has no lamps; link some to it")
			return
		end
		M.flip_lamps(lamps)
	end

	-- The use key: a door or window under the cursor opens or closes. For an
	-- editor for everybody; a viewer opens it for themselves.
	-- What the use key would work: a door, a window or a switch under the
	-- cursor, or with nothing under it the switch selected. Returns its id and
	-- kind, or nil.
	use_target = function()
		local s = pick_surface(true)
		local id = s and s.kind == "instance" and s.id
		local p = S.primary and doc.ents[S.primary]
		if not id and p and p.type == "instance" and
				doc.ents[p.ints.def].ints.kind == KIND.switch then
			id = S.primary
		end
		local e = id and doc.ents[id]
		if not e then
			return nil
		end
		local kind = doc.ents[e.ints.def].ints.kind
		if kind == KIND.switch or kind == KIND.door or kind == KIND.window then
			return id, kind
		end
		-- A lamp on its own (user: as a door or a switch)
		if is_lamp(id) then
			return id, "lamp"
		end
		return nil
	end

	use = function()
		local id, kind = use_target()
		if not id then
			return
		end
		if kind == KIND.switch then
			flip_switch(id)
			return
		end
		if kind == "lamp" then
			M.flip_lamps({id})
			return
		end
		M.toggle_open(id)
	end

	-- Shut to 90 degrees open, anything open to shut: the plan's for an
	-- editor, the viewer's own otherwise
	function M.toggle_open(id)
		local open = open_amount(id) > 0 and 0 or 1000
		if doc.can("edit") then
			S.local_open[id] = nil
			send({{op = "set", ent = {id = id, ints = {open = open}}}})
		else
			S.local_open[id] = open
			S.dirty = true
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

	-- Up and Down in a numeric field step it; whether the key was that
	function M.nudge(key, shift)
		if key ~= magic.KEY_UP and key ~= magic.KEY_DOWN then
			return false
		end
		return panel.nudge_focused(key == magic.KEY_UP and 1 or -1, shift)
	end

	-- Down one level ([FP_ESC]): the pause menu, the crosshair, what is in
	-- progress; at the bottom of a view, the pause menu. Esc's, and the
	-- touch bar's Cancel ([FP_TOUCH] 4).
	function M.escape()
		if panel.popup then
			panel.close_popup()
		elseif S.voxel_box then
			-- The box given up; the button's release does nothing then
			S.voxel_box = nil
			S.dirty = true
		elseif S.drag then
			-- **A drag given up** (user): nothing moves, and the button's
			-- release that follows is not a click
			local was = S.drag
			S.drag, S.press = nil, nil
			if was.kind == "node" or was.kind == "move" then
				doc.unlock()
			end
			S.swallow_up = true
			S.dirty = true
			refresh_panels()
		elseif S.place_copy then
			S.place_copy = nil
			S.dirty = true
		elseif S.paused then
			close_pause()
		elseif S.picker or S.replace then
			close_picker()
		elseif S.type_open then
			S.type_open = false
			refresh_panels()
		elseif S.captured then
			S.crosshair = false
			update_capture()
		elseif S.draw or S.corners then
			S.draw = nil
			S.corners = nil
			S.typed = ""
		elseif S.linking then
			S.linking = nil
			refresh_panels()
		elseif S.calib then
			S.calib = nil
			refresh_panels()
		elseif S.tool ~= "select" then
			-- **A tool is a level of its own** (user): out of it to Select,
			-- and from Select to the pause menu. The same in every view,
			-- walking included, where the mouse's capture goes first.
			set_tool("select")
		else
			open_pause()
		end
	end

	-- A key being bound takes the next key ([the keys page])
	function M.capture_key(key)
		local action = S.binding
		-- Not the Enter or Space that pressed the key's button itself,
		-- which reaches here after the UI took it
		if not action or buildat.get_time_us() - (S.binding_t or 0) < 100000 then
			return false
		end
		S.binding = nil
		if key == magic.KEY_BACKSPACE then
			keys.set(action, nil)
		elseif key ~= magic.KEY_ESCAPE then
			keys.set(action, key)
		end
		refresh_panels()
		M.keys_page()
		return true
	end

	function M.key_down(key, event_data)
		if M.capture_key(key) then
			return
		end
		local qualifiers = event_data and event_data:GetInt("Qualifiers") or 0
		local ctrl = qualifiers % 4 >= 2
		-- Alt with anything is the window manager's: Alt+Tab switches windows,
		-- not views
		if qualifiers % 8 >= 4 then
			return
		end
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
			if key == magic.KEY_Z and S.shift or key == magic.KEY_Y then
				doc.redo()
			elseif key == magic.KEY_Z then
				doc.undo()
			elseif key == magic.KEY_D then
				copy_selected(false)
			elseif key == magic.KEY_L then
				copy_selected(true)
			end
			return
		end
		local function is(action)
			return key == keys.key(action)
		end
		if key == magic.KEY_ESCAPE then
			M.escape()
		elseif S.paused then
			-- The pause menu takes the keys: Up and Down go through it
			M.menu_key(key)
		elseif is("noclip") and S.view == "walk" then
			S.walk.noclip = not S.walk.noclip
			doc.notice(S.walk.noclip and "Noclip: walls do not stop you; " ..
					keys.name("up") .. " and " .. keys.name("down") ..
					" go up and down" or "Noclip off")
		elseif is("use") then
			use()
		elseif is("next_user") then
			go_to_next_user()
		elseif is("flat") then
			S.plan_look = not S.plan_look
			set_view(S.view)
		elseif is("view_2d") then
			M.pick_view("2d")
		elseif is("view_3d") then
			M.pick_view("3d")
		elseif is("view_walk") then
			M.pick_view("walk")
		elseif is("turn_left") then
			rotate_selection(angle_step())
		elseif is("turn_right") then
			rotate_selection(-angle_step())
		elseif is("hosted") then
			-- Again: the next of opening, door and window
			if S.tool == "hosted" then
				S.hosted = NEXT_HOSTED[S.hosted]
			end
			set_tool("hosted")
		elseif is("select") or is("node") or is("wall") or is("room") or
				is("box") or is("voxel") or is("paint") then
			for _, t in ipairs({"select", "node", "wall", "room", "box",
					"voxel", "paint"}) do
				if is(t) then
					set_tool(t)
					break
				end
			end
		elseif is("grid") then
			next_grid()
		elseif is("angle") then
			S.angle = S.angle % #ANGLE_STEPS + 1
			refresh_panels()
		elseif is("delete") then
			delete_selected()
		end
	end

	do
		--
		-- Walking
		--
		-- The voxels of the volumes near (x, z) as footprints, for the walker,
		-- in every layout: stairs go up to another
		-- simplified: a volume pitched or rolled is its bounding box
		local function layer_voxel_solids(insts, x, z, out)
			for id, it in pairs(insts) do
				if it.voxel and geom.len(x - it.x, z - it.z) < math.max(it.ex, it.ez) +
						BODY_R * 2 then
					if it.pitch % 360 ~= 0 or it.roll % 360 ~= 0 then
						out[#out + 1] = {pts = it.foot, y0 = it.y0, y1 = it.y1}
					else
						local sz = it.size
						for key in pairs(doc.voxels[doc.ents[id].ints.def] or {}) do
							local cx, cy, cz = doc.voxel_cell(key)
							local pts = {}
							for k, c in ipairs({{0, 0}, {1, 0}, {1, 1}, {0, 1}}) do
								local px, _, pz = geom.rot((cx + c[1]) * sz, 0,
										(cz + c[2]) * sz, 0, it.yaw, 0)
								pts[k] = {it.ox + px, it.oz + pz}
							end
							if not geom.is_ccw(pts) then
								pts = {pts[4], pts[3], pts[2], pts[1]}
							end
							out[#out + 1] = {pts = pts, y0 = it.oy + cy * sz,
									y1 = it.oy + (cy + 1) * sz}
						end
					end
				end
			end
		end
		local function voxel_solids(x, z, out)
			for _, l in ipairs(place.layers) do
				local r = l.rel
				local lx, _, lz = place.unpoint(r, x, 0, z)
				local list = {}
				layer_voxel_solids(l.insts, lx, lz, list)
				for _, sd in ipairs(list) do
					local pts = {}
					for k, q in ipairs(sd.pts) do
						local px, _, pz = place.point(r, q[1], 0, q[2])
						pts[k] = {px, pz}
					end
					out[#out + 1] = {pts = pts, y0 = sd.y0 + r.y, y1 = sd.y1 + r.y}
				end
			end
		end

	-- The walker at (x, z) with its feet at `feet`, pushed out of what it is
	-- in, and standing on the highest thing under it it can step onto
	-- simplified: it steps down at once rather than falling
	local function collide(x, z, feet)
		local list = {}
		for _, sd in ipairs(solids) do
			list[#list + 1] = sd
		end
		voxel_solids(x, z, list)
		-- The world's ground, where the current layout has it
		return geom.walk(list, x, z, feet, BODY_R, STEP, HEAD,
				place.rel(place.WORLD, place.current()).y)
	end

	-- dt: seconds of walking at the keys' speed, or mm: that far, which is
	-- a middle drag's
	walk = function(dt, f, r, mm)
		local input = magic.input
		local w = S.walk
		-- Shift runs; Ctrl is the shortcuts' (Ctrl+D is a copy)
		local speed = mm or (S.shift and 5250 or 2100) * dt
		local yaw = math.rad(S.yaw)
		local dx = (math.sin(yaw) * f + math.cos(yaw) * r) * speed
		local dz = (math.cos(yaw) * f - math.sin(yaw) * r) * speed
		if w.noclip then
			w.x, w.z = w.x + dx, w.z + dz
			local u = 0
			if keys.down("up") then u = u + 1 end
			if keys.down("down") then u = u - 1 end
			w.feet = w.feet + u * speed
		else
			w.x, w.z, w.feet = collide(w.x + dx, w.z + dz, w.feet)
		end
		S.pos = {x = w.x / 1000, y = (w.feet + S.eye) / 1000, z = w.z / 1000}
		place.follow(w)
	end

	end

end

--
-- Every frame
--
local function move_camera(dt)
	local input = magic.input
	S.shift = input:GetKeyDown(magic.KEY_LSHIFT) or
			input:GetKeyDown(magic.KEY_RSHIFT)
	S.ctrl = input:GetKeyDown(magic.KEY_LCTRL) or
			input:GetKeyDown(magic.KEY_RCTRL)
	if doc.typing() or S.ctrl then
		return
	end
	local f, r, u = 0, 0, 0
	if keys.down("forward") then f = f + 1 end
	if keys.down("back") then f = f - 1 end
	if keys.down("right") then r = r + 1 end
	if keys.down("left") then r = r - 1 end
	if S.view == "2d" then
		local k = S.span * dt
		S.cx = S.cx + r * k
		S.cz = S.cz + f * k
		return
	end
	if S.view == "walk" then
		if S.stick then
			f, r = f + S.stick.f, r + S.stick.r
		end
		walk(dt, f, r)
		return
	end
	if keys.down("up") then u = u + 1 end
	if keys.down("down") then u = u - 1 end
	local speed = (S.shift and 12 or 4) * dt
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

-- What each button would do, above the chat
local hud = magic.ui.root:CreateChild("Text")
hud:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 15)
hud:SetAlignment(magic.HA_CENTER, magic.VA_BOTTOM)
hud:SetPosition(0, -12)
hud:SetTextEffect(magic.TE_SHADOW)
hud:SetTextAlignment(magic.HA_CENTER)
hud.priority = 90
if S.touch then
	hud:SetWordwrap(true)
end

local crosshair = magic.ui.root:CreateChild("Text")
crosshair:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
crosshair:SetText("+")
crosshair:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
crosshair.visible = false
crosshair.priority = -10

-- A text over a place in the world, for this frame
local label_i = 0
-- The text each label was last set to (on M: the chunk is at Lua's
-- limit of 200 locals)
M.label_texts = {}
local function world_label(x_mm, y_mm, z_mm, text)
	label_i = label_i + 1
	local t = label_nodes[label_i]
	if not t then
		t = magic.ui.root:CreateChild("Text")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 13)
		t:SetTextEffect(magic.TE_SHADOW)
		-- Of the scene: under every panel and menu, whenever it was made
		t.priority = -10
		label_nodes[label_i] = t
	end
	local cam = S.view == "2d" and cam2d or cam3d
	local p = cam:WorldToScreenPoint(magic.Vector3(W(x_mm), W(y_mm), W(z_mm)))
	-- Set only when it changes: a text set is laid out again (user: a big
	-- plan panned slowly in Firefox)
	if M.label_texts[label_i] ~= text then
		M.label_texts[label_i] = text
		t:SetText(text)
	end
	t.visible = true
	local root = magic.ui.root
	t:SetPosition(math.floor(p.x * root.width) + 8,
			math.floor(p.y * root.height) - 18)
end

local function mm_text(v)
	return string.format("%d mm", math.floor(v + 0.5))
end

-- A user's colour, from their name
local function user_color(name)
	local h = 0
	for i = 1, #name do
		h = (h * 31 + name:byte(i)) % 360
	end
	local k = function(n)
		local x = (n + h / 30) % 12
		return 0.5 - 0.45 * math.max(-1, math.min(x - 3, 9 - x, 1))
	end
	return magic.Color(k(0), k(8), k(4))
end

-- A door's swing or a window's glass as a plan draws them: a door open
-- square to the wall with the arc it sweeps, a window as two lines
local function plan_symbol(id, it, line)
	local def = doc.ents[it.def].ints
	local e = doc.ents[id].ints
	local f = it.frame
	local col = magic.Color(0.2, 0.2, 0.25)
	local function at(a, c)
		-- A point a along the wall from the centre, c across it
		return f.ax + f.ux * (it.along + a) + f.nx * c,
				f.az + f.uz * (it.along + a) + f.nz * c
	end
	local hw = def.w / 2
	local mid = (f.lo - f.ro) / 2
	if def.kind == KIND.switch then
		local pts = it.foot
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			line(p[1], p[2], q[1], q[2], col)
		end
	elseif def.kind == KIND.window then
		for _, c in ipairs({mid - 15, mid + 15}) do
			local ax, az = at(-hw, c)
			local bx, bz = at(hw, c)
			line(ax, az, bx, bz, col)
		end
	elseif def.kind == KIND.door then
		local right = e.flip % 2 == 1
		local side = math.floor(e.flip / 2) % 2 == 1 and -1 or 1
		local face = side > 0 and f.lo or -f.ro
		local hinges = def.leaf == 1 and {{-hw, 1, hw}, {hw, -1, hw}} or
				{{right and hw or -hw, right and -1 or 1, 2 * hw}}
		for _, h in ipairs(hinges) do
			local r = h[3]
			local hx, hz = at(h[1], face)
			local ox, oz = at(h[1], face + side * r)
			line(hx, hz, ox, oz, col)
			local steps = 12
			local px, pz = at(h[1] + h[2] * r, face)
			for k = 1, steps do
				local a = k / steps * math.pi / 2
				local qx, qz = at(h[1] + h[2] * r * math.cos(a),
						face + side * r * math.sin(a))
				line(px, pz, qx, qz, col)
				px, pz = qx, qz
			end
		end
	end
end

--
-- The guides: what the pointer is on, highlighted, and what each button
-- would do to it, said ([FP_GUIDES]). compute_guide() makes the same picks
-- the clicks do, so what is shown is what is done.
--
local compute_guide, draw_guide, guide_text
do
	local HOVER = magic.Color(0.2, 0.9, 1.0)
	local DIG = magic.Color(1, 0.3, 0.2)
	local PLACE = magic.Color(0.2, 1, 0.3)
	-- What a right click does something to (user): a door's leaf to open
	-- or shut
	local RIGHT = magic.Color(1.0, 0.55, 0.1)

	local function name_of(id)
		local e = doc.ents[id]
		if not e then
			return "?"
		end
		if e.type == "instance" then
			local kind = doc.ents[e.ints.def].ints.kind
			return (kind == KIND.voxel and "voxels" or
					KIND_NAMES[kind]:lower()) .. " " .. id
		elseif e.type == "room" then
			return "room '" .. e.strs.name .. "'"
		elseif e.type == "image" then
			return "the picture " .. e.strs.file
		end
		return e.type .. " " .. id
	end

	local function mat_text(m)
		local e = m and m ~= 0 and doc.ents[m]
		if not e then
			return "no material"
		end
		return "'" .. e.strs.name .. "' #" .. m
	end

	local function cell_of(id, c)
		local e = doc.ents[id]
		local m = (doc.voxels[e.ints.def] or {})[doc.voxel_key(c[1], c[2], c[3])]
		return m
	end

	compute_guide = function()
		if S.paused or (over_ui() and not S.captured) then
			return nil
		end
		-- At the pointer of a view with a crosshair, a click goes up into it
		if crosshair_view() and not S.captured then
			local walking = S.view == "walk"
			local g = {hl = {}, left = walking and
					"into the crosshair: walk, look and point (Esc: back)" or
					"into the crosshair to dig and place (Esc: back)",
					right = walking and "drag: turn" or nil,
					middle = walking and "drag: walk" or nil}
			-- A click on a door's leaf opens or shuts it (mouse_up)
			local s = walking and pick_surface()
			if s and s.side == "mat_leaf" and doc.ents[s.id] then
				g.right = "click: " .. (open_amount(s.id) > 0 and "close " or
						"open ") .. name_of(s.id) .. "; drag: turn"
				g.hl[1] = {kind = "leaves", id = s.id, col = RIGHT}
			elseif s and s.kind == "instance" and is_lamp(s.id) then
				g.right = "click: switch " .. name_of(s.id) ..
						(lamp_on(s.id) and " off" or " on") .. "; drag: turn"
				g.hl[1] = {kind = "instance", id = s.id, col = RIGHT}
			end
			return g
		end
		local g = {hl = {}}
		local function hl(t)
			g.hl[#g.hl + 1] = t
		end
		-- The camera's buttons
		if S.view == "2d" then
			g.middle = "drag: pan the plan"
			g.right = "drag: into 3D, orbiting round the pointer"
		elseif S.orbit and plan_facing() then
			g.right = plan_aligned() and "let go: back to the plan view" or
					"turn it north-up to let go into the plan view"
		elseif not S.captured then
			local s = pick_surface()
			g.right = (s or not next(room_data)) and
					"drag: orbit round what the pointer is on" or
					"drag: orbit round the middle of the plan"
			-- A click on a door's leaf opens or shuts it (mouse_up)
			if s and s.side == "mat_leaf" and doc.ents[s.id] then
				g.right = "click: " .. (open_amount(s.id) > 0 and "close " or
						"open ") .. name_of(s.id) .. "; " .. g.right
				hl({kind = "leaves", id = s.id, col = RIGHT})
			elseif s and s.kind == "instance" and is_lamp(s.id) then
				g.right = "click: switch " .. name_of(s.id) ..
						(lamp_on(s.id) and " off" or " on") .. "; " .. g.right
				hl({kind = "instance", id = s.id, col = RIGHT})
			end
			g.middle = "drag: pan the view"
		end
		local cur = default_material()
		local edit = doc.can("edit")
		-- The use key
		local uid, ukind = use_target()
		if uid then
			local what
			if ukind == KIND.switch then
				local any = false
				for _, l in ipairs(doc.ents[uid].lists.lamps) do
					any = any or lamp_on(l)
				end
				what = "switch " .. name_of(uid) .. "'s lamps " ..
						(any and "off" or "on")
			elseif ukind == "lamp" then
				what = "switch " .. name_of(uid) .. (lamp_on(uid) and " off" or " on")
			else
				what = (open_amount(uid) > 0 and "close " or "open ") .. name_of(uid)
			end
			g.use = what
			hl({kind = "instance", id = uid, col = PLACE})
			if S.captured and S.tool ~= "voxel" then
				g.right = what
				-- The right button is the use key there: its colour
				hl({kind = (ukind == KIND.switch or ukind == "lamp") and
						"instance" or "leaves", id = uid, col = RIGHT})
			end
		end
		if S.calib then
			local x, z = cursor_floor()
			if x and not S.calib.measured then
				hl({kind = "point", x = x, z = z})
				g.left = "calibration point " .. (#S.calib.pts + 1) .. " of 2 here"
			end
			g.note = "Esc: stop calibrating"
			return g
		end
		if S.linking then
			local s = pick_surface()
			if s and s.kind == "instance" and is_lamp(s.id) then
				hl({kind = "instance", id = s.id})
				local linked = false
				for _, l in ipairs(doc.ents[S.linking].lists.lamps) do
					linked = linked or l == s.id
				end
				g.left = (linked and "unlink " or "link ") .. name_of(s.id) ..
						(linked and " from " or " to ") .. name_of(S.linking)
			end
			g.note = "Linking lamps: point at a lamp; Esc: done"
			return g
		end
		local tool = S.place_copy and "place_copy" or S.tool
		if tool == "select" or tool == "node" then
			local t = press_target()
			if t then
				hl({kind = t.kind == "room" and t.side == "ceiling" and "ceiling" or
						t.kind, id = t.id})
				local name = name_of(t.id)
				if S.shift then
					g.left = (S.sel[t.id] and "take " .. name .. " out of" or
							"add " .. name .. " to") .. " the selection"
				elseif S.sel[t.id] or S.nodes[t.id] then
					g.left = (S.sel[t.id] and panel.folded("props") and
							"its properties" or "keep " .. name .. " selected") ..
							(edit and "; drag: move the selection" or "")
				else
					g.left = "select " .. name .. (t.kind == "wall" and t.side and
							(" by its " .. (t.side == "core" and "top" or
							t.side .. " face")) or t.kind == "room" and t.side and
							(" by its " .. t.side) or "") .. "; drag: select by a box"
				end
				if t.kind == "node" and edit then
					g.left = g.left .. " (onto another node: merge them)"
				end
			else
				g.left = (next(S.sel) or next(S.nodes)) and
						"clear the selection; drag: select by a box" or
						"drag: select by a box"
			end
		elseif tool == "wall" or tool == "room" then
			local from = tool == "wall" and S.draw or
					(S.corners and S.corners[#S.corners])
			local x, z, ref = snapped_point(from)
			if x and edit then
				local at = ref.node and " at node " .. ref.node or ref.edge and
						(ref.edge.wall and ", splitting wall " .. ref.edge.wall or
						" on a room's edge") or ""
				if ref.node then
					hl({kind = "node", id = ref.node})
				elseif ref.edge then
					hl({kind = "edge", u = ref.edge.u, v = ref.edge.v})
				end
				if tool == "wall" then
					g.left = (S.draw and "end the wall here" or "start a wall here") .. at
				else
					local first = S.corners and S.corners[1]
					if first and #S.corners >= 3 and
							geom.len(x - first.x, z - first.z) <= snap_radius() then
						g.left = "close the room: " .. #S.corners .. " corners"
					else
						g.left = "corner " .. ((S.corners and #S.corners or 0) + 1) ..
								" here" .. at
					end
				end
				if from then
					g.right = "stop drawing"
					g.note = "Type a length and Enter to draw it that long"
				end
			end
		elseif tool == "box" then
			local x, z = snapped_point(nil)
			if x and edit then
				hl({kind = "point", x = x, z = z})
				g.left = S.shape == "lamp" and "put a plafond lamp on the ceiling here" or
						S.shape == "stairs" and "put stairs here, " ..
						S.stairs.w .. " mm wide, of " .. mat_text(cur) ..
						"; drag: draw their footprint" or
						"put a box here, " .. S.box.w .. " x " .. S.box.d ..
						" mm, of " .. mat_text(cur) .. "; drag: draw its footprint"
			end
		elseif tool == "place_copy" then
			local src = doc.ents[S.place_copy.id]
			local s = pick_surface()
			local f = s and s.kind == "wall" and wall_frame(s.id)
			g.left = "click a wall to put the " .. (S.place_copy.linked and
					"linked clone" or "copy") .. " in (Esc: no copy)"
			if f and src then
				local d = doc.ents[src.ints.def].ints
				local along = geom.snap((s.x - f.ax) * f.ux + (s.z - f.az) * f.uz,
						grid_step())
				along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
				hl({kind = "wall", id = s.id})
				hl({kind = "opening", frame = f, along = along, w = d.w,
						sill = src.ints.sill, h = d.h})
				g.left = "put the " .. (S.place_copy.linked and "linked clone" or
						"copy") .. " into wall " .. s.id .. ", " ..
						math.floor(along + 0.5) .. " mm along it (Esc: no copy)"
			end
		elseif tool == "hosted" then
			local s = pick_surface()
			local f = s and s.kind == "wall" and wall_frame(s.id)
			if f and edit then
				local d = HOSTED[S.hosted]
				local along = geom.snap((s.x - f.ax) * f.ux + (s.z - f.az) * f.uz,
						grid_step())
				along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
				hl({kind = "wall", id = s.id})
				hl({kind = "opening", frame = f, along = along, w = d.w,
						sill = d.sill, h = d.h})
				g.left = "put " .. KIND_NAMES[S.hosted]:lower() .. " into wall " ..
						s.id .. ", " .. math.floor(along + 0.5) .. " mm along it"
			end
		elseif tool == "voxel" then
			local id = voxel_target()
			if not edit then
			elseif not id then
				local x, z = snapped_point(nil)
				if x then
					hl({kind = "point", x = x, z = z})
					local what = "start a voxel volume here, of " .. mat_text(cur)
					if S.captured then
						g.right = what
					else
						g.left = what
					end
				end
			elseif S.view == "2d" then
				local cx, cz, top = voxel_column(id)
				if cx then
					local y = top and top + 1 or 0
					hl({kind = "cell", id = id, c = {cx, y, cz}, col = PLACE})
					g.left = "a voxel of " .. mat_text(cur) .. " on the column, layer " .. y
					if top then
						g.left = g.left .. "; Ctrl+Left: take the top one (" ..
								mat_text(cell_of(id, {cx, top, cz})) .. ") off" ..
								"; Shift+Left: make it " .. mat_text(cur)
					end
				end
			elseif S.voxel_box and S.voxel_box.cancelled then
				g.left = "given up: let go of the buttons"
			elseif S.voxel_box and S.voxel_box.id == id then
				-- The box a release here would make, from where it was pressed
				local vb = S.voxel_box
				local ok, c = M.voxel_box_end(vb)
				local col = vb.mode == "place" and PLACE or DIG
				if ok then
					hl({kind = "cell", id = id, c = vb.a, c2 = c, col = col})
					local n = (math.abs(c[1] - vb.a[1]) + 1) *
							(math.abs(c[2] - vb.a[2]) + 1) * (math.abs(c[3] - vb.a[3]) + 1)
					g.left = "let go: " .. ({place = "fill", dig = "empty",
							paint = "paint"})[vb.mode] .. " " .. n .. " cells; Esc: none"
				else
					hl({kind = "cell", id = id, c = vb.a, col = col})
					g.left = "let go here: nothing (point at the volume); Esc: none"
				end
			else
				local hit, place = voxel_ray(id)
				local pok, pc = M.voxel_cell("place")
				if not S.captured then
					-- At the pointer: the left button by the panel's Click
					local mode = S.ctrl and "dig" or S.shift and "paint" or
							S.voxel_mode
					if mode == "place" and pok then
						hl({kind = "cell", id = id, c = pc, col = PLACE})
						g.left = "place a voxel of " .. mat_text(cur) ..
								" here (hold: a box); Ctrl: dig, Shift: paint"
					elseif mode ~= "place" and hit then
						hl({kind = "cell", id = id, c = hit, col = DIG})
						g.left = (mode == "dig" and "dig this voxel (" ..
								mat_text(cell_of(id, hit)) .. ")" or "make this voxel " ..
								mat_text(cur)) .. " (hold: a box)"
					end
					hit = nil
				elseif hit then
					hl({kind = "cell", id = id, c = hit, col = DIG})
					g.left = "dig this voxel (" .. mat_text(cell_of(id, hit)) ..
							"); Shift+click: make it " .. mat_text(cur)
				end
				if pok and S.captured then
					hl({kind = "cell", id = id, c = pc, col = PLACE})
					g.right = "place a voxel of " .. mat_text(cur) ..
							" here (hold: a box)"
				end
				if hit then
					g.left = g.left .. " (hold: a box)"
				end
			end
		elseif tool == "paint" then
			local s = pick_surface()
			if s and edit then
				local old
				if s.kind == "instance" and inst_data[s.id].voxel then
					local hit = voxel_ray(s.id)
					if hit then
						hl({kind = "cell", id = s.id, c = hit})
						g.left = "make this voxel " .. mat_text(cur) .. " (now " ..
								mat_text(cell_of(s.id, hit)) .. ")"
					end
				elseif s.kind == "instance" then
					hl({kind = "instance", id = s.id})
					old = doc.ents[doc.ents[s.id].ints.def].ints.mat
					g.left = "make " .. name_of(s.id) .. " " .. mat_text(cur) ..
							" (now " .. mat_text(old) .. ")"
				elseif s.kind == "wall" then
					local w = doc.ents[s.id].ints
					hl({kind = "face", id = s.id, side = s.side})
					old = s.side == "left" and w.mat_left or s.side == "right" and
							w.mat_right or (w.mat_core ~= 0 and w.mat_core or w.mat_left)
					g.left = "make wall " .. s.id .. "'s " .. (s.side == "core" and
							"top and ends" or s.side .. " face") .. " " .. mat_text(cur) ..
							" (now " .. mat_text(old) .. ")"
				elseif s.kind == "floor" or s.kind == "ceiling" then
					local r = doc.ents[s.id]
					hl({kind = s.kind, id = s.id})
					old = s.kind == "floor" and r.ints.mat_floor or r.ints.mat_ceiling
					g.left = "make " .. name_of(s.id) .. "'s " .. s.kind .. " " ..
							mat_text(cur) .. " (now " .. mat_text(old) .. ")"
				end
			end
		end
		return g
	end

	guide_text = function(g)
		if not g then
			return ""
		end
		local lines = {}
		-- A touchscreen's are what the last tap did, and holding still
		-- ([FP_TOUCH] 4); the mouse's other buttons are its gestures
		local names = S.touch and {{"left", "Tap"}, {"use", "Hold"}} or
				{{"left", "Left"}, {"right", "Right"}, {"middle", "Middle"},
				{"use", keys.name("use")}}
		for _, b in ipairs(names) do
			local t = g[b[1]]
			-- A finger's drag on nothing moves the view, not a box
			if t and S.touch then
				t = t:gsub("; drag: select by a box", "")
				if t:match("^drag:") then
					t = nil
				end
			end
			if t then
				lines[#lines + 1] = b[2] .. ": " .. t
			end
		end
		if g.note then
			lines[#lines + 1] = g.note
		end
		return table.concat(lines, "\n")
	end

	-- A cell of a volume as its 12 edges
	local function cell_box(id, c, col, c2)
		local it = inst_data[id]
		if not it then
			return
		end
		local sz = it.size
		-- From one cell to another, both in
		c2 = c2 or c
		local lo = {math.min(c[1], c2[1]), math.min(c[2], c2[2]), math.min(c[3], c2[3])}
		local n = {math.abs(c[1] - c2[1]) + 1, math.abs(c[2] - c2[2]) + 1,
				math.abs(c[3] - c2[3]) + 1}
		local function corner(dx, dy, dz)
			local x, y, z = geom.rot((lo[1] + dx * n[1]) * sz,
					(lo[2] + dy * n[2]) * sz, (lo[3] + dz * n[3]) * sz,
					it.pitch, it.yaw, it.roll)
			return magic.Vector3(W(it.ox + x), W(it.oy + y), W(it.oz + z))
		end
		for _, e in ipairs({{0,0,0, 1,0,0}, {0,0,0, 0,1,0}, {0,0,0, 0,0,1},
				{1,1,1, 0,1,1}, {1,1,1, 1,0,1}, {1,1,1, 1,1,0},
				{1,0,0, 1,1,0}, {1,0,0, 1,0,1}, {0,1,0, 1,1,0},
				{0,1,0, 0,1,1}, {0,0,1, 1,0,1}, {0,0,1, 0,1,1}}) do
			debug:AddLine(corner(e[1], e[2], e[3]), corner(e[4], e[5], e[6]),
					col, false)
		end
	end

	-- An instance's box as its 12 edges
	local function inst_box(id, col)
		local it = inst_data[id]
		local function corner(sx, sy, sz)
			local x, y, z = geom.rot(sx * it.hx, sy * it.hy, sz * it.hz, it.pitch,
					it.yaw, it.roll)
			return magic.Vector3(W(it.x + x), W(it.y + y), W(it.z + z))
		end
		for _, e in ipairs({{-1,-1,-1, 1,-1,-1}, {-1,-1,-1, -1,1,-1},
				{-1,-1,-1, -1,-1,1}, {1,1,1, -1,1,1}, {1,1,1, 1,-1,1},
				{1,1,1, 1,1,-1}, {1,-1,-1, 1,1,-1}, {1,-1,-1, 1,-1,1},
				{-1,1,-1, 1,1,-1}, {-1,1,-1, -1,1,1}, {-1,-1,1, 1,-1,1},
				{-1,-1,1, -1,1,1}}) do
			debug:AddLine(corner(e[1], e[2], e[3]), corner(e[4], e[5], e[6]),
					col, false)
		end
	end

	draw_guide = function(g, P, line, outline)
		if not g then
			return
		end
		local plan = S.view == "2d"
		for _, h in ipairs(g.hl) do
			local col = h.col or HOVER
			if h.kind == "point" then
				debug:AddCross(P(h.x, h.z), plan and W(12 * mm_per_px()) or 0.15,
						col, false)
			elseif h.kind == "node" then
				local x, z = node_pos(h.id)
				debug:AddCross(P(x, z), plan and W(16 * mm_per_px()) or 0.25, col,
						false)
			elseif h.kind == "edge" then
				local ux, uz = node_pos(h.u)
				local vx, vz = node_pos(h.v)
				line(ux, uz, vx, vz, col)
			elseif h.kind == "wall" and outlines[h.id] then
				local y0, y1 = wall_span(doc.ents[h.id].ints)
				outline(outlines[h.id].pts, col, not plan and
						{W(y0) + 0.004, W(y1) + 0.004} or nil)
			elseif h.kind == "face" and outlines[h.id] then
				local o = outlines[h.id]
				local y0, y1 = wall_span(doc.ents[h.id].ints)
				for i = 1, #o.pts do
					if o.sides[i] == h.side then
						local p, q = o.pts[i], o.pts[i % #o.pts + 1]
						if plan then
							line(p[1], p[2], q[1], q[2], col)
						else
							for _, yy in ipairs({y0, y1}) do
								debug:AddLine(magic.Vector3(W(p[1]), W(yy), W(p[2])),
										magic.Vector3(W(q[1]), W(yy), W(q[2])), col, false)
							end
							for _, c in ipairs({p, q}) do
								debug:AddLine(magic.Vector3(W(c[1]), W(y0), W(c[2])),
										magic.Vector3(W(c[1]), W(y1), W(c[2])), col, false)
							end
						end
					end
				end
				if h.side == "core" then
					outline(o.pts, col, not plan and {W(y1) + 0.004} or nil)
				end
			elseif (h.kind == "floor" or h.kind == "room") and room_data[h.id] then
				outline(room_data[h.id].pts, col, not plan and {0.006} or nil)
			elseif h.kind == "ceiling" and room_data[h.id] then
				outline(room_data[h.id].pts, col,
						{W(room_ceiling(doc.ents[h.id])) - 0.004})
			elseif h.kind == "instance" and inst_data[h.id] then
				if plan then
					outline(inst_data[h.id].foot, col)
				else
					inst_box(h.id, col)
				end
			elseif h.kind == "leaves" and inst_data[h.id] then
				-- Each leaf's box, where it has swung to; a door with none
				-- (an opening) has its own box
				local leaves = inst_data[h.id].leaves or {}
				if #leaves == 0 then
					inst_box(h.id, col)
				end
				for _, lf in ipairs(leaves) do
					local function V(i)
						local x = i % 2 == 0 and lf.lo[1] or lf.hi[1]
						local y = math.floor(i / 2) % 2 == 0 and lf.lo[2] or lf.hi[2]
						local z = math.floor(i / 4) == 0 and lf.lo[3] or lf.hi[3]
						local wx, wy, wz = geom.rot(x, y, z, 0, lf.yaw, 0)
						return magic.Vector3(lf.x + wx, wy, lf.z + wz)
					end
					for _, e in ipairs({{0, 1}, {2, 3}, {4, 5}, {6, 7}, {0, 2},
							{1, 3}, {4, 6}, {5, 7}, {0, 4}, {1, 5}, {2, 6},
							{3, 7}}) do
						debug:AddLine(V(e[1]), V(e[2]), col, false)
					end
				end
			elseif h.kind == "image" and image_data[h.id] then
				outline(image_data[h.id].foot, col)
			elseif h.kind == "cell" then
				cell_box(h.id, h.c, col, h.c2)
			elseif h.kind == "opening" then
				-- Where the door or window would go, on the wall's left face
				local f = h.frame
				local function at(a, y)
					return magic.Vector3(W(f.ax + f.ux * (h.along + a) + f.nx * f.lo),
							W(y), W(f.az + f.uz * (h.along + a) + f.nz * f.lo))
				end
				if plan then
					local pts = {}
					for k, c in ipairs({{-1, f.lo}, {1, f.lo}, {1, -f.ro}, {-1, -f.ro}}) do
						pts[k] = {f.ax + f.ux * (h.along + c[1] * h.w / 2) + f.nx * c[2],
								f.az + f.uz * (h.along + c[1] * h.w / 2) + f.nz * c[2]}
					end
					outline(pts, PLACE)
				else
					local a, b = -h.w / 2, h.w / 2
					local y0, y1 = h.sill, h.sill + h.h
					debug:AddLine(at(a, y0), at(b, y0), PLACE, false)
					debug:AddLine(at(b, y0), at(b, y1), PLACE, false)
					debug:AddLine(at(b, y1), at(a, y1), PLACE, false)
					debug:AddLine(at(a, y1), at(a, y0), PLACE, false)
				end
			end
		end
	end
end

-- **What the plan view draws that changes only with the plan or the zoom**
-- (user, 2026-10-01: panning a big plan in Firefox was slow; the dashes
-- over what is above the cut alone were some 2000 debug lines a frame,
-- each two sandboxed vectors): the walls and objects above the cut, the
-- objects' outlines and the doors' and windows' symbols, as a line list on
-- a node, made again when the plan, the zoom, the cut or the floor edited
-- change. Drawn a frame at a time as before during a drag, which moves
-- things without a rebuild, and on a client without set_line_geometry.
local plan_lines_node = scene:CreateChild("PlanLines")
-- And the grid, over three times the view each way, made again when the
-- view leaves that or the step changes
local grid_node = scene:CreateChild("PlanGrid")
M.build_gen = 0

local function draw_overlay()
	local y = S.view == "2d" and W(settings().cut) - 0.001 or 0.004
	plan_lines_node.enabled = false
	grid_node.enabled = false
	local function P(x, z, yy)
		return magic.Vector3(W(x), yy or y, W(z))
	end
	local function line(ax, az, bx, bz, col)
		debug:AddLine(P(ax, az), P(bx, bz), col, false)
	end
	local function dashed(pts, col, ln)
		ln = ln or line
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			local l = geom.len(q[1] - p[1], q[2] - p[2])
			local n = math.max(1, math.floor(l / (6 * mm_per_px())))
			for j = 0, n - 1, 2 do
				ln(p[1] + (q[1] - p[1]) * j / n, p[2] + (q[2] - p[2]) * j / n,
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
		-- 30 mm up, over the floors (2 mm) by enough for a 16 bit depth
		-- buffer over the plan camera's 100 m (a browser's may be; user:
		-- the grid went under the floors in Firefox when it became
		-- geometry, where the debug lines drawn last had won the tie); the
		-- camera looks straight down, so the height shows nowhere else
		local gy = 0.03
		local g = M.grid_cache
		if buildat.set_line_geometry then
			if not (g and g.step == step and x0 >= g.x0 and x1 <= g.x1 and
					z0 >= g.z0 and z1 <= g.z1) then
				local dx, dz = x1 - x0, z1 - z0
				g = {step = step, x0 = x0 - dx, x1 = x1 + dx, z0 = z0 - dz,
						z1 = z1 + dz}
				M.grid_cache = g
				local out = {}
				local function add(ax, az, bx, bz, c)
					local k = #out
					out[k + 1], out[k + 2], out[k + 3] = W(ax), gy, W(az)
					out[k + 4], out[k + 5], out[k + 6], out[k + 7] = c.r, c.g, c.b, 1
					out[k + 8], out[k + 9], out[k + 10] = W(bx), gy, W(bz)
					out[k + 11], out[k + 12], out[k + 13], out[k + 14] = c.r, c.g, c.b, 1
				end
				for gx = math.floor(g.x0 / step) * step, g.x1, step do
					add(gx, g.z0, gx, g.z1, gx % 1000 == 0 and major or fine)
				end
				for gz = math.floor(g.z0 / step) * step, g.z1, step do
					add(g.x0, gz, g.x1, gz, gz % 1000 == 0 and major or fine)
				end
				buildat.set_line_geometry(grid_node, out)
				grid_node:GetComponent("CustomGeometry"):SetMaterial(0,
						flat_material)
			end
			grid_node.enabled = true
		else
			for gx = math.floor(x0 / step) * step, x1, step do
				debug:AddLine(P(gx, z0, gy), P(gx, z1, gy),
						gx % 1000 == 0 and major or fine, true)
			end
			for gz = math.floor(z0 / step) * step, z1, step do
				debug:AddLine(P(x0, gz, gy), P(x1, gz, gy),
						gz % 1000 == 0 and major or fine, true)
			end
		end
		-- The rooms' names and areas
		for id, r in pairs(room_data) do
			local cx, cz = geom.centroid(r.pts)
			world_label(cx, 0, cz, doc.ents[id].strs.name .. "\n" .. m2(r.net))
		end
		-- What is above the cut, dashed; the objects below it outlined
		local cut = settings().cut
		local function plan_lines(ln)
			for id, o in pairs(outlines) do
				if wall_span(doc.ents[id].ints) >= cut then
					dashed(o.pts, dark, ln)
				end
			end
			for id, it in pairs(inst_data) do
				if it.hosted then
					plan_symbol(id, it, ln)
				elseif it.y0 >= cut then
					dashed(it.foot, dark, ln)
				else
					for i = 1, #it.foot do
						local p, q = it.foot[i], it.foot[i % #it.foot + 1]
						ln(p[1], p[2], q[1], q[2], dark)
					end
				end
			end
		end
		if buildat.set_line_geometry and not S.drag then
			local key = M.build_gen .. ":" .. mm_per_px() .. ":" .. cut ..
					":" .. tostring(S.layout)
			if key ~= M.plan_lines_key then
				M.plan_lines_key = key
				local out = {}
				plan_lines(function(ax, az, bx, bz, c)
					local k = #out
					out[k + 1], out[k + 2], out[k + 3] = W(ax), y, W(az)
					out[k + 4], out[k + 5], out[k + 6], out[k + 7] = c.r, c.g, c.b, c.a
					out[k + 8], out[k + 9], out[k + 10] = W(bx), y, W(bz)
					out[k + 11], out[k + 12], out[k + 13], out[k + 14] =
							c.r, c.g, c.b, c.a
				end)
				buildat.set_line_geometry(plan_lines_node, out)
				plan_lines_node:GetComponent("CustomGeometry"):SetMaterial(0,
						flat_material)
			end
			plan_lines_node.enabled = true
		else
			plan_lines(line)
		end
	end
	local accent = magic.Color(1.0, 0.6, 0.1)
	for id, kind in pairs(S.sel) do
		if kind == "wall" and outlines[id] then
			local y0, y1 = wall_span(doc.ents[id].ints)
			outline(outlines[id].pts, accent, S.view ~= "2d" and
					{W(y0) + 0.004, W(y1) + 0.004} or nil)
			-- The face it was selected by, brighter
			if S.sel_face[id] then
				draw_guide({hl = {{kind = "face", id = id, side = S.sel_face[id],
						col = magic.Color(1.0, 0.95, 0.4)}}}, P, line, outline)
			end
			local w = wall_data[id]
			world_label((w.ax + w.bx) / 2, 0, (w.az + w.bz) / 2,
					mm_text(geom.len(w.bx - w.ax, w.bz - w.az)))
		elseif kind == "room" and room_data[id] then
			outline(room_data[id].pts, accent, S.sel_face[id] == "ceiling" and
					S.view ~= "2d" and {W(room_ceiling(doc.ents[id])) - 0.004} or nil)
			outline(room_data[id].inner, magic.Color(0.2, 0.6, 1.0))
		elseif kind == "image" and image_data[id] then
			outline(image_data[id].foot, accent)
		elseif kind == "instance" and inst_data[id] then
			local it = inst_data[id]
			outline(it.foot, accent, S.view ~= "2d" and
					{W(it.y0) + 0.004, W(it.y1) + 0.004} or nil)
		end
	end
	-- The calibration's two points
	if S.calib then
		local c = S.calib
		for i, p in ipairs(c.pts) do
			debug:AddCross(P(p[1], p[2]), W(10 * mm_per_px()), accent, false)
			if i == 2 then
				line(c.pts[1][1], c.pts[1][2], p[1], p[2], accent)
			end
		end
	end
	-- A switch's lamps, joined to it by dashed lines
	local sw = S.primary and doc.ents[S.primary]
	if sw and sw.type == "instance" and #sw.lists.lamps > 0 and inst_data[sw.id] then
		local a = inst_data[sw.id]
		for _, l in ipairs(sw.lists.lamps) do
			local b = inst_data[l]
			if b then
				dashed({{a.x, a.z}, {b.x, b.z}}, magic.Color(0.9, 0.7, 0.1))
			end
		end
	end
	-- The primary object's gaps to the walls
	if S.primary and S.sel[S.primary] == "instance" and inst_data[S.primary] and
			not inst_data[S.primary].hosted and not S.drag then
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
	-- The lines a dragged node was straightened onto (M.angle_snap), each
	-- wall's angle and length on it
	if S.drag and S.drag.kind == "node" and S.drag.angle_lines and S.drag.x then
		local d = S.drag
		for _, c in ipairs(d.angle_lines) do
			dashed({{c.p[1], c.p[2]}, {d.x, d.z}}, magic.Color(1.0, 0.55, 0.1))
			local a = math.deg(math.atan2(d.z - c.p[2], d.x - c.p[1]))
			world_label((c.p[1] + d.x) / 2, 0, (c.p[2] + d.z) / 2,
					string.format("%d deg, ", math.floor((a % 360) + 0.5) % 360) ..
					mm_text(geom.len(d.x - c.p[1], d.z - c.p[2])))
		end
	end
	-- **A door, window or opening moved along its wall** (user): what is
	-- left of the wall on each side, from the hole's edge to the wall's
	-- end, on that part of the wall.
	-- simplified: to the end of the wall's line, which at a corner is
	-- half the other wall's thickness past the face seen there
	local dr = S.drag
	if dr and dr.kind == "move" and dr.moved and dr.inst then
		for id in pairs(dr.inst) do
			local it = inst_data[id]
			local e = doc.ents[id]
			local def = e and doc.ents[e.ints.def]
			if it and it.hosted and it.frame and def then
				local f, hw = it.frame, def.ints.w / 2
				-- From the glass's edges for a window measured by its glass
				if def.ints.kind == KIND.window and def.ints.measure == 1 then
					hw = hw - 2 * FRAME_W
				end
				for _, span in ipairs({{0, it.along - hw},
						{it.along + hw, f.len}}) do
					if span[2] - span[1] > 0 then
						local t = (span[1] + span[2]) / 2
						world_label(f.ax + f.ux * t, 0, f.az + f.uz * t,
								mm_text(span[2] - span[1]))
					end
				end
			end
		end
	end
	-- The voxel tool's and walking's crosshair, and what the pointer is on
	crosshair.visible = S.captured or false
	draw_guide(S.guide, P, line, outline)
	-- The others: their cursors, their cameras, what they have selected
	for _, o in pairs(doc.others) do
		local p = o.p and place.presence(o.p, true)
		if p and o.name then
			local col = user_color(o.name)
			local size = S.view == "2d" and W(10 * mm_per_px()) or 0.15
			if p.view == 1 then
				-- Their camera, as a small frustum where it is
				local ex = magic.Vector3(W(p.px), W(p.py), W(p.pz))
				local function at(fx, fy)
					local x, y, z = geom.rot(fx * 0.3, fy * 0.2, 0.5, p.pitch / 1000,
							p.yaw / 1000, 0)
					return magic.Vector3(ex.x + x, ex.y + y, ex.z + z)
				end
				local c = {at(-1, -1), at(1, -1), at(1, 1), at(-1, 1)}
				for i = 1, 4 do
					debug:AddLine(ex, c[i], col, false)
					debug:AddLine(c[i], c[i % 4 + 1], col, false)
				end
				world_label(p.px, S.view ~= "2d" and p.py or 0, p.pz, o.name)
				if p.view == 2 then
					-- Walking: a body under the eyes
					local feet = p.py - S.eye
					local ring = {}
					for k = 0, 11 do
						local a = k / 12 * math.pi * 2
						ring[k + 1] = {p.px + math.cos(a) * BODY_R,
								p.pz + math.sin(a) * BODY_R}
					end
					outline(ring, col, S.view == "2d" and {y} or
							{W(feet) + 0.004, W(feet + HEAD) + 0.004})
					debug:AddLine(magic.Vector3(W(p.px), W(feet), W(p.pz)), ex,
							col, false)
				end
			else
				debug:AddCross(P(p.cx, p.cz), size, col, false)
				world_label(p.cx, 0, p.cz, o.name)
			end
			for _, id in ipairs(p.sel) do
				if outlines[id] then
					outline(outlines[id].pts, col)
				elseif inst_data[id] then
					outline(inst_data[id].foot, col)
				elseif room_data[id] then
					outline(room_data[id].pts, col)
				end
			end
		end
	end
	-- Nodes, for the tools that pick them
	if S.tool == "select" or S.tool == "node" then
		local size = S.view == "2d" and W(6 * mm_per_px()) or 0.08
		for _, n in ipairs(of_type("node")) do
			local x, z = node_pos(n.id)
			local on = S.sel[n.id] or S.nodes[n.id]
			debug:AddCross(P(x, z), size, on and accent or
					magic.Color(0.1, 0.3, 0.8), S.view ~= "2d")
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

-- This user's presence, for the others, every PRESENCE_SECONDS
local PRESENCE_SECONDS = 0.1
local presence_timer = 0
local function send_presence(dt)
	presence_timer = presence_timer + dt
	if presence_timer < PRESENCE_SECONDS then
		return
	end
	presence_timer = 0
	local cx, cz = cursor_floor()
	local sel = {}
	for id in pairs(S.sel) do
		sel[#sel + 1] = id
	end
	for id in pairs(S.nodes) do
		sel[#sel + 1] = id
	end
	local p = {view = S.view == "walk" and 2 or S.view == "3d" and 1 or 0,
			cx = math.floor(cx or 0), cz = math.floor(cz or 0), sel = sel,
			yaw = math.floor(S.yaw * 1000), pitch = math.floor(S.pitch * 1000)}
	if S.view ~= "2d" then
		p.px, p.py, p.pz = math.floor(S.pos.x * 1000), math.floor(S.pos.y * 1000),
				math.floor(S.pos.z * 1000)
	else
		p.px, p.py, p.pz = math.floor(S.cx), math.floor(S.span), math.floor(S.cz)
	end
	doc.send_presence(place.presence(p))
end

-- The plan closed for another ([FP_OTHER_PLAN]): the editor waits, drawing
-- and showing nothing, until the next plan's snapshot resumes it
local SCENE_PARTS = {walls_node, caps_node, overhead_node, pieces_node,
	images_node, decals_node, lamps_node}
function M.suspend()
	close_pause()
	S.crosshair = false
	update_capture()
	S.suspended = true
	S.sel, S.primary, S.nodes, S.sel_face = {}, nil, {}, {}
	S.draw, S.corners, S.linking, S.calib, S.drag, S.press = nil
	-- What the plan left behind goes ([FP_PLANS]): enabled = false is not
	-- recursive, and it stayed drawn under the plans page. The next plan's
	-- snapshot builds its own.
	for _, n in ipairs(built) do
		n:Remove()
	end
	built = {}
	for _, parts in pairs(place.parts) do
		for _, n in pairs(parts) do
			n:Remove()
		end
	end
	place.parts = {}
	voxel_meshes = {}
	-- and what they were built from: fp:closed empties the entities, and a
	-- ray against an instance whose door was gone was an error (user,
	-- 2026-10-02)
	outlines, wall_data, room_data, inst_data, solids = {}, {}, {}, {}, {}
	place.layers = {}
	S.layout, S.layouts_open = nil, false
	place.build_window()
	for _, n in ipairs(SCENE_PARTS) do
		n.enabled = false
	end
	for _, w in ipairs({toolbar, props, palette_win, S.touch_bar}) do
		if w then
			w.visible = false
		end
	end
	for _, t in ipairs(label_nodes) do
		t.visible = false
	end
	hud:SetText("")
	crosshair.visible = false
end

-- **Where the view was, per plan** (user, 2026-09-30): the mode, the
-- layout and the cameras, kept on this client and put back when the plan is
-- next opened. The storage key is the plan's name in hex, since a name is
-- anything a user typed.
-- simplified: a plan name of over 60 bytes is not remembered
local function view_key()
	local n = doc and doc.plan_name or ""
	if n == "" or #n > 60 then
		return nil
	end
	return "view_" .. (n:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

local function view_record()
	local w = S.walk
	-- and after them the free camera and the walker's look, each kept
	-- while the other is in use
	local c = S.cam3d or {x = S.pos.x, y = S.pos.y, z = S.pos.z, yaw = S.yaw,
			pitch = S.pitch}
	return string.format("%s;%s;%.1f;%.1f;%.1f;%.4f;%.4f;%.4f;%.3f;%.3f;" ..
			"%.1f;%.1f;%.1f;%.4f;%.4f;%.4f;%.3f;%.3f;%.3f;%.3f;%d", S.view,
			tostring(S.layout or ""), S.cx, S.cz,
			S.span, S.pos.x, S.pos.y, S.pos.z, S.yaw, S.pitch, w.x, w.z, w.feet,
			c.x, c.y, c.z, c.yaw, c.pitch, w.yaw or S.yaw, w.pitch or 0,
			w.placed and 1 or 0)
end

-- Kept once a second when it changed; M.update calls it
function M.save_view(dt)
	S.view_save_t = (S.view_save_t or 0) + dt
	if S.view_save_t < 1 then
		return
	end
	S.view_save_t = 0
	local key = view_key()
	if not key then
		return
	end
	local rec = view_record()
	if rec ~= S.view_saved then
		S.view_saved = rec
		buildat.storage_write(key, rec)
	end
end

-- Put back once the plan's document is here: init.lua calls it after the
-- join. A layout that has gone leaves the current one as it is.
function M.restore_view()
	local key = view_key()
	local rec = key and buildat.storage_read(key)
	if not rec then
		return
	end
	local f = {}
	for part in (rec .. ";"):gmatch("([^;]*);") do
		f[#f + 1] = part
	end
	local n = {}
	for i = 3, 13 do
		n[i] = tonumber(f[i])
		if not n[i] then
			return
		end
	end
	local view = f[1]
	if view ~= "2d" and view ~= "3d" and view ~= "walk" then
		return
	end
	local layout = tonumber(f[2])
	local e = layout and doc.ents[layout]
	if e and e.type == "layout" then
		S.layout = layout
		place.current()
	end
	set_view(view)
	S.cx, S.cz, S.span = n[3], n[4], math.max(500, math.min(200000, n[5]))
	S.pos = {x = n[6], y = n[7], z = n[8]}
	S.yaw, S.pitch = n[9], math.max(-90, math.min(90, n[10]))
	S.walk.x, S.walk.z, S.walk.feet = n[11], n[12], n[13]
	-- A record from before the two cameras were apart has none of these
	local m = {}
	for i = 14, 21 do
		m[i] = tonumber(f[i])
	end
	if m[21] then
		S.cam3d = {x = m[14], y = m[15], z = m[16], yaw = m[17], pitch = m[18]}
		S.walk.yaw, S.walk.pitch, S.walk.placed = m[19], m[20], m[21] == 1
	end
	S.view_saved = view_record()
	S.dirty = true
	refresh_panels()
	log:info("The view of " .. doc.plan_name .. " put back: " .. view)
end

function M.resume()
	S.suspended = false
	walls_node.enabled = true
	images_node.enabled = true
	decals_node.enabled = true
	lamps_node.enabled = true
	for _, w in ipairs({toolbar, props, palette_win, S.touch_bar}) do
		if w then
			w.visible = true
		end
	end
	-- The rest of the scene's parts are set by the view
	set_view(S.view)
	S.dirty = true
end

-- **Viewports** (user, 2026-10-01): a camera saved in the plan, from 3D
-- or walking, to see it again from the very same place. Gone to, the
-- camera is fixed there -- nothing that moves a camera moves it -- with
-- its own field of view, what was selected is let go of, and the menus
-- and texts are hidden until a key, a click or a touch; and, when it
-- recalls its moment, the light is its day and minute. Selecting and
-- editing go on as in 3D. Another view leaves it.
-- Up and Down through the pause menu's page; true when taken
function M.menu_key(key)
	return pause_win ~= nil and panel.menu_key(pause_win, key)
end

function M.viewports()
	local list = {}
	for _, e in ipairs(doc.of_type("viewport")) do
		list[#list + 1] = e
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

function M.save_viewport()
	if S.view == "2d" or not doc.can("edit") or not S.layout then
		return
	end
	local n = 0
	for _, e in ipairs(M.viewports()) do
		local k = tonumber(e.strs.name:match("^Viewport (%d+)$") or "")
		if k and k > n then
			n = k
		end
	end
	local walk = S.view == "walk"
	local name = "Viewport " .. (n + 1)
	local function mm(m)
		return math.floor(m * 1000 + 0.5)
	end
	send({{op = "create", ent = {id = doc.placeholder(), type = "viewport",
			ints = {layout = S.layout, x = mm(S.pos.x), y = mm(S.pos.y),
			z = mm(S.pos.z), yaw = math.floor(S.yaw % 360 * 1000 + 0.5) % 360000,
			pitch = math.floor(S.pitch * 1000 + 0.5), walk = walk and 1 or 0,
			fov = math.floor((walk and S.walk_fov or 60) + 0.5),
			day = M.plan_day(), minute = math.floor(M.plan_minute()) % 1440,
			recall = 1}, strs = {name = name}}}})
	doc.notice("Saved as " .. name)
end

function M.hide_ui()
	doc.ui_hidden = true
	panel.close_popup()
end

function M.show_ui()
	if doc.ui_hidden then
		doc.ui_hidden = false
		refresh_panels()
	end
end

-- preview: the camera only, the menus and the selection as they are
function M.go_viewport(id, preview)
	local e = doc.ents[id]
	if not e or e.type ~= "viewport" then
		return
	end
	if e.ints.layout ~= S.layout then
		place.switch(e.ints.layout)
	end
	S.vp = nil
	set_view("3d")
	S.vp = id
	S.daylight_key = nil
	S.dirty = true
	if preview then
		return
	end
	S.sel, S.sel_face, S.primary, S.nodes = {}, {}, nil, {}
	refresh_panels()
	M.hide_ui()
end

-- **The white the eye is adapted to** (FpFrame.glsl): the probes' where
-- the camera is along its room -- or, standing in a doorway, the room it
-- looks into -- else the outdoor one; FpFrame.glsl moves the eye's to it
-- in a second or so. In fp_wb, a texture of two texels: the two drawn
-- probes' rows and how far between (the cube mode); and a white's colour
-- (worked out probes', or outdoors).
-- simplified: under plain PBR without probes, the outdoor white
function M.wb_tick(dt)
	if not M.pbr_now() then
		return
	end
	M.probes_init()
	local w = M.wb
	if not w then
		local image = magic.Image:new()
		assert(image:SetSize(2, 1, 4), "the white's image")
		local texture = magic.Texture2D:new()
		texture:SetNumLevels(1)
		texture.filterMode = magic.FILTER_NEAREST
		assert(magic.cache:AddManualResource(texture, "fp_wb"), "the white in the cache")
		M.kept[#M.kept + 1] = image
		M.kept[#M.kept + 1] = texture
		w = {image = image, texture = texture}
		M.wb = w
	end
	local fx, fz = math.sin(math.rad(S.yaw)), math.cos(math.rad(S.yaw))
	local id
	for _, ahead in ipairs({0, 300, 600}) do
		id = id or room_at(S.pos.x * 1000 + fx * ahead, S.pos.z * 1000 + fz * ahead)
	end
	local slot = id and M.room_slot[id]
	local pr = slot and M.probe_rows[slot]
	local ra, rb, t, o = 0, 0, 0, M.wb_outdoor or {r = 1, g = 1, b = 1}
	M.wb_at = nil
	if pr then
		local a, b, f = M.probe_at(pr, S.pos.x, S.pos.z)
		local pa, pb = M.probe_pos[a], M.probe_pos[b]
		M.wb_at = {W(pa.x + (pb.x - pa.x) * f), W(pa.y + (pb.y - pa.y) * f),
				W(pa.z + (pb.z - pa.z) * f)}
		if M.cube_mode == 1 and M.probe_ready[a] and M.probe_ready[b] then
			ra, rb, t = a, b, f
		elseif M.cube_mode == 2 and M.cpu_cube[a] and M.cpu_cube[b] then
			local c = {0, 0, 0}
			for _, k in ipairs({{a, 1 - f}, {b, f}}) do
				for _, face in ipairs(M.cpu_cube[k[1]]) do
					for i = 1, 3 do
						c[i] = c[i] + face[i] * k[2]
					end
				end
			end
			o = {r = c[1], g = c[2], b = c[3]}
		else
			M.wb_at = nil
		end
	end
	local m = math.max(o.r, o.g, o.b, 1e-6)
	local key = string.format("%d %d %.3f %.4f %.4f %.4f", ra, rb, t,
			o.r / m, o.g / m, o.b / m)
	if key == w.key then
		return
	end
	w.key = key
	w.image:SetPixel(0, 0, magic.Color(ra / 255, rb / 255, t, 1))
	w.image:SetPixel(1, 0, magic.Color(o.r / m, o.g / m, o.b / m, 1))
	assert(w.texture:SetData(w.image), "the white's texture")
end

-- **A dump for the path-traced reference** (games/floorplanner/test/
-- pathtrace_render.py, user, 2026-10-01): with BUILDAT_FP_REFDUMP naming a
-- viewport, that viewport is gone to and, REFDUMP_WAIT seconds on, when
-- the room probes have bounced their light round, the scene's meshes are
-- dumped (buildat.dump_meshes, into <user>/meshdumps) with what the render
-- needs beside them: the camera, the sun and the sky as apply_daylight
-- has them, and each palette row's albedo as M.room_bounce takes it; and
-- a screenshot, after which the client quits.
-- The lamps are switched off for this client, as the render has none.
-- simplified: the albedo is the entry's flat colour, without the
-- pattern's gaps and grain
M.REFDUMP_WAIT = 20
M.refdump = buildat.get_env("BUILDAT_FP_REFDUMP") and
		{name = buildat.get_env("BUILDAT_FP_REFDUMP")}
function M.refdump_tick(dt)
	local r = M.refdump
	if not r then
		return
	end
	-- Done: a second for the screenshot to land, then the client goes
	if r.done then
		r.quit_t = r.quit_t + dt
		if r.quit_t > 1 then
			M.refdump = nil
			buildat.quit()
		end
		return
	end
	if not r.t then
		for _, e in ipairs(M.viewports()) do
			if e.strs.name == r.name then
				M.go_viewport(e.id)
				r.t = 0
			end
		end
		-- The lamps off, for this client: the render has none
		for id in pairs(doc.ents) do
			if is_lamp(id) then
				S.local_on[id] = false
				S.dirty = true
			end
		end
		return
	end
	r.t = r.t + dt
	if r.t < M.REFDUMP_WAIT then
		return
	end
	r.done = true
	local function v3(x, y, z)
		return string.format("[%.6g, %.6g, %.6g]", x, y, z)
	end
	local function c3(c)
		return v3(c.r, c.g, c.b)
	end
	local function lin(rgb)
		return {r = (math.floor(rgb / 65536) / 255) ^ 2.2,
				g = (math.floor(rgb / 256) % 256 / 255) ^ 2.2,
				b = (rgb % 256 / 255) ^ 2.2}
	end
	local st = settings()
	local tx, h, tz = M.daylight.sun_toward(st.latitude, st.north,
			M.plan_day(), M.plan_minute())
	local ground = lin(M.ground_rgb())
	local light = M.daylight.light(h, ground)
	local yaw, pitch = math.rad(S.yaw), math.rad(S.pitch)
	-- Each row the meshes point at: kind 5 is glass, 4 a lamp
	local rows = {'"0": {"albedo": ' .. c3(lin(0xb0b0b0)) .. ', "kind": 0}',
			'"1": {"albedo": ' .. c3(lin(0xa8c8e0)) .. ', "kind": 5}',
			string.format('"%d": {"albedo": %s, "kind": 0}', M.ground_row,
			c3(ground))}
	for _, e in ipairs(of_type("palette")) do
		rows[#rows + 1] = string.format('"%d": {"albedo": %s, "kind": %d}',
				row(e.id), c3(M.entry_albedo(e.id)), e.ints.kind)
	end
	local json = "{" .. table.concat({
		'"viewport": "' .. r.name:gsub('[%c"\\]', "") .. '"',
		'"camera_pos": ' .. v3(S.pos.x, S.pos.y, S.pos.z),
		'"camera_dir": ' .. v3(math.sin(yaw) * math.cos(pitch),
				-math.sin(pitch), math.cos(yaw) * math.cos(pitch)),
		'"fov": ' .. string.format("%.6g", cam3d.fov),
		-- Where the frame's white is taken (M.wb_tick): between the room's
		-- probes, or the eye's outdoors
		'"white_at": ' .. (M.wb_at and v3(M.wb_at[1], M.wb_at[2], M.wb_at[3]) or
				v3(S.pos.x, S.pos.y, S.pos.z)),
		'"sun_toward": ' .. v3(tx, h, tz),
		'"sun_irradiance": ' .. string.format("%.6g", light.sun),
		'"sun_color": ' .. c3(light.sun_color),
		'"sky_zenith": ' .. c3(light.zenith),
		'"sky_horizon": ' .. c3(light.horizon),
		'"sky_ambient": ' .. c3(light.ambient),
		'"rows": {\n' .. table.concat(rows, ",\n") .. "\n}",
	}, ",\n") .. "}\n"
	local name, err = buildat.dump_meshes(json, scene)
	log:info("Reference dump of " .. r.name .. ": " .. tostring(name or err))
	-- and the client's own frame of it, into <user>/screenshots
	local shot, serr = buildat.take_screenshot()
	log:info("Reference screenshot of " .. r.name .. ": " .. tostring(shot or serr))
	r.quit_t = 0
end

function M.leave_viewport()
	if not S.vp then
		return
	end
	S.vp = nil
	S.daylight_key = nil
	M.show_ui()
	refresh_panels()
end

function M.update(dt)
	panel.flush()
	if S.suspended then
		return
	end
	M.save_view(dt)
	cam3d.fov = M.fov_for(S.view == "walk" and S.walk_fov or 60)
	-- The floors above hidden in 3D, when the layouts menu says so. Deep:
	-- a layout's nodes hold its walls and objects as children.
	place.shown = place.shown or {}
	for id, parts in pairs(place.parts) do
		local shown = not (S.hide_above and S.view == "3d" and
				place.above and place.above[id])
		if place.shown[id] ~= shown then
			place.shown[id] = shown
			for _, n in pairs(parts) do
				n:SetDeepEnabled(shown)
			end
		end
	end
	move_camera(dt)
	-- A viewport's camera does not move: whatever moved it, it is put back
	local vp = S.vp and doc.ents[S.vp]
	if S.vp and not vp then
		M.leave_viewport()
	elseif vp then
		local v = vp.ints
		S.pos = {x = W(v.x), y = W(v.y), z = W(v.z)}
		S.yaw, S.pitch = v.yaw / 1000, v.pitch / 1000
		cam3d.fov = M.fov_for(v.fov)
	end
	-- The camera of the view in use, kept for when it is gone back to
	if S.vp then
		-- (a viewport's is its own)
	elseif S.view == "3d" then
		S.cam3d = {x = S.pos.x, y = S.pos.y, z = S.pos.z, yaw = S.yaw,
				pitch = S.pitch}
	elseif S.view == "walk" then
		S.walk.yaw, S.walk.pitch = S.yaw, S.pitch
	end
	place_cameras()
	send_presence(dt)
	stream_drag(dt)
	if S.dirty then
		rebuild()
	end
	M.apply_daylight()
	M.probes_tick()
	M.wb_tick(dt)
	M.refdump_tick(dt)
	-- A menu made since: its buttons for the keyboard
	if pause_win and pause_win ~= M.keyed_win then
		M.keyed_win = pause_win
		panel.keyboard_menu(pause_win)
	end
	if S.panels_stale and not doc.typing() then
		refresh_panels()
	end
	label_i = 0
	-- No hints and no highlights while a viewport is shown clean
	S.guide = not doc.ui_hidden and compute_guide() or nil
	-- [FP_TOUCH] 4: a finger held still is the right button
	if S.touch and not S.paused then
		local only, n = nil, 0
		for _, f in pairs(S.fingers) do
			only, n = f, n + 1
		end
		if n == 1 and not only.ui and not only.stick and not only.moved and
				not only.held and buildat.get_time_us() - only.t0 > 500000 then
			only.held = true
			M.long_press()
		end
		-- The guide wraps to the screen, over the touch bar
		hud:SetFixedWidth(magic.ui.root.width - 24)
		hud:SetPosition(0, -(S.touch_bar and S.touch_bar.height + 20 or 12))
	end
	local text = guide_text(S.guide)
	if hud.text ~= text then
		hud:SetText(text)
	end
	draw_overlay()
	for i = label_i + 1, #label_nodes do
		label_nodes[i].visible = false
	end
	-- Hidden for a viewport: whatever was made or shown since
	if doc.ui_hidden then
		-- (pairs: any of them may be nil, where ipairs would stop)
		for _, w in pairs({toolbar, props, palette_win, picker_win, place.win,
				pause_win, S.touch_bar, hud, crosshair}) do
			w.visible = false
		end
		for i = 1, label_i do
			label_nodes[i].visible = false
		end
	else
		hud.visible = true
	end
end

function M.start(d)
	doc = d
	-- The editor's state, for what reads it from outside (tutorial.lua)
	M.S = S
	M.folded = panel.folded
	doc.members_changed = M.members_changed
	doc.backups_changed = M.backups_changed
	S.material = nil
	doc.listeners[#doc.listeners + 1] = function(changed, deleted)
		if S.suspended then
			return
		end
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
	doc.privs_changed = function()
		if not doc.can("edit") and S.tool ~= "select" then
			set_tool("select")
		end
		refresh_panels()
		-- The pause menu's mode shows what the server says
		if M.pause_top() then
			M.open_pause()
		end
	end
	doc.others_changed = function()
		S.dirty = true
	end
	doc.voxels_changed = function()
		S.dirty = true
		refresh_panels()
	end
	-- A press off an open dropdown closes it, and one on the view does
	-- nothing else
	-- None of the input is the editor's under the plans page (M.suspend):
	-- a click on a plan there went on to pick in the plan just closed
	local function live(f)
		return function(...)
			if not S.suspended then
				f(...)
			end
		end
	end
	magic.SubscribeToEvent("MouseButtonDown", live(function(_, data)
		-- A viewport's hidden menus come back, and the click does nothing
		-- else
		if doc.ui_hidden then
			M.show_ui()
			S.swallow_up = true
			return
		end
		local sc = magic.ui.scale
		if panel.press(S.mx / sc, S.my / sc) and not over_ui() then
			S.swallow_up = true
			return
		end
		M.mouse_down(data:GetInt("Button"))
	end))
	magic.SubscribeToEvent("MouseButtonUp", live(function(_, data)
		M.mouse_up(data:GetInt("Button"))
	end))
	magic.SubscribeToEvent("MouseMove", live(function(_, data)
		M.mouse_move(data:GetInt("X"), data:GetInt("Y"), data:GetInt("DX"),
				data:GetInt("DY"))
	end))
	magic.SubscribeToEvent("MouseWheel", live(function(_, data)
		M.mouse_wheel(data:GetInt("Wheel"))
	end))
	magic.SubscribeToEvent("TouchBegin", live(function(_, data)
		local x, y, sc = data:GetInt("X"), data:GetInt("Y"), magic.ui.scale
		panel.press(x / sc, y / sc)
		M.touch_begin(data:GetInt("TouchID"), x, y)
	end))
	magic.SubscribeToEvent("TouchMove", live(function(_, data)
		M.touch_move(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"),
				data:GetInt("DX"), data:GetInt("DY"))
	end))
	magic.SubscribeToEvent("TouchEnd", live(function(_, data)
		M.touch_end(data:GetInt("TouchID"), data:GetInt("X"), data:GetInt("Y"))
	end))
	set_view("2d")
	-- A phone's address bar away from the first tap, until the menu
	buildat.set_web_fullscreen(true)
	log:info("Editor started")
end

return M
-- vim: set noet ts=4 sw=4:
