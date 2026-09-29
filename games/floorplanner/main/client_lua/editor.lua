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
-- The view button goes round the views: the plan, the free camera, walking
local NEXT_VIEW = {["2d"] = "3d", ["3d"] = "walk", walk = "2d"}
local VIEW_NAMES = {["2d"] = "2D", ["3d"] = "3D", walk = "Walk"}
-- Walking: the body's radius, how high a step it takes, its height, mm.
-- A step takes a stair's riser, which building codes cap near 220 mm.
local BODY_R, STEP, HEAD = 250, 250, 1750
local JUSTIFY_NAMES = {[0] = "centered", [1] = "left", [2] = "right"}
local TOOL_KEYS = {select = "V", node = "N", wall = "B", room = "R",
	box = "O", hosted = "I", voxel = "K", paint = "M"}
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
	view = "2d",
	show_ids = true, -- the material id decals
	plan_look = true, -- the plan view in flat colours (L)
	tool = "select",
	angle = 4,      -- index into ANGLE_STEPS: the angle snap
	-- New walls
	thickness = 100,
	justify = 0,
	height = 0,
	hang = 0,
	room_walls = true, -- a room drawn gets walls on its edges
	-- New boxes
	box = {w = 600, h = 750, d = 600, align = 0, offset = 0},
	-- The object tool's other shape: stairs this wide, up this high (0: the
	-- plan's floor to floor) in risers of about this much, each this deep
	shape = "box",
	stairs = {w = 1000, h = 0, riser = 200, tread = 250},
	hosted = 3,     -- what the door/window tool puts in a wall
	voxel_size = 50, -- a new voxel volume's, mm
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
	eye = 1600,
	export_mmpx = 10, -- the PNG export's scale
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
sun.shadowBias = magic.BiasParameters(0.00025, 0.5)
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
-- The same, for the type previews: its own so the plan's flat look is not
-- theirs
local preview_material = magic.cache:GetResource("Material",
		"main/palette_preview.xml")
local flat_material = magic.cache:GetResource("Material", "main/flat_vcol.xml")
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
	local uv = magic.Vector2(row, 0)
	for _, v in ipairs({a, b, c}) do
		g:DefineVertex(v)
		g:DefineNormal(n)
		g:DefineColor(col)
		g:DefineTexCoord(uv)
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

-- A box of half sizes hx, hy, hz (metres) about the origin, or about
-- (cx, cy, cz)
local function box_geometry(g, hx, hy, hz, col, cx, cy, cz, tint)
	cx, cy, cz = cx or 0, cy or 0, cz or 0
	local function V(x, y, z)
		return magic.Vector3(cx + x * hx, cy + y * hy, cz + z * hz)
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
		tri(g, C(-1, -1), C(1, -1), C(1, 1), n, col, tint)
		tri(g, C(-1, -1), C(1, 1), C(-1, 1), n, col, tint)
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
			magic.Color(0.85, 0.85, 0.83))
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
	rp:Load(magic.cache:GetResource("XMLFile", "RenderPaths/Deferred.xml"))
	vp.renderPath = rp
	return vp
end

