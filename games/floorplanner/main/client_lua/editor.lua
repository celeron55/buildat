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
	box = "O", hosted = "I", paint = "P"}
-- What a definition is, as main.cpp's DefKind
local KIND = {box = 0, voxel = 1, opening = 2, door = 3, window = 4}
local KIND_NAMES = {[0] = "Box", [2] = "Opening", [3] = "Door",
	[4] = "Window"}
-- A new opening, door and window
local HOSTED = {
	[2] = {w = 900, h = 2100, sill = 0},
	[3] = {w = 900, h = 2100, sill = 0},
	[4] = {w = 1200, h = 1200, sill = 900},
}
-- A door leaf's thickness and the gap round it, and a window's frame
local LEAF_T, LEAF_GAP, FRAME_W = 40, 4, 50

local S = {
	view = "2d",
	plan_look = true, -- the plan view in flat colours (L)
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
	hosted = 3,     -- what the door/window tool puts in a wall
	-- Doors and windows a viewer has opened, which only they see
	local_open = {},
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
local lit_material = magic.cache:GetResource("Material", "main/palette.xml")
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
	-- A number is a palette row, for the palette's shader; a Color is a
	-- flat colour, for the plan view's own
	local row = 0
	if type(col) == "number" then
		row, col = col, WHITE
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
local function box_geometry(g, hx, hy, hz, col, cx, cy, cz)
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

-- The palette's rows: 0 is what has no material, 1 the glass a window has
-- when it was given none, and the entries follow in id order
local palette_rows = {}
local palette_key = nil

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
	local entries = doc.of_type("palette")
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
	local n = #entries + 2
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
	for i, e in ipairs(entries) do
		local p = e.ints
		local y = i + 1
		palette_rows[e.id] = y
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
	end
	local texture = magic.Texture2D:new()
	-- One level: a smaller one would average the rows' knobs together
	texture:SetNumLevels(1)
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = magic.FILTER_NEAREST
	M.kept[#M.kept + 1] = texture
	M.kept[#M.kept + 1] = image
	for _, m in ipairs({lit_material, glass_material}) do
		m:SetTexture(magic.TU_DIFFUSE, texture)
		m:SetShaderParameter("PaletteRows", n)
	end
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
local function build_inst_data()
	inst_data = {}
	local d = S.drag
	for _, e in ipairs(doc.of_type("instance")) do
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
				it = {x = f.ax + f.ux * along + f.nx * mid,
						z = f.az + f.uz * along + f.nz * mid,
						y = i.sill + p.h / 2, yaw = f.yaw, pitch = 0, roll = 0,
						ex = p.w + 2 * trim, ey = p.h, ez = f.lo + f.ro + 2 * td,
						hosted = true, along = along, frame = f}
			end
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
	local f = it.frame
	local ox, oz = f.ax + f.ux * it.along, f.az + f.uz * it.along
	local function part()
		local g, node = geometry(pieces_node)
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

-- simplified: everything is rebuilt on any change, which at a few hundred
-- walls is milliseconds; the upgrade is rebuilding only what is at the
-- nodes that moved
local function rebuild()
	palette_texture()
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
		if it.hosted then
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
						local g = geometry(walls_node)
						extrude(g, pts, labels, part[1], part[2], cols, part[1] > 0)
						commit(g, lit_material)
						cap(pts, part[1], part[2], magic.Color(0.16, 0.16, 0.18),
								magic.Color(0.55, 0.55, 0.58))
					end
				end
			end
		end
	end

	for id, r in pairs(room_data) do
		local e = doc.ents[id]
		if #r.pts >= 3 then
			local g = geometry(walls_node)
			flat_polygon(g, r.pts, 2, UP, row(e.ints.mat_floor))
			commit(g, lit_material)
			local cg = geometry(overhead_node)
			flat_polygon(cg, r.pts, room_ceiling(e), DOWN,
					row(e.ints.mat_ceiling))
			commit(cg, lit_material)
		end
	end

	for id, it in pairs(inst_data) do
		local def = doc.ents[it.def].ints
		local e = doc.ents[id].ints
		if it.hosted then
			build_hosted(id, it, def, e, geometry, commit)
		elseif def.kind == KIND.box then
			local g, node = geometry(e.align == 1 and overhead_node or walls_node)
			node.position = magic.Vector3(W(it.x), W(it.y), W(it.z))
			node.rotation = magic.Quaternion(it.pitch, it.yaw, it.roll)
			local rgb = palette_rgb(def.mat)
			box_geometry(g, W(def.w) / 2, W(def.h) / 2, W(def.d) / 2,
					row(def.mat))
			commit(g, lit_material)
			cap(it.foot, it.y0, it.y1, rgb_color(rgb, 0.7), rgb_color(rgb, 0.9))
		end
	end
	pieces_node.enabled = S.view == "3d"
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
				return {kind = "wall", id = id, side = side, x = x, z = z}
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
		local half = doc.placeholder()
		add_op(b, "create", {id = half, type = "wall", ints = f})
		-- What is in the wall past the split goes with the second half
		for _, inst in ipairs(doc.of_type("instance")) do
			if inst.ints.host == e.wall and inst.ints.along > ref.t then
				add_op(b, "set", {id = inst.id, ints = {host = half,
						along = inst.ints.along - ref.t}})
			end
		end
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

-- A door, window or opening put in a wall where the point is along it
local function add_hosted(wall, x, z)
	local f = wall_frame(wall)
	if not f then
		return
	end
	local kind = S.hosted
	local d = HOSTED[kind]
	local along = geom.snap((x - f.ax) * f.ux + (z - f.az) * f.uz, grid_step())
	along = math.max(d.w / 2, math.min(f.len - d.w / 2, along))
	local def = doc.placeholder()
	local mat = default_material()
	send({
		{op = "create", ent = {id = def, type = "definition", ints = {
				kind = kind, w = d.w, h = d.h, mat = mat, mat_leaf = mat,
				trim = kind == KIND.opening and 0 or 70}}},
		{op = "create", ent = {id = doc.placeholder(), type = "instance",
				ints = {def = def, host = wall, along = math.floor(along + 0.5),
				sill = d.sill}}},
	})
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
	-- The plan view's look: flat colours, or the materials lit
	local flat = v == "2d" and S.plan_look and 1 or 0
	lit_material:SetShaderParameter("PlanLook", flat)
	glass_material:SetShaderParameter("PlanLook", flat)
	caps_node.enabled = v == "2d"
	pieces_node.enabled = v == "3d"
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
			{"hosted", "Door/window"}, {"paint", "Paint"}}) do
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
		if p.kind ~= KIND.opening then
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
			panel.label(props, "The palette entry on:")
			local r2 = panel.row(props)
			for _, slot in ipairs({{"Frame", "mat"}, {"Leaf", "mat_leaf"},
					{"Glass", "mat_glass"}}) do
				panel.button(r2, slot[1], function()
					set(i.def, {ints = {[slot[2]] = default_material()}})
				end)
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
	elseif S.tool == "hosted" then
		panel.label(props, "Click a wall to put in (I: the next):")
		local r = panel.row(props)
		for _, k in ipairs({KIND.opening, KIND.door, KIND.window}) do
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

local MATERIAL_KINDS = {[0] = "Drywall", "Wood", "Stone", "Wallpaper", "Lamp",
	"Glass", "Metal", "Tile", "Fabric", "Plaster"}
local FINISHES = {[0] = "Over its colour", "White undercoat", "Stain"}
local AXES = {[0] = "Grain along X", "Grain along Y", "Grain along Z"}
-- Which knobs each type has, beyond the colours and the finish
local KNOBS = {
	[0] = {"roughness", "specular", "reflect"},
	{"roughness", "specular", "reflect", "scale", "seed", "axis"},
	{"roughness", "specular", "reflect", "scale", "seed", "color2"},
	{"specular", "scale", "seed", "color2"},
	{"temperature", "brightness"},
	{"opacity", "specular", "reflect"},
	{"roughness", "specular", "reflect", "scale"},
	{"roughness", "specular", "reflect", "scale", "grout", "stagger", "color2"},
	{"scale"},
	{"roughness", "specular", "scale", "seed", "speckle"},
}
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
}
local KNOB_LABELS = {roughness = "Roughness", specular = "Specular",
	reflect = "Reflective", scale = "Scale mm", seed = "Seed",
	temperature = "Kelvin", brightness = "Brightness", opacity = "Opacity",
	grout = "Grout mm", speckle = "Speckle"}