--
-- The document, as the editor reads it
--
local function settings()
	return doc.settings().ints
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
		brightness = 500, speckle = 300, angle = 0, contrast = 1000, kind = k}
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
	local key = table.concat(parts, ",")
	if key == palette_key then
		return
	end
	palette_key = key
	palette_rows = {}
	-- The two rows of nothing, a preview's for each type, then the entries
	local n = #entries + 2 + #MATERIAL_KINDS + 1
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
			knob = p.brightness / 1000
		elseif p.kind == 7 then
			knob = math.min(1, p.grout / p.scale * 4)
		elseif p.kind == 9 then
			knob = p.speckle / 1000
		end
		px(4, y, math.log(p.scale) / math.log(2) / 16,
				(p.axis + 4 * p.stagger) * 16 / 255, math.floor(p.seed / 256) / 255,
				knob)
		-- Wood's grain contrast and paneling's angle
		px(5, y, p.angle / 180, p.contrast / 3000, 0, 0)
	end
	for k = 0, #MATERIAL_KINDS do
		put_row(2 + k, kind_preview(k))
	end
	for i, e in ipairs(entries) do
		palette_rows[e.id] = i + 2 + #MATERIAL_KINDS
		put_row(i + 2 + #MATERIAL_KINDS, e.ints)
	end
	local texture = magic.Texture2D:new()
	-- One level: a smaller one would average the rows' knobs together
	texture:SetNumLevels(1)
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = magic.FILTER_NEAREST
	M.kept[#M.kept + 1] = texture
	M.kept[#M.kept + 1] = image
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
			-- In a wall: across its whole thickness and trim, at its sill
			local f = wall_frame(i.host)
			local p = def.ints
			if f then
				local along = i.along
				if moved then
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

-- simplified: one quad per exposed voxel face, made through CustomGeometry,
-- which is slow past some tens of thousands of faces; the upgrade is a
-- greedy mesher filling a VertexBuffer with buildat.write_floats
local function voxel_geometry(g, def, sz, tint)
	local vox = doc.voxels[def] or {}
	local s = W(sz)
	for key, mat in pairs(vox) do
		local x, y, z = doc.voxel_cell(key)
		local r = row(mat)
		for _, f in ipairs(FACES) do
			if not vox[doc.voxel_key(x + f[1], y + f[2], z + f[3])] then
				local n = magic.Vector3(f[1], f[2], f[3])
				-- The face's four corners: the cell's far side on the face's
				-- axis, and the two others across it
				local cx, cy, cz = x + 0.5 + f[1] * 0.5, y + 0.5 + f[2] * 0.5,
						z + 0.5 + f[3] * 0.5
				local u = f[1] ~= 0 and {0, 1, 0} or {1, 0, 0}
				local v = f[3] ~= 0 and {0, 1, 0} or {0, 0, 1}
				if f[2] ~= 0 then
					u, v = {1, 0, 0}, {0, 0, 1}
				end
				local function C(a, b)
					return magic.Vector3((cx + (u[1] * a + v[1] * b) * 0.5) * s,
							(cy + (u[2] * a + v[2] * b) * 0.5) * s,
							(cz + (u[3] * a + v[3] * b) * 0.5) * s)
				end
				tri(g, C(-1, -1), C(1, -1), C(1, 1), n, r, tint)
				tri(g, C(-1, -1), C(1, 1), C(-1, 1), n, r, tint)
			end
		end
	end
end

local function update_voxel_meshes(seen)
	for id, it in pairs(inst_data) do
		if it.voxel then
			seen[id] = true
			local e = doc.ents[id].ints
			local def = e.def
			local on = lamp_on(id)
			local key = (doc.voxel_version[def] or 0) .. ":" .. palette_gen ..
					":" .. it.size .. ":" .. def .. ":" .. e.align .. ":" ..
					tostring(on)
			local m = voxel_meshes[id]
			if not m or m.key ~= key then
				if m then
					m.node:Remove()
				end
				local parent = e.align == 1 and P.overhead or P.walls
				local node = parent:CreateChild("voxels")
				local g = node:CreateComponent("CustomGeometry")
				g:SetNumGeometries(1)
				g:BeginGeometry(0, magic.TRIANGLE_LIST)
				voxel_geometry(g, def, it.size, not on and UNLIT or nil)
				g:Commit()
				g:SetMaterial(0, lit_material)
				m = {node = node, key = key}
				voxel_meshes[id] = m
			end
			m.node.position = magic.Vector3(W(it.ox), W(it.oy), W(it.oz))
			m.node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
		end
	end
end

-- How open a door or window is, in thousandths: a viewer's own opening
-- wins over the plan's
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
		g:Commit()
		g:SetMaterial(0, lit_material)
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
	if window then
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
			B(lg, x0, y0, -LEAF_T / 2, x1, y1 - LEAF_GAP, LEAF_T / 2, leaf_col)
			commit(lg, lit_material)
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
		local b = p.brightness / 1000
		light.brightness = 0.5 + 1.5 * b
		light.range = 2 + 8 * b
end

-- The lamps that are on: each connected region of a volume's lamp voxels
-- is one light at its middle, not one per voxel; a box of a lamp material
-- is one at its centre
build_lamps = function()
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

-- wells: {floor = {pts, ...}, ceiling = {pts, ...}}, the stairwells cut in
-- this layout's rooms
local function build_layout(seen_voxels, wells)
	solids = {}
	wall_data = {}
	for _, e in ipairs(of_type("wall")) do
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
			local cg = geometry(P.caps)
			flat_polygon(cg, pts, math.min(y1, cut) - 3, UP, y1 >= cut and
					cut_col or low_col)
			commit(cg, flat_material)
		end
	end

	-- An outline extruded between y0 and y1, its faces coloured by label
	local function extrude(g, pts, labels, y0, y1, cols, bottom)
		flat_polygon(g, pts, y1, UP, cols.core)
		if bottom then
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
		if #r.pts >= 3 then
			local g = geometry(P.walls)
			r.floor = geom.minus(r.pts, wells.floor)
			for _, pts in ipairs(r.floor) do
				flat_polygon(g, pts, 2, UP, row(e.ints.mat_floor))
			end
			commit(g, lit_material)
			local cg = geometry(P.overhead)
			for _, pts in ipairs(geom.minus(r.pts, wells.ceiling)) do
				flat_polygon(cg, pts, room_ceiling(e), DOWN,
						row(e.ints.mat_ceiling))
			end
			commit(cg, lit_material)
		end
	end

	for id, it in pairs(inst_data) do
		local def = doc.ents[it.def].ints
		local e = doc.ents[id].ints
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
	palette_texture()
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
	local wells = place.stairwells(order, cur)
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
		P, S.view_layout = parts, l.id
		build_layout(seen_voxels, wells[l.id])
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
	-- The sun where the plan puts it
	local st = settings()
	sun.enabled = st.sun == 1
	local sx, sy, sz = geom.rot(0, 0, 1, st.sun_pitch, st.sun_yaw, 0)
	sun_node.direction = magic.Vector3(sx, sy, sz)
	caps_node.enabled = S.view == "2d"
	S.dirty = false
end
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
local function ray_instance(it, o, d, id)
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
		local t = ray_instance(it, o, d, not whole and id or nil)
		if t and t < best_t then
			best, best_t = {kind = "instance", id = id}, t
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
		send(finish_batch(b), select_placed(ph, "room"))
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
		send({
			{op = "create", ent = {id = def, type = "definition", ints = ints}},
			{op = "create", ent = {id = inst, type = "instance",
					ints = {def = def, x = math.floor(x + 0.5),
					z = math.floor(z + 0.5), align = S.box.align,
					offset = S.box.offset}}},
		}, select_placed(inst, "instance"))
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
	local function add_volume(x, z)
		local def = doc.placeholder()
		local inst = doc.placeholder()
		send({
			{op = "create", ent = {id = def, type = "definition", ints = {
					kind = KIND.voxel, voxel_size = S.voxel_size}}},
			{op = "create", ent = {id = inst, type = "instance", ints = {def = def,
					x = math.floor(x + 0.5), z = math.floor(z + 0.5)}}},
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
	voxel_edit = function(dig, paint)
		if not doc.can("edit") then
			doc.notice("Viewing only: no edit privilege")
			return
		end
		local id = voxel_target()
		if not id then
			local x, z = snapped_point(nil)
			if x and not dig and not paint then
				add_volume(x, z)
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
			local hit, place = voxel_ray(id)
			if paint and hit then
				sets[doc.voxel_key(hit[1], hit[2], hit[3])] = default_material()
			elseif dig and hit then
				sets[doc.voxel_key(hit[1], hit[2], hit[3])] = 0
			elseif not dig and place and in_range(place) then
				sets[doc.voxel_key(place[1], place[2], place[3])] = default_material()
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
		}, function(err)
			-- What was put in is what is selected
			if err == "" then
				S.sel = {[S.real[inst]] = "instance"}
				S.primary = S.real[inst]
				M.refresh_panels()
			end
		end)
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
	return S.view == "walk" or (S.view == "3d" and S.tool == "voxel")
end

local function update_capture()
	local want = S.crosshair and crosshair_view() and not S.paused or false
	if want ~= (S.captured or false) then
		S.captured = want
		S.looking = want
		magic.input:SetMouseMode(want and magic.MM_RELATIVE or magic.MM_ABSOLUTE)
	end
end

local function set_view(v)
	if v == "walk" and S.view ~= "walk" then
		-- On the floor under the camera, or the plan's middle
		if S.view == "3d" then
			local x, z = S.pos.x * 1000, S.pos.z * 1000
			S.walk.x, S.walk.z = x, z
		else
			S.walk.x, S.walk.z = S.cx, S.cz
		end
		S.walk.feet = 0
		S.pitch = 0
	end
	-- A view starts at its pointer, so the view button can go on from it
	if v ~= S.view then
		S.crosshair = false
	end
	S.view = v
	-- Only when it changes: the walk and the free camera share a viewport
	if (v == "2d") ~= (S.shown_2d == true) or not S.shown then
		S.shown, S.shown_2d = true, v == "2d"
		magic.set_preferred_viewports({viewport_for(v)})
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

local function set_tool(t)
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
	toolbar = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 8, true)
	panel.button(toolbar, VIEW_NAMES[S.view] .. " (F1 F2 F3)",
			function() set_view(NEXT_VIEW[S.view]) end, false, 40)
	-- The layout edited, and the window that picks another
	local l = S.layout and doc.ents[S.layout]
	panel.button(toolbar, l and l.strs.name or "Layouts", function()
		S.layouts_open = not S.layouts_open
		refresh_panels()
	end, S.layouts_open)
	for _, t in ipairs({{"select", "Select"}, {"node", "Nodes"},
			{"wall", "Wall"}, {"room", "Room"}, {"box", "Object"},
			{"hosted", "Door/window"}, {"voxel", "Voxels"}, {"paint", "Material"}}) do
		panel.button(toolbar, t[2] .. " (" .. TOOL_KEYS[t[1]] .. ")",
				function() set_tool(t[1]) end, S.tool == t[1])
	end
	local g = grid_step()
	panel.button(toolbar, "Grid " .. (g < 10 and g .. " mm" or
			(g / 10) .. " cm") .. " (G)", function()
		next_grid()
	end)
	local a = ANGLE_STEPS[S.angle]
	panel.button(toolbar, "Angle " .. (a and a .. " deg" or "free") ..
			" (H)", function()
		S.angle = S.angle % #ANGLE_STEPS + 1
		refresh_panels()
	end)
	panel.button(toolbar, "IDs", function()
		S.show_ids = not S.show_ids
		S.dirty = true
		refresh_panels()
	end, S.show_ids)
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
	props = panel.window(magic.HA_RIGHT, magic.VA_TOP, -8, 50)
	local sel = S.primary and S.sel[S.primary] and doc.ents[S.primary]
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
	elseif sel and sel.type == "instance" and sel.ints.host ~= 0 then
		local i = sel.ints
		local p = doc.ents[i.def].ints
		local links = instances_of(i.def)
		panel.label(props, KIND_NAMES[p.kind] .. " " .. sel.id ..
				(links > 1 and ("   linked x" .. links) or ""))
		int_field(i.def, "Width mm", "w", p.w)
		int_field(i.def, "Height mm", "h", p.h)
		int_field(sel.id, "Sill mm", "sill", i.sill)
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
			local names = p.kind == KIND.door and {"Single leaf", "Double leaf"}
					or {"Fixed", "Casement"}
			panel.button(props, names[p.leaf + 1], function()
				set(i.def, {ints = {leaf = 1 - p.leaf}})
			end)
			local r = panel.row(props)
			panel.button(r, "Other hinge", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 1)}})
			end)
			panel.button(r, "Other side", function()
				set(sel.id, {ints = {flip = bit_xor(i.flip, 2)}})
			end)
			panel.field(props, "Open %", math.floor(i.open / 10 + 0.5),
					function(t)
				local v = tonumber(t)
				if v then
					set(sel.id, {ints = {open = math.max(0, math.min(1000,
							math.floor(v * 10 + 0.5)))}})
				end
			end)
			-- The part a palette double click goes on, the palette showing
			-- what it has now; a part with none of its own shows the frame's
			panel.label(props, "Selected part (the palette's double click):")
			local r2 = panel.row(props)
			local part = DOOR_PARTS[S.sel_face[sel.id]] and S.sel_face[sel.id] or
					"mat"
			for _, slot in ipairs({{"Frame", "mat"}, {"Leaf", "mat_leaf"},
					{"Glass", "mat_glass"}}) do
				panel.button(r2, slot[1], function()
					S.sel_face[sel.id] = slot[2]
					editing_selection()
					local m = p[slot[2]] ~= 0 and p[slot[2]] or p.mat
					if doc.ents[m] then
						S.material = m
					end
					refresh_panels()
				end, part == slot[2])
			end
		end
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (Del)", delete_selected)
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
		panel.button(props, "Replace a material...", function()
			S.picker = nil
			S.replace = {def = i.def, to = default_material()}
			refresh_panels()
		end)
		panel.label(props, "Voxel tool (K): 3D left digs, right places;")
		panel.label(props, "2D click adds on top, Ctrl+click takes off;")
		panel.label(props, "Shift+click gives a voxel the palette entry")
		panel.button(props, "Copy (Ctrl+D)", function() copy_selected(false) end)
		panel.button(props, "Linked clone (Ctrl+L)", function()
			copy_selected(true)
		end)
		if links > 1 then
			panel.button(props, "Unlink", function() unlink(sel.id) end)
		end
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "instance" then
		local i = sel.ints
		local def = doc.ents[i.def]
		local p = def.ints
		local links = instances_of(i.def)
		panel.label(props, KIND_NAMES[p.kind] .. " " .. sel.id .. (links > 1 and
				("   linked x" .. links) or ""))
		int_field(i.def, "Width mm", "w", p.w)
		int_field(i.def, "Height mm", "h", p.h)
		int_field(i.def, "Depth mm", "d", p.d)
		if p.kind == KIND.stairs then
			-- The riser sets the steps, the height staying; the tread sets
			-- the depth
			int_field(i.def, "Steps", "steps", p.steps)
			panel.field(props, "Riser mm", math.floor(p.h / p.steps * 10 + 0.5) / 10,
					function(t)
				local v = tonumber(t)
				if v and v > 0 then
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
		panel.button(props, "Delete (Del)", delete_selected)
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
			end)
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
		panel.button(props, i.show3d == 1 and "Shown in 3D too" or
				"In the plan view only", function()
			set(sel.id, {ints = {show3d = 1 - i.show3d}})
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
		local on_ceiling = S.sel_face[sel.id] == "ceiling"
		panel.label(props, "Selected by its " .. (on_ceiling and "ceiling, #" ..
				sel.ints.mat_ceiling or "floor, #" .. sel.ints.mat_floor))
		panel.button(props, "The palette entry on the " .. (on_ceiling and
				"ceiling" or "floor") .. " (double click)",
				function() apply_material() end)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif sel and sel.type == "node" then
		panel.label(props, "Node " .. sel.id)
		int_field(sel.id, "X mm", "x", sel.ints.x)
		int_field(sel.id, "Z mm", "z", sel.ints.z)
		panel.button(props, "Delete (Del)", delete_selected)
	elseif S.tool == "hosted" then
		panel.label(props, "Click a wall to put in (I: the next):")
		local r = panel.row(props)
		for _, k in ipairs({KIND.opening, KIND.door, KIND.window, KIND.switch}) do
			panel.button(r, KIND_NAMES[k], function()
				S.hosted = k
				refresh_panels()
			end, S.hosted == k)
		end
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
		panel.label(props, "place a voxel on the floor to start one")
		panel.field(props, "Voxel mm", S.voxel_size, function(t)
			local v = num(t)
			if v and v > 0 then S.voxel_size = v end
		end)
		panel.label(props, "3D: the mouse turns the view, Esc lets go")
	elseif S.tool == "box" then
		local stairs = S.shape == "stairs"
		panel.button(props, stairs and "Shape: stairs" or "Shape: box", function()
			S.shape = stairs and "box" or "stairs"
			refresh_panels()
		end)
		panel.label(props, stairs and "New stairs: click, or drag the footprint"
				or "New boxes: drag the footprint")
		if stairs then
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
		for _, f in ipairs(stairs and {{"Offset mm", "offset"}} or
				{{"Width mm", "w"}, {"Height mm", "h"}, {"Depth mm", "d"},
				{"Offset mm", "offset"}}) do
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
		panel.button(props, st.sun == 1 and "Sun: on" or "Sun: off", function()
			set(sid, {ints = {sun = 1 - st.sun}})
		end)
		if st.sun == 1 then
			int_field(sid, "Sun from deg", "sun_yaw", st.sun_yaw)
			int_field(sid, "Sun height deg", "sun_pitch", st.sun_pitch)
		end
		panel.field(props, "Eye mm", S.eye, function(t)
			local v = num(t)
			if v and v > 0 then S.eye = v end
		end)
		-- The pictures in the save's images/, and the ones placed, locked
		for _, file in ipairs(doc.images) do
			panel.button(props, "Trace over " .. file, function()
				send({{op = "create", ent = {id = doc.placeholder(), type = "image",
						ints = {x = math.floor(S.cx), z = math.floor(S.cz)},
						strs = {file = file}}}})
			end)
		end
		for _, im in ipairs(of_type("image")) do
			if im.ints.locked == 1 then
				panel.button(props, "Unlock " .. im.strs.file, function()
					set(im.id, {ints = {locked = 0}})
				end)
			end
		end
		panel.field(props, "Export mm/px", S.export_mmpx, function(t)
			local v = tonumber(t)
			if v and v > 0 then S.export_mmpx = v end
		end)
		panel.button(props, "Export the plan view as PNG", function()
			S.exporting = {frame = 0}
		end)
	end
	if not doc.can("edit") then
		panel.label(props, "Viewing only: no edit privilege",
				magic.Color(1, 0.6, 0.4))
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
		{"reflect", "scale", "seed", "angle", "contrast"},
	}
	local KNOB_LABELS = {roughness = "Roughness", specular = "Specular",
		reflect = "Reflective", scale = "Scale mm", seed = "Seed",
		temperature = "Kelvin", brightness = "Brightness", opacity = "Opacity",
		grout = "Grout mm", speckle = "Speckle", angle = "Angle deg",
		contrast = "Grain contrast"}
	-- Knobs in thousandths shown as percent
	local PERCENT = {roughness = true, specular = true, reflect = true,
		brightness = true, opacity = true, speckle = true, contrast = true}

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
		palette_win:Remove()
	end
	palette_win = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 50)
	panel.label(palette_win, S.replacing and "Pick the entry to use instead:"
			or "Palette")
	local cur = default_material()
	local entries = of_type("palette")
	for _, p in ipairs(entries) do
		panel.swatch_row(palette_win, palette_rgb(p.id), "#" .. p.id .. "  " ..
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
		end, 120)
		-- The types as a grid of their previews, opened under the button
		-- ([FP_TYPES]); Esc or the button again closes it
		panel.button(palette_win, "Type: " .. MATERIAL_KINDS[p.kind] ..
				(S.type_open and "  ^" or "  v"), function()
			S.type_open = not S.type_open
			refresh_panels()
		end, S.type_open)
		if S.type_open then
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
			end, 90)
			panel.chip(r, p[name], 14, function()
				S.picker = {ent = cur, field = name, groups = colour_groups(p, name),
						title = e.strs.name .. ": " .. label}
				build_picker()
			end)
		end
		if p.kind ~= 4 then
			colour("Own colour", "base")
			colour("Paint", "color")
			panel.button(palette_win, "Finish: " .. FINISHES[p.finish], function()
				set({finish = (p.finish + 1) % 3})
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
				panel.button(palette_win, AXES[p.axis], function()
					set({axis = (p.axis + 1) % 3})
				end)
			elseif k == "stagger" then
				panel.button(palette_win, p.stagger == 1 and "Staggered" or
						"In a grid", function()
					set({stagger = 1 - p.stagger})
				end)
			else
				local shown = PERCENT[k] and p[k] / 10 or p[k]
				panel.field(palette_win, (k == "scale" and p.kind == 10 and
						"Board mm" or KNOB_LABELS[k]) .. (PERCENT[k] and " %"
						or ""), shown, function(t)
					local v = tonumber(t)
					if v then
						set({[k] = math.floor((PERCENT[k] and v * 10 or v) + 0.5)})
					end
				end, 120)
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
	local w = panel.window(magic.HA_CENTER, magic.VA_TOP, 0, 50)
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
	panel.button(top, "Close", function()
		S.layouts_open = false
		refresh_panels()
	end)
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
		panel.button(w, l.strs.group .. ": " .. l.strs.name, function()
			place.switch(l.id)
			refresh_panels()
		end, l.id == S.layout)
	end
	if not e or not doc.can("edit") then
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
	end)
	panel.field(w, "Group", e.strs.group, function(t)
		set(id, {strs = {group = t}})
	end)
	int_field(id, "X mm", "x", c.x)
	int_field(id, "Y mm", "y", c.y)
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
	build_props()
	build_palette()
	place.build_window()
end
M.refresh_panels = function() refresh_panels() end

-- The pause menu ([FP_ESC]): what Esc opens at the bottom of any view, and
-- a level of its own, so Esc on it is Continue. Its Settings are the
-- planner's; the engine's are the launcher's.
local pause_win = nil
local open_pause, close_pause
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

	local function settings_page()
		local w = dialog("Settings")
		local mute, db = buildat.get_sound()
		panel.button(w, mute and "Sound: muted" or (db <= -33 and "Sound: off" or
				string.format("Sound: %d dB", db)), function()
			-- Muted, then full, then down 6 dB at a time
			if mute then
				buildat.set_sound(false, 0)
			elseif db > -30 then
				buildat.set_sound(false, math.max(-30, db - 6))
			else
				buildat.set_sound(true, 0)
			end
			settings_page()
		end)
		panel.button(w, S.plan_look and "The plan: flat colours (L)" or
				"The plan: the materials (L)", function()
			S.plan_look = not S.plan_look
			set_view(S.view)
			settings_page()
		end)
		panel.button(w, S.show_ids and "Material ids: shown" or
				"Material ids: hidden", function()
			S.show_ids = not S.show_ids
			S.dirty = true
			settings_page()
		end)
		panel.field(w, "Eye mm", S.eye, function(t)
			local v = tonumber(t)
			if v and v > 0 then
				S.eye = math.floor(v)
			end
		end)
		panel.button(w, "Back", function() open_pause() end)
	end

	-- **A copy of the plan** ([FP_COPY]): under a name no plan has, which
	-- is then the plan open; the server says so if the name is taken
	local function copy_page()
		local w = dialog("Copy this plan")
		panel.label(w, "\"" .. doc.plan_name .. "\" as:")
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

	-- **Who may use the plan** ([FP_ACCESS] 4), the admin's; the chat
	-- commands it replaces are gone. The server sends the list at the join
	-- and after every change, and the page follows it while it is open.
	local users_page
	local function secret(e)
		e.echoCharacter = string.byte("*")
		return e
	end

	local function password_page(name)
		local w = dialog("A new password for " .. name)
		local e
		local function set()
			doc.admin("password", name, e:GetText())
			users_page()
		end
		e = secret(panel.field(w, "Password", "", set, 180))
		local r = panel.row(w)
		panel.button(r, "Set", set)
		panel.button(r, "Back", function() users_page() end)
		e:SetFocus(true)
	end

	local function delete_page(name)
		local w = dialog("Delete the account " .. name .. "?")
		panel.label(w, "Their session ends.")
		local r = panel.row(w)
		panel.button(r, "Delete", function()
			doc.admin("delete", name)
			users_page()
		end)
		panel.button(r, "Back", function() users_page() end)
	end

	local function add_page()
		local w = dialog("Add a user")
		local can_edit = true
		local n, p
		local function add()
			doc.admin("add", n:GetText(), p:GetText(), can_edit)
			users_page()
		end
		n = panel.field(w, "Name", "", function() p:SetFocus(true) end, 180)
		p = secret(panel.field(w, "Password", "", add, 180))
		local b
		b = panel.button(w, "Can edit: yes", function()
			can_edit = not can_edit
			b:GetChild(0):SetText(can_edit and "Can edit: yes" or "Can edit: no")
		end)
		local r = panel.row(w)
		panel.button(r, "Add", add)
		panel.button(r, "Back", function() users_page() end)
		n:SetFocus(true)
	end

	users_page = function()
		S.pause_page = "users"
		local w = dialog("Users")
		local u = doc.users
		-- What the last request came to, on a line that is always there so
		-- that the buttons under it do not move when it appears; an
		-- invite's code in a field, to copy
		local message = doc.admin_message or ""
		local code = message:match("^Invite code: (%w+)$")
		if code then
			panel.field(w, "Invite code", code, function() end, 140)
		else
			local l = panel.label(w, message ~= "" and message or " ",
					magic.Color(1.0, 0.8, 0.4))
			-- The field's height, which a code in its place takes
			l.minHeight = 22
		end
		if not u then
			panel.label(w, "Waiting for the server...")
			panel.button(w, "Back", function() open_pause() end)
			return
		end
		for _, user in ipairs(u.users) do
			local has = {}
			for _, p in ipairs(user.privs) do
				has[p] = true
			end
			local r = panel.row(w)
			local l = panel.label(r, user.name .. (user.here == 1 and " (here)" or ""))
			l.minWidth = 140
			-- Who edits what is each plan's (Plan members...); the server's
			-- is who administers it ([FP_PLANS] 1)
			panel.button(r, has.admin and "Admin: yes" or "Admin: no", function()
				doc.admin("priv", user.name, "admin", not has.admin)
			end)
			if user.here == 1 then
				panel.button(r, "Kick", function() doc.admin("kick", user.name) end)
			end
			panel.button(r, "Password...", function() password_page(user.name) end)
			panel.button(r, "Delete...", function() delete_page(user.name) end)
		end
		panel.button(w, "Add a user...", add_page)
		panel.label(w, "Invites (each makes one account):")
		for _, inv in ipairs(u.invites) do
			local r = panel.row(w)
			local l = panel.label(r, inv.code .. "  (" .. inv.by .. ")")
			l.minWidth = 240
			panel.button(r, "Delete", function() doc.admin("uninvite", inv.code) end)
		end
		panel.button(w, "New invite", function() doc.admin("invite") end)
		local a = u.access
		panel.button(w, a.open_registration == 1 and
				"Open registration: on (anyone can make an account)" or
				"Open registration: off (invites only)", function()
			doc.admin("setting", "open_registration", "", a.open_registration ~= 1)
		end)
		panel.button(w, "Back", function()
			doc.admin_message = nil
			open_pause()
		end)
	end
	-- doc's once M.start has it
	M.users_changed = function()
		if pause_win and S.pause_page == "users" then
			users_page()
		end
	end

	-- **Who may use this plan** ([FP_PLANS] 5): its owner's and an admin's.
	-- The server sends the list when they enter it and after every change.
	local members_page
	local PUBLIC_TEXT = {[0] = "Others: cannot see it", [1] = "Others: can read",
			[2] = "Others: can edit"}
	local ROLE_NEXT = {[""] = "viewer", viewer = "editor", editor = ""}
	local ROLE_LABEL = {[""] = "Role: others'", viewer = "Role: reader",
			editor = "Role: editor"}

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
		panel.button(w, PUBLIC_TEXT[m.pub] or "?", function()
			doc.plan_admin("public", "", tostring((m.pub + 1) % 3))
		end)
		for _, member in ipairs(m.members) do
			if member.name ~= m.owner then
				local r = panel.row(w)
				local n = panel.label(r, member.name)
				n.minWidth = 140
				panel.button(r, ROLE_LABEL[member.role] or member.role, function()
					doc.plan_admin("role", member.name,
							ROLE_NEXT[member.role] or "")
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

	-- A user's own password ([FP_ACCESS] 4)
	local function own_password_page(message)
		S.pause_page = "passwd"
		local w = dialog("Change password")
		if message then
			panel.label(w, message, magic.Color(1.0, 0.8, 0.4))
		end
		local old, new1, new2
		local function change()
			if new1:GetText() ~= new2:GetText() then
				return own_password_page("The new passwords differ")
			end
			doc.passwd(old:GetText(), new1:GetText())
		end
		old = secret(panel.field(w, "Old", "", function()
			new1:SetFocus(true) end, 180))
		new1 = secret(panel.field(w, "New", "", function()
			new2:SetFocus(true) end, 180))
		new2 = secret(panel.field(w, "New again", "", change, 180))
		local r = panel.row(w)
		panel.button(r, "Change", change)
		panel.button(r, "Back", function() open_pause() end)
		old:SetFocus(true)
	end
	M.passwd_done = function(text)
		if pause_win and S.pause_page == "passwd" then
			own_password_page(text == "" and "The password was changed" or text)
		end
	end

	open_pause = function()
		S.pause_page = nil
		S.paused = true
		S.press, S.drag = nil, nil
		update_capture()
		local w = dialog("Paused")
		panel.button(w, "Continue (Esc)", function() close_pause() end)
		panel.button(w, "Settings", settings_page)
		if doc.privs.admin then
			panel.button(w, "Users...", function()
				doc.admin("list")
				users_page()
			end)
		end
		if doc.privs.manage then
			panel.button(w, "Plan members...", function()
				doc.plan_admin("list")
				members_page()
			end)
		end
		if not doc.is_local then
			panel.button(w, "Change password...", function() own_password_page() end)
		end
		-- Anyone makes a copy, which is theirs, and goes back to the plans
		-- ([FP_PLANS] 4, 5)
		panel.button(w, "Copy this plan...", copy_page)
		panel.button(w, "Other plan...", function()
			close_pause()
			doc.close_plan()
		end)
		panel.button(w, "Leave to the launcher", function() buildat.leave() end)
		panel.button(w, "Quit", function() buildat.quit() end)
	end

	close_pause = function()
		if pause_win then
			pause_win:Remove()
			pause_win = nil
		end
		S.paused = false
		update_capture()
	end
end

local function over_ui()
	local s = magic.ui.scale
	return panel.over({toolbar, props, palette_win, pause_win, picker_win,
			place.win}, S.mx / s,
			S.my / s)
end

local press_target, plan_facing, plan_aligned, stream_drag, use, use_target, walk
do
	--
	-- Input
	--
	-- What a left press would take, for the select and node tools: the same
	-- pick for the click and for what the guide shows. In the select tool an
	-- object under the cursor wins, then a node near it, then the wall,
	-- picture or room it is on.
	press_target = function()
		local x, z = cursor_floor()
		if S.tool == "select" then
			local s = pick_surface()
			if s and s.kind == "instance" then
				return {kind = "instance", id = s.id}
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
			S.sel_face[t.id] = t.side
			palette_follows(t)
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
				local it = inst_data[id]
				if i and it and it.hosted then
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
				if S.shape == "stairs" then
					add_box(x, z, S.stairs.w, nil)
				else
					add_box(x, z, S.box.w, S.box.d)
				end
			end
		elseif S.tool == "hosted" then
			local s = pick_surface()
			if s and s.kind == "wall" and doc.can("edit") then
				add_hosted(s.id, s.x, s.z, s.side)
			end
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
	-- at none of the plan, the middle of the box round all its rooms, up to
	-- half their highest ceiling (user)
	local function camera_pivot(orbit)
		local o, d = cursor_ray()
		local s = pick_surface()
		if s and s.t then
			return {x = o.x + d.x * s.t, y = o.y + d.y * s.t, z = o.z + d.z * s.t}
		end
		if orbit and next(room_data) then
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
		local x, z, t = ray_at_height(0)
		if x then
			return {x = o.x + d.x * t, y = 0, z = o.z + d.z * t}
		end
		return nil
	end

	function M.mouse_down(button)
		if S.paused then
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
			-- Walking: the right button is Luanti's use, a door or a switch
			use()
			return
		end
		if S.captured and S.tool == "voxel" then
			-- Luanti's: the left button digs, the right one places
			if button == magic.MOUSEB_LEFT then
				voxel_edit(true, S.shift)
			elseif button == magic.MOUSEB_RIGHT then
				voxel_edit(false, S.shift)
			end
			return
		end
		if button == magic.MOUSEB_RIGHT then
			if S.draw or S.corners then
				S.draw = nil
				S.corners = nil
				S.typed = ""
				return
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
		if S.swallow_up then
			S.swallow_up = false
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
		if S.orbit then
			-- The camera goes round the point with the view: its offset from
			-- the point is held in the camera's own frame, so the point stays
			-- where it was on the screen
			local p = S.orbit
			local ox, oy, oz = geom.unrot(S.pos.x - p.x, S.pos.y - p.y,
					S.pos.z - p.z, S.pitch, S.yaw, 0)
			S.yaw = S.yaw + dx * 0.3
			S.pitch = math.max(-90, math.min(90, S.pitch + dy * 0.3))
			local wx, wy, wz = geom.rot(ox, oy, oz, S.pitch, S.yaw, 0)
			S.pos = {x = p.x + wx, y = p.y + wy, z = p.z + wz}
			return
		end
		if S.pan3d then
			-- Across the view, as far as the pointed point moves under the
			-- pointer
			local _, h = screen_size()
			local k = S.pan3d.dist * 2 * math.tan(math.rad(cam3d.fov) / 2) / h
			local rx, ry, rz = geom.rot(1, 0, 0, S.pitch, S.yaw, 0)
			local ux, uy, uz = geom.rot(0, 1, 0, S.pitch, S.yaw, 0)
			S.pos = {x = S.pos.x - (rx * dx - ux * dy) * k,
					y = S.pos.y - (ry * dx - uy * dy) * k,
					z = S.pos.z - (rz * dx - uz * dy) * k}
			return
		end
		if S.looking then
			S.yaw = S.yaw + dx * 0.15
			S.pitch = math.max(-89, math.min(89, S.pitch + dy * 0.15))
			return
		end
		if S.walk_drag then
			-- 10 mm a pixel, Shift two and a half times that as it runs
			local mm = S.shift and 25 or 10
			walk(0, -dy, dx, mm)
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

	-- A switch's lamps, all on or all off: on unless any of them is on
	local function flip_switch(id)
		local lamps = doc.ents[id].lists.lamps
		if #lamps == 0 then
			doc.notice("This switch has no lamps; link some to it")
			return
		end
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

	function M.key_down(key, event_data)
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
		if key == magic.KEY_ESCAPE then
			-- Down one level ([FP_ESC]): the pause menu, the crosshair, what is
			-- in progress; at the bottom of a view, the pause menu
			if S.paused then
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
			else
				open_pause()
			end
		elseif S.paused then
			-- The pause menu takes the keys
		elseif key == magic.KEY_F and S.view == "walk" then
			S.walk.noclip = not S.walk.noclip
			doc.notice(S.walk.noclip and "Noclip: walls do not stop you; Space and C"
					.. " go up and down" or "Noclip off")
		elseif key == magic.KEY_E then
			use()
		elseif key == magic.KEY_U then
			go_to_next_user()
		elseif key == magic.KEY_L then
			S.plan_look = not S.plan_look
			set_view(S.view)
		elseif key == magic.KEY_F1 then
			set_view("2d")
		elseif key == magic.KEY_F2 then
			set_view("3d")
		elseif key == magic.KEY_F3 then
			set_view("walk")
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
		elseif key == magic.KEY_K then
			set_tool("voxel")
		elseif key == magic.KEY_I then
			-- Again: the next of opening, door and window
			if S.tool == "hosted" then
				S.hosted = NEXT_HOSTED[S.hosted]
			end
			set_tool("hosted")
		elseif key == magic.KEY_M then
			set_tool("paint")
		elseif key == magic.KEY_G then
			next_grid()
		elseif key == magic.KEY_H then
			S.angle = S.angle % #ANGLE_STEPS + 1
			refresh_panels()
		elseif key == magic.KEY_DELETE then
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
			if input:GetKeyDown(magic.KEY_SPACE) then u = u + 1 end
			if input:GetKeyDown(magic.KEY_C) then u = u - 1 end
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
	if S.view == "walk" then
		walk(dt, f, r)
		return
	end
	if input:GetKeyDown(magic.KEY_SPACE) then u = u + 1 end
	if input:GetKeyDown(magic.KEY_C) then u = u - 1 end
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

local crosshair = magic.ui.root:CreateChild("Text")
crosshair:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
crosshair:SetText("+")
crosshair:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
crosshair.visible = false

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
			return {hl = {}, left = walking and
					"into the crosshair: walk, look and point (Esc: back)" or
					"into the crosshair to dig and place (Esc: back)",
					right = walking and "drag: turn" or nil,
					middle = walking and "drag: walk" or nil}
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
			g.right = (pick_surface() or not next(room_data)) and
					"drag: orbit round what the pointer is on" or
					"drag: orbit round the middle of the plan"
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
			else
				what = (open_amount(uid) > 0 and "close " or "open ") .. name_of(uid)
			end
			g.use = what
			hl({kind = "instance", id = uid, col = PLACE})
			if S.captured and S.tool ~= "voxel" then
				g.right = what
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
		local tool = S.tool
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
					g.left = "keep " .. name .. " selected" ..
							(edit and "; drag: move the selection" or "")
				else
					g.left = "select " .. name .. (t.kind == "wall" and t.side and
							(" by its " .. (t.side == "core" and "top" or
							t.side .. " face")) or t.kind == "room" and t.side and
							(" by its " .. t.side) or "") ..
							(edit and "; drag: move it" or "")
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
				g.left = S.shape == "stairs" and "put stairs here, " ..
						S.stairs.w .. " mm wide, of " .. mat_text(cur) ..
						"; drag: draw their footprint" or
						"put a box here, " .. S.box.w .. " x " .. S.box.d ..
						" mm, of " .. mat_text(cur) .. "; drag: draw its footprint"
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
			else
				local hit, place = voxel_ray(id)
				if hit then
					hl({kind = "cell", id = id, c = hit, col = DIG})
					g.left = "dig this voxel (" .. mat_text(cell_of(id, hit)) ..
							"); Shift+click: make it " .. mat_text(cur)
				end
				if place and math.max(math.abs(place[1] + 0.5), math.abs(place[2] +
						0.5), math.abs(place[3] + 0.5)) < 128 then
					hl({kind = "cell", id = id, c = place, col = PLACE})
					g.right = "place a voxel of " .. mat_text(cur) .. " here"
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
		for _, b in ipairs({{"left", "Left"}, {"right", "Right"},
				{"middle", "Middle"}, {"use", "E"}}) do
			if g[b[1]] then
				lines[#lines + 1] = b[2] .. ": " .. g[b[1]]
			end
		end
		if g.note then
			lines[#lines + 1] = g.note
		end
		return table.concat(lines, "\n")
	end

	-- A cell of a volume as its 12 edges
	local function cell_box(id, c, col)
		local it = inst_data[id]
		if not it then
			return
		end
		local sz = it.size
		local function corner(dx, dy, dz)
			local x, y, z = geom.rot((c[1] + dx) * sz, (c[2] + dy) * sz,
					(c[3] + dz) * sz, it.pitch, it.yaw, it.roll)
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
			elseif h.kind == "image" and image_data[h.id] then
				outline(image_data[h.id].foot, col)
			elseif h.kind == "cell" then
				cell_box(h.id, h.c, col)
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
		for id, it in pairs(inst_data) do
			if it.hosted then
				plan_symbol(id, it, line)
			elseif it.y0 >= cut then
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

-- The plan view at S.export_mmpx, without the panels, as a screenshot:
-- one frame to draw it that way, the shot at the end of the next
local function export_step()
	local e = S.exporting
	if not e then
		return
	end
	local _, h = screen_size()
	if e.frame == 0 then
		e.view, e.span = S.view, S.span
		set_view("2d")
		S.span = S.export_mmpx * h
		for _, w in ipairs({toolbar, props, palette_win}) do
			w.visible = false
		end
	elseif e.frame == 2 then
		local name, why = buildat.take_screenshot()
		doc.notice(name and ("Exported " .. name .. " at " .. S.export_mmpx ..
				" mm/px") or ("Could not export: " .. tostring(why)))
	elseif e.frame == 4 then
		S.span = e.span
		S.exporting = nil
		set_view(e.view)
		return
	end
	e.frame = e.frame + 1
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
	S.layout, S.layouts_open = nil, false
	place.build_window()
	for _, n in ipairs(SCENE_PARTS) do
		n.enabled = false
	end
	for _, w in ipairs({toolbar, props, palette_win}) do
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

function M.resume()
	S.suspended = false
	walls_node.enabled = true
	images_node.enabled = true
	decals_node.enabled = true
	lamps_node.enabled = true
	for _, w in ipairs({toolbar, props, palette_win}) do
		if w then
			w.visible = true
		end
	end
	-- The rest of the scene's parts are set by the view
	set_view(S.view)
	S.dirty = true
end

function M.update(dt)
	if S.suspended then
		return
	end
	export_step()
	move_camera(dt)
	place_cameras()
	send_presence(dt)
	stream_drag(dt)
	if S.dirty then
		rebuild()
	end
	if S.panels_stale and not doc.typing() then
		refresh_panels()
	end
	label_i = 0
	S.guide = compute_guide()
	local text = S.exporting and "" or guide_text(S.guide)
	if hud.text ~= text then
		hud:SetText(text)
	end
	draw_overlay()
	for i = label_i + 1, #label_nodes do
		label_nodes[i].visible = false
	end
end

function M.start(d)
	doc = d
	doc.users_changed, doc.passwd_done = M.users_changed, M.passwd_done
	doc.members_changed = M.members_changed
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
	doc.privs_changed = refresh_panels
	doc.others_changed = function()
		S.dirty = true
	end
	doc.voxels_changed = function()
		S.dirty = true
		refresh_panels()
	end
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