-- Knobs in thousandths shown as percent
local PERCENT = {roughness = true, specular = true, reflect = true,
	brightness = true, opacity = true, speckle = true}

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

local function build_palette()
	if palette_win then
		palette_win:Remove()
	end
	palette_win = panel.window(magic.HA_LEFT, magic.VA_TOP, 8, 50)
	panel.label(palette_win, S.replacing and "Pick the entry to use instead:"
			or "Palette")
	local cur = default_material()
	local entries = doc.of_type("palette")
	for _, p in ipairs(entries) do
		local r = panel.row(palette_win)
		panel.swatch(r, palette_rgb(p.id), function()
			if S.replacing then
				if p.id ~= S.replacing then
					replace_entry(S.replacing, p.id)
				end
				S.replacing = nil
			end
			S.material = p.id
			refresh_panels()
		end, p.id == cur)
		panel.label(r, p.strs.name .. "  (" .. MATERIAL_KINDS[p.ints.kind] .. ")",
				p.id == cur and magic.Color(1.0, 0.85, 0.3) or nil)
	end
	local e = doc.ents[cur]
	local function set(ints, strs)
		send({{op = "set", ent = {id = cur, ints = ints, strs = strs}}})
	end
	if e then
		local p = e.ints
		panel.field(palette_win, "Name", e.strs.name, function(t)
			set(nil, {name = t})
		end, 120)
		panel.button(palette_win, "Type: " .. MATERIAL_KINDS[p.kind], function()
			-- A new type starts from its own look
			local k = (p.kind + 1) % 10
			local d = KIND_DEFAULTS[k]
			set({kind = k, base = d.base, color2 = d.color2, scale = d.scale,
					roughness = d.roughness, specular = d.specular})
		end)
		local function colour(label, name)
			panel.field(palette_win, label, string.format("%06x", p[name]),
					function(t)
				local v = tonumber(t, 16)
				if v and v >= 0 and v <= 0xffffff then set({[name] = v}) end
			end, 120)
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
				panel.field(palette_win, KNOB_LABELS[k] .. (PERCENT[k] and " %"
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
	elseif S.tool == "hosted" then
		local s = pick_surface()
		if s and s.kind == "wall" and doc.can("edit") then
			add_hosted(s.id, s.x, s.z)
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
	if M.after_drag then
		M.after_drag = false
		doc.unlock()
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
		lock_drag()
	end
	if S.drag then
		update_drag()
	end
end

-- The previews go out at most every PREVIEW_SECONDS
local function stream_drag(dt)
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
	local p = o.p
	if p.view == 1 then
		S.pos = {x = p.px / 1000, y = p.py / 1000, z = p.pz / 1000}
		S.yaw, S.pitch = p.yaw / 1000, p.pitch / 1000
		set_view("3d")
	else
		S.cx, S.cz, S.span = p.px, p.pz, math.max(500, p.py)
		set_view("2d")
	end
	doc.notice("At " .. o.name .. "'s view")
end

-- The use key: a door or window under the cursor opens or closes. For an
-- editor for everybody; a viewer opens it for themselves.
local function use()
	local s = pick_surface()
	local id = s and s.kind == "instance" and s.id
	local e = id and doc.ents[id]
	if not e or e.ints.host == 0 then
		return
	end
	local kind = doc.ents[e.ints.def].ints.kind
	if kind ~= KIND.door and kind ~= KIND.window then
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
	elseif key == magic.KEY_E then
		use()
	elseif key == magic.KEY_U then
		go_to_next_user()
	elseif key == magic.KEY_L then
		S.plan_look = not S.plan_look
		set_view(S.view)
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
	elseif key == magic.KEY_I then
		-- Again: the next of opening, door and window
		if S.tool == "hosted" then
			S.hosted = S.hosted % 3 + 2
		end
		set_tool("hosted")
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
	if def.kind == KIND.window then
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
	-- The others: their cursors, their cameras, what they have selected
	for _, o in pairs(doc.others) do
		local p = o.p
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
				world_label(p.px, S.view == "3d" and p.py or 0, p.pz, o.name)
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
	local p = {view = S.view == "3d" and 1 or 0,
			cx = math.floor(cx or 0), cz = math.floor(cz or 0), sel = sel,
			yaw = math.floor(S.yaw * 1000), pitch = math.floor(S.pitch * 1000)}
	if S.view == "3d" then
		p.px, p.py, p.pz = math.floor(S.pos.x * 1000), math.floor(S.pos.y * 1000),
				math.floor(S.pos.z * 1000)
	else
		p.px, p.py, p.pz = math.floor(S.cx), math.floor(S.span), math.floor(S.cz)
	end
	doc.send_presence(p)
end

function M.update(dt)
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
	doc.others_changed = function()
		S.dirty = true
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
