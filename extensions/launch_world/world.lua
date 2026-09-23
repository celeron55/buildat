-- extensions/launch_world: [LAUNCH_WORLD], the room you start in.
--
-- **An extension, not a game** (user, 2026-09-23): the room *is* the
-- launcher, and starting a game is `ctx.launch` on the launcher's own
-- trusted side, which a game cannot call. So it needs no server process:
-- the voxels are described in room.lua, built here and meshed straight
-- into a node of this extension's own scene.
--
-- What that costs, as the plan said it would: no voxelworld means no
-- skylight flood and no baked ambient occlusion, so the wall's relief
-- rests entirely on the real lights; and the dissolve is a rewrite of the
-- block and a re-mesh rather than voxel removal on a server.
--
-- Run it with `Build/bin/buildat -m launch_world`.
local log = buildat.Logger("launch_world")
local magic = require("buildat/extension/urho3d").safe
local EXT = buildat.extension_path("launch_world")
local room = dofile(EXT .. "/room.lua")

-- The ornament generator and the maps it feeds; see ornament.lua
local ornament = dofile(EXT .. "/ornament.lua")
-- **The voxel tiles are generated here and registered by name**, which
-- is the only way a generated picture reaches a voxel atlas: a tile is
-- loaded out of the resource cache by the name the voxel definition
-- gives, and this puts one there under it. The plan's rule is that the
-- generator and its seed are the source and the picture is a build
-- artefact, never committed -- so this is where the wall's material
-- comes from.
--
-- **Before the room is meshed**, or a face is drawn before its texture
-- exists and is drawn without it.
tiles = {}
local function register_tile(name, h, inlay, opts)
	local diff = ornament.maps(magic, h, inlay, opts)
	assert(magic.cache:AddManualResource(diff, name),
			"the generated tile went into the cache")
	-- Held: a resource the cache has is the cache's, but the wrapper is
	-- this script's and the Image would go with it. Its own table,
	-- because the tiles are registered before the world may stream and
	-- that is earlier than anything else here is built.
	tiles[#tiles + 1] = diff
	log:info("tile: generated/" .. name)
end

do
	local wh, wi = ornament.wall(128, ornament.seed_of("launch_world wall"))
	-- Matte cut stone, and the mineral patches a shade off it rather than
	-- a colour: what varies is the mineral, not the paint
	register_tile("wall.png", wh, wi,
			{base = magic.Color(0.50, 0.51, 0.55, 1),
			inlay = magic.Color(0.40, 0.42, 0.40, 1), relief = 0.35,
			strength = 2})
end
do
	-- The pockets' side columns, which are the one place the ornament
	-- goes now that the wall is one material ([LAUNCH_WORLD]: "the
	-- ornament is on its side columns and nowhere else")
	local ch, ci = ornament.meander(128, {units = 2, depth = 2})
	register_tile("column.png", ch, ci,
			{base = magic.Color(0.46, 0.47, 0.52, 1),
			inlay = magic.Color(0.22, 0.20, 0.26, 1), relief = 0.8,
			strength = 4})
end

-- The room's sound, synthesised; see synth.lua
local synth = dofile(EXT .. "/synth.lua")

-- Held at module scope: a Lua-owned Image, Texture2D or Material is freed
-- when the last Lua reference goes, whatever is drawing with it
local kept = {}

-- **The room is authored in metres and lives on a 45 cm grid** (user's
-- reading of the reference frame: the eye sits at the centre of the
-- fourth stacked slab, which is 3.5 voxels to a 1.6 m eye). So one unit
-- of the scene is one voxel, and everything written below in metres is
-- multiplied by this on its way in -- which is what lets the numbers stay
-- readable while the voxelworld gets the grid it wants.
local VOXEL_M = 0.45
local U = 1 / VOXEL_M

-- Metres to units, for the places that do not go through part()
local function V(x, y, z)
	return magic.Vector3(x * U, y * U, z * U)
end


-- The classic raytrace floor, built rather than loaded: a 2x2 checker is
-- the one texture the look actually needs
-- The classic raytrace floor, built rather than loaded. squares is how
-- many across the image, since Plane.mdl's UVs run 0..1 over the whole
-- plane: at one square per half of it the floor is two grey rectangles,
-- not a checkerboard.
local function checker_texture(size, squares, a, b, filter)
	local image = magic.Image:new()
	assert(image:SetSize(size, size, 3), "Image:SetSize")
	local cell = size / squares
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local dark = (math.floor(x / cell) + math.floor(y / cell)) % 2 == 1
			image:SetPixel(x, y, dark and a or b)
		end
	end
	local texture = magic.Texture2D:new()
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = filter or magic.FILTER_NEAREST
	kept[#kept + 1] = image
	kept[#kept + 1] = texture
	return texture
end

-- Urho3D's PBR techniques, on the client's own render path -- no render
-- path control needed, and none of the preferred-viewport machinery is in
-- the way. What they do want is PBR_INTENSITY below.
-- simplified: a diffuse colour, a roughness and a metalness, and no
-- material maps at all. The library of generated maps is the ornament
-- generator's work, further down the list.
local function material(colour, roughness, metallic, texture)
	local m = magic.Material:new()
	-- BUILDAT_LAUNCH_NOPBR=1 puts the stock non-PBR techniques on
	-- instead, which is the last thing between a scene that lights in
	-- HDR here and one that does not
	local pbr = (buildat.get_env("BUILDAT_LAUNCH_NOPBR") or "") == ""
	local t = magic.cache:GetResource("Technique",
			pbr and (texture and "Techniques/PBR/PBRDiff.xml" or
			"Techniques/PBR/PBRNoTexture.xml") or
			(texture and "Techniques/Diff.xml" or
			"Techniques/NoTexture.xml"))
	assert(t ~= nil, "the technique loaded")
	m:SetTechnique(0, t)
	if texture then m:SetTexture(magic.TU_DIFFUSE, texture) end
	m:SetShaderParameter("MatDiffColor", colour)
	m:SetShaderParameter("Roughness", roughness)
	m:SetShaderParameter("Metallic", metallic)
	kept[#kept + 1] = m
	return m
end

-- **The room's own scene.** There is no server and so no replicated
-- scene; the voxels are meshed into a node of this one like any other
-- model.
scene = magic.Scene()
scene:CreateComponent("Octree")

-- **The floor's two tiles and the dark under it**, generated like the
-- wall is: the plan's rule is that everything is generated and nothing
-- generated is committed, and as an extension there is no client_data
-- directory to put a picture in anyway.
do
	-- A field of nought: these three are colours, and what makes them a
	-- surface is the finish in the voxel definition, not a picture
	local flat = {size = 16}
	for i = 1, 16 * 16 do flat[i] = 0 end
	register_tile("floor_light.png", flat, flat,
			{base = magic.Color(0.72, 0.73, 0.76, 1), relief = 0})
	register_tile("floor_dark.png", flat, flat,
			{base = magic.Color(0.10, 0.10, 0.12, 1), relief = 0})
	register_tile("dark.png", flat, flat,
			{base = magic.Color(0.05, 0.05, 0.06, 1), relief = 0})
end

-- **The voxel registry, in the order room.lua's ids are read back from.**
-- The atlas takes the normal and roughness maps off each tile's own
-- luminance, so what is set here is the finish and not a picture.
local voxel_reg = buildat.safe.createVoxelRegistry()
local atlas_reg = buildat.safe.createAtlasRegistry()
local function add_voxel(name, texture, solid, roughness, spec_strength,
		bumpiness, uv_scale)
	local vdef = buildat.safe.VoxelDefinition()
	vdef.name.block_name = name
	vdef.name.segment_x = 0
	vdef.name.segment_y = 0
	vdef.name.segment_z = 0
	vdef.name.rotation_primary = 0
	vdef.name.rotation_secondary = 0
	vdef.handler_module = ""
	local textures = {}
	for i = 1, 6 do
		local seg = buildat.safe.AtlasSegmentDefinition()
		seg.resource_name = texture or ""
		seg.total_segments = magic.IntVector2(texture and 1 or 0,
				texture and 1 or 0)
		seg.select_segment = magic.IntVector2(0, 0)
		seg.roughness = roughness or 0.9
		seg.spec_strength = spec_strength or 0.3
		seg.bumpiness = bumpiness or 0.5
		seg.translucency = 0.0
		seg.spots = 0.0
		seg.static_spots = 0.0
		textures[i] = seg
	end
	vdef.textures = textures
	vdef.edge_material_id = solid and
			buildat.safe.VoxelDefinition.EDGEMATERIALID_GROUND or
			buildat.safe.VoxelDefinition.EDGEMATERIALID_EMPTY
	vdef.physically_solid = solid
	vdef.fully_empty = not solid
	-- How many voxels this voxel's texture spans before it repeats
	-- ([WORLD_UV]); 1 is one stamp a voxel, as it always was
	vdef.uv_scale = uv_scale or 1
	return voxel_reg:add_voxel(vdef)
end

room.id.air = add_voxel("air", nil, false)
-- **The wall's own material**, spanning eight voxels before it repeats so
-- that it reads as one cut surface rather than as a grid of stamps
room.id.stone = add_voxel("stone", "generated/wall.png", true,
		0.85, 0.10, 0.7, 8)
room.id.dark = add_voxel("dark", "generated/dark.png", true, 0.95, 0.1, 0.4)
-- The pockets' side columns, which are the one place the ornament goes
room.id.column = add_voxel("column", "generated/column.png", true,
		0.70, 0.20, 0.9, 4)
-- The checkerboard: the light squares are polished, which is what puts
-- the room's reflection in the floor
room.id.floor_light = add_voxel("floor_light", "generated/floor_light.png",
		true, 0.18, 1.0, 0.2)
room.id.floor_dark = add_voxel("floor_dark", "generated/floor_dark.png",
		true, 0.22, 1.0, 0.2)

-- **The room in chunks across x**, so that a dissolve re-meshes the one
-- or two the bay touches rather than the whole room. Each chunk is told
-- where its own zero sits, which is what a voxel of uv_scale > 1 takes
-- its slice of the repeat from ([WORLD_UV]).
-- **The room's geometry is drawn with voxel_shading's own technique**, the
-- one builtin/voxel_shading hands voxelworld's chunks. There is no server
-- to send that module's client_data, so the client's resource router
-- falls back to builtin/<module>/client_data for a name nobody announced;
-- the mesher itself sets no technique, and a node without one is
-- invisible rather than unlit (2026-09-23).
local VOXEL_TECHNIQUE = magic.cache:GetResource("Technique",
		"voxel_shading/PBRVoxel.xml")
assert(VOXEL_TECHNIQUE, "voxel_shading/PBRVoxel.xml is in the cache")
local function apply_technique(node)
	local cg = node:GetComponent("CustomGeometry")
	local i = 0
	while true do
		local m = cg:GetMaterial(i)
		if m == nil then break end
		m:SetTechnique(0, VOXEL_TECHNIQUE)
		-- The mesher does not pack the sky into the vertex alpha here, and
		-- the shadow-kind diagnostic is off
		m:SetShaderParameter("PackedSky", 0.0)
		m:SetShaderParameter("ShadowKinds", 0.0)
		i = i + 1
	end
end

local CHUNK = 16
local rows = room.build()
local chunk_nodes = {}
local function mesh_chunk(c)
	local x0 = c * CHUNK
	local w = math.min(CHUNK, room.W - x0)
	local data = {}
	local n = 0
	for r = 1, #rows do
		n = n + 1
		data[n] = rows[r]:sub(x0 + 1, x0 + w)
	end
	local node = chunk_nodes[c]
	if not node then
		node = scene:CreateChild("room" .. c)
		-- **The mesher centres a block on its node** (mesh.cpp: every
		-- vertex is its voxel less half the block), so the node goes to
		-- the block's middle rather than to its corner. The half is the
		-- voxel's own: a voxel v fills [v, v + 1), which is what makes
		-- the floor's top face the room's metre zero.
		node.position = magic.Vector3(room.OX + x0 + w / 2 + 0.5,
				room.OY + room.H / 2 + 0.5, room.OZ + room.D / 2 + 0.5)
		chunk_nodes[c] = node
	end
	buildat.safe.set_8bit_voxel_geometry(node, w, room.H, room.D,
			table.concat(data), voxel_reg, atlas_reg,
			room.OX + x0, room.OY, room.OZ)
	apply_technique(node)
end
local CHUNKS = math.ceil(room.W / CHUNK)
for c = 0, CHUNKS - 1 do
	mesh_chunk(c)
end
log:info("room: " .. room.W .. "x" .. room.H .. "x" .. room.D ..
		" voxels of 45 cm in " .. CHUNKS .. " chunks")

-- The dissolve rewrites the pocket's own box and re-meshes what it
-- touched; the room is generated and never saved, so the description in
-- room.lua is the only state there is.
local function rewrite_box(x0, x1, y0, y1, z0, z1, open)
	local touched = {}
	for z = z0, z1 do
		for y = y0, y1 do
			local ri = room.row_index(y, z)
			local rw = rows[ri]
			if rw then
				local out = {}
				for x = x0, x1 do
					local i = x - room.OX + 1
					if i >= 1 and i <= room.W then
						out[#out + 1] = {i, string.char(open and room.id.air or
								room.voxel_at(x, y, z))}
					end
				end
				for _, e in ipairs(out) do
					rw = rw:sub(1, e[1] - 1) .. e[2] .. rw:sub(e[1] + 1)
					touched[math.floor((e[1] - 1) / CHUNK)] = true
				end
				rows[ri] = rw
			end
		end
	end
	for c in pairs(touched) do
		mesh_chunk(c)
	end
end

-- Ambient near zero: nothing in this room is lit by "the environment",
-- everything is lit by a source you can point at
local zone_node = scene:CreateChild("Zone")
local zone = zone_node:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(-200, 200)
-- **Nought, and it has to be**: the voxel shader multiplies the zone's
-- ambient by the skylight share, which in a sealed room is nought
-- everywhere, so raising this moves nothing at all. What stands for the
-- bounce is the pair of directional lights below.
zone.ambientColor = magic.Color(0.01, 0.01, 0.015, 1)
zone.fogColor = magic.Color(0, 0, 0, 1)
zone.fogStart = 26 * U
zone.fogEnd = 64 * U

local function part(model, pos, scale, mat)
	local node = scene:CreateChild("part")
	node.position = magic.Vector3(pos.x * U, pos.y * U, pos.z * U)
	node.scale = magic.Vector3(scale.x * U, scale.y * U, scale.z * U)
	local object = node:CreateComponent("StaticModel")
	object.model = magic.cache:GetResource("Model", "Models/" .. model .. ".mdl")
	object.material = mat
	object.castShadows = true
	return node
end

local chrome = material(magic.Color(0.92, 0.94, 0.97, 1), 0.06, 1.0)
local machined = material(magic.Color(0.55, 0.57, 0.62, 1), 0.34, 1.0)
local stone = material(magic.Color(0.26, 0.26, 0.29, 1), 0.85, 0.0)

-- A material wearing a generated height field: the ornament is the
-- texture and not the geometry, which is what lets the room sit on a
-- 45 cm grid and still carry a meander ([LAUNCH_WORLD]'s own reading of
-- the reference frame).
local ORN_SIZE = 128
local function ornamented(h, inlay, opts)
	local diff, norm = ornament.maps(magic, h, inlay, opts)
	local dt, nt = magic.Texture2D:new(), magic.Texture2D:new()
	assert(dt:SetData(diff), "the ornament's albedo")
	assert(nt:SetData(norm), "the ornament's normal")
	kept[#kept + 1] = diff
	kept[#kept + 1] = norm
	kept[#kept + 1] = dt
	kept[#kept + 1] = nt
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/PBR/PBRDiffNormal.xml"))
	m:SetTexture(magic.TU_DIFFUSE, dt)
	m:SetTexture(magic.TU_NORMAL, nt)
	m:SetShaderParameter("MatDiffColor", magic.Color(1, 1, 1, 1))
	m:SetShaderParameter("Roughness", (opts or {}).roughness or 0.75)
	m:SetShaderParameter("Metallic", (opts or {}).metallic or 0.0)
	-- **The frieze has to tile.** A Box's UVs run 0..1 over a face, so
	-- one 128-texel meander stretched across nine metres of frieze is
	-- four metres a unit and reads as a plain band. Urho3D's UOffset and
	-- VOffset are the scale, as a Vector4 whose x and y are the tiling.
	local uv = (opts or {}).uv
	if uv then
		-- A Color, not a Vector4: the sandbox's SetShaderParameter takes
		-- no Vector4, and a Color carries the same four floats into the
		-- same uniform
		m:SetShaderParameter("UOffset", magic.Color(uv[1], 0, 0, 0))
		m:SetShaderParameter("VOffset", magic.Color(0, uv[2], 0, 0))
	end
	kept[#kept + 1] = m
	return m
end

-- An unlit material draws at its own colour whatever the light does,
-- which is what an orb that *is* the light needs; it also lands in the
-- probe, so the chrome has something bright to reflect.
--
-- **The mark is a hole in the glow, not a picture on it** (user): the
-- texture multiplies the orb's own colour, so where the mark is the
-- light is not -- a silhouette inside the light, the way a lantern's
-- cut-out works, rather than a sticker fighting the emission.
local function glow(colour, mark)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			mark and "Techniques/DiffUnlit.xml" or
			"Techniques/NoTextureUnlit.xml"))
	if mark then
		local f = ornament.mark(64, ornament.seed_of(mark))
		local image = magic.Image:new()
		assert(image:SetSize(f.size, f.size, 3), "the mark")
		for y = 0, f.size - 1 do
			for x = 0, f.size - 1 do
				local v = ornament.at(f, x, y)
				image:SetPixel(x, y, magic.Color(v, v, v, 1))
			end
		end
		local t = magic.Texture2D:new()
		assert(t:SetData(image), "the mark's texture")
		t.filterMode = magic.FILTER_BILINEAR
		m:SetTexture(magic.TU_DIFFUSE, t)
		kept[#kept + 1] = image
		kept[#kept + 1] = t
	end
	m:SetShaderParameter("MatDiffColor", colour)
	kept[#kept + 1] = m
	return m
end

-- The ornament generator's own check, which runs whatever wears its
-- output: the patterns are asserted as patterns here and the wall and
-- the columns wear them as voxel tiles, registered at the top of this
-- file.
log:info(ornament.self_check(ORN_SIZE))

-- The floor: a checkerboard in perspective is half the classic raytrace
-- picture, and in the reference frame it carries the reflections of
-- everything standing on it
local floor_mat = material(magic.Color(1, 1, 1, 1), 0.18, 0.0,
		checker_texture(256, 20, magic.Color(0.04, 0.04, 0.05, 1),
		magic.Color(0.62, 0.63, 0.66, 1), magic.FILTER_TRILINEAR))
-- (the floor is the voxelworld's checkerboard now)

-- **The architecture is the room's, and described once.** room.lua holds
-- the wall, its slabs, its insets and the pockets; nothing here keeps a
-- second copy of those numbers to drift from them, which is what the
-- extension move bought -- the game had them in main.cpp and again here,
-- and the check compared the two lists.
--
-- **The composition rule** (user), read off the reference frame and
-- against the evenly-lit set that was rejected: every view has a light
-- source occluded by something -- so the orb sits in its pocket and the
-- stone silhouettes against it.
local BAYS = room.BAYS
local BAY_Z = room.BAY_Z
local function bay_x(i) return room.bay_x(i - 1) end
local function bay_y(i) return room.bay_y(i - 1) end

-- **The orbs are the games** (user): warm is what you own, cold is a
-- server you can reach. The name is what a mark is generated from and
-- what Text3D says over the one being pointed at.
local ORBS = {
	{name = "Vanilla", warm = true},
	{name = "Undermine", warm = true},
	{name = "Digger", warm = true},
	{name = "buildat.example.org", warm = false, ping = 38},
	-- Chekhov's empty shelf: a pocket with nothing in it, which is what
	-- says there is room for another game and is the way to ContentDB
	{name = "install a game", warm = true, empty = true},
	{name = "mine.example.net", warm = false, ping = 210},
}

local orb_places = {}
local bay_desc = {}
for b = 1, BAYS do
	-- **Wholly behind the wall's plane**, which is what makes the
	-- pocket's contrast line free: every point of the wall's outward
	-- face has the orb behind it, so N dot L is negative there and the
	-- face takes nothing from it, while every face inside the pocket
	-- looks at the orb and lights all round.
	-- **An orb finds its own place in its pocket** (user, 2026-09-23):
	-- per axis, it centres itself where the walls are close and
	-- otherwise keeps back from the one it would touch. The margin has a
	-- lighting reason as well as a visual one -- a point light at no
	-- distance from a face burns it white.
	-- **An orb finds its own place** (user, 2026-09-23): per axis it
	-- centres itself where the walls are close and otherwise keeps a
	-- margin off the one it would touch. At 2 to 4 voxels across, every
	-- pocket here is the close case, so the middle is both answers --
	-- and the margin has a lighting reason as well as a visual one, a
	-- point light at no distance from a face burning it white.
	local p = room.pockets[b]
	orb_places[b] = {
		x = (p.x0 + p.sx / 2) * VOXEL_M,
		y = (p.y0 + p.sy / 2) * VOXEL_M,
		z = (p.mouth - p.sz / 2 + 0.5) * VOXEL_M,
	}
	bay_desc[#bay_desc + 1] = string.format("%d %d %d %d%d%d", p.x0, p.y0,
			p.mouth, p.sx, p.sy, p.sz)
end
log:info("bays " .. BAYS .. " " .. BAY_Z .. " " ..
		table.concat(bay_desc, " "))

-- **The ornament, on primitives in front of the voxels.** The bays are
-- voxel mass and the ornament is a generated texture, and the two cannot
-- meet: a voxel's tile is loaded by resource name out of Urho3D's
-- ResourceCache and there is no way to put a generated Image in there.
-- So the friezes are what the plan's own "three representations, each
-- where it is better" asks for -- boxes carrying the meander and the
-- socket field, standing a little proud of the wall the way a course of
-- dressed stone stands proud of rubble.
-- **No friezes.** They were the ornament's home while the wall was a
-- flat plane with a balcony per orb; the wall the reference actually has
-- is one material with the ornament on the pockets' side columns and
-- nowhere else, and those are voxels wearing a generated tile. What used
-- to stand proud of the wall here is the wall's own relief now.
frieze_nodes = {}

-- The orbs. Warm is what you own; the palette's own entry says which
-- colour each carries, and the light at it is what lights the room.
local orb_mats = {}
local orb_nodes = {}
for i, o in ipairs(orb_places) do
	local spec = ORBS[i]
	if spec and spec.empty then
		-- Nothing in the niche but the ring that would hold something,
		-- dim: an empty socket reads as empty, not as broken
		part("Torus", magic.Vector3(o.x, o.y, o.z),
				magic.Vector3(1.4, 1.4, 1.4), machined)
	else
		orb_mats[i] = glow(magic.Color(1, 1, 1, 1), spec and spec.name)
		-- simplified: one size. The plan wants 1.2 to 1.8 voxels by the
		-- game's own size, which list_games() answers -- that arrives
		-- with the real contents, step 5 of the remaining order.
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				magic.Vector3(1.5, 1.5, 1.5), orb_mats[i])
		node:GetComponent("StaticModel").castShadows = false
		orb_nodes[i] = node
	end
end

-- The foreground: ten shipped primitives on the checkerboard, the chrome
-- ones doing what a perfect sphere under a sharp light does
-- **The floor's own things, out of the way of the wall.** A server and a
-- launch action stand on the floor, and the pockets are at Y 0 to 3 --
-- knee to chest -- so anything in the middle of the floor stands in
-- front of the lights the room is lit by. They frame the view instead:
-- wide in x, near the eye in z, and the corridor to the wall left open.
-- The check's own 99th percentile catches this, having read 110 against
-- 253 the moment the eye came down to standing height (2026-09-23).
local PROPS = {
	{"Sphere", -7.4, 1.55, 6.4, 3.1, "chrome"},
	{"Sphere", -3.6, 1.15, 9.4, 2.3, "chrome"},
	{"Sphere", 4.8, 1.55, 7.0, 3.1, "chrome"},
	{"Sphere", 9.2, 1.30, 9.8, 2.6, "chrome"},
	{"Sphere", -11.2, 1.60, 4.0, 3.2, "chrome"},
	{"Cone", -9.0, 1.35, 9.2, 2.7, "machined"},
	{"Cylinder", 11.4, 1.25, 5.0, 2.5, "machined"},
	{"Torus", 1.6, 0.60, 10.2, 2.6, "chrome"},
	{"Pyramid", 13.8, 1.15, 8.4, 2.3, "stone"},
	{"Pyramid", -13.0, 1.10, 10.6, 2.2, "machined"},
}

local MATS = {chrome = chrome, machined = machined, stone = stone}
prop_nodes = {}
for _, o in ipairs(PROPS) do
	prop_nodes[#prop_nodes + 1] = part(o[1],
			magic.Vector3(o[2], o[3], o[4]),
			magic.Vector3(o[5], o[5], o[5]), MATS[o[6]])
end

-- The ten lights are the experiment. Their places are the room's and do
-- not move; a preset says what colour, how bright and how far each is.
-- Roles, from the plan: 1-2 the interior key pair, 3-6 the readouts
-- (every readout is a real light source), 7-8 the structure's own glow,
-- 9 the one amber thing that wants you, 10 the horizon through the
-- opening.
-- **The bounce has to be point lights.** A directional one does almost
-- nothing in here: the voxel shader gates the sun by the skylight
-- nibble, which is what keeps a cave out of the sun, and this room's
-- nibble is nought everywhere. Eight times the brightness moved the
-- wall by three levels. So the fill below is point lights with long
-- ranges and low strength, spread through the room, which is the only
-- lever a sealed voxel room has.
-- The first six lights are the orbs -- each sits inside its own sphere,
-- so what lights the room is the thing you can see lighting it. The last
-- four are fill: two low at the sides and two picking out the
-- foreground, which is what keeps the chrome from being a black ball
-- with one highlight.
-- **The room's light, as the wall's own reading has it**: cold, from a
-- big square opening overhead, and the orbs. Nothing else -- the fill
-- and the per-bay washes that lit the old flat wall are gone, because
-- they re-light the very surface the pocket's contrast line depends on.
--
-- **The whole shadow budget goes to the overhead light**, which is the
-- one doing the dramatic work on the wall's relief: without it the deep
-- insets cannot read black while lit. The orbs are plain point lights
-- with a tight range -- no cube shadow maps and no cones. The pocket's
-- own contrast line is free: the wall's outward face has the orb behind
-- its plane, so N dot L is negative there and it takes nothing, while
-- every face inside the pocket looks at the orb.
local OVERHEAD_Y = 18         -- voxels above the floor, per the plan's 16-20
local LIGHT_PLACES = {}
for i, o in ipairs(orb_places) do
	LIGHT_PLACES[i] = {o.x, o.y, o.z}
end
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, OVERHEAD_Y * VOXEL_M, 2.0}

-- The palette's roles, from the plan: cyan is live and connected, purple
-- is structure and never state, amber is the one thing that wants you,
-- and the warm horizon is the world outside and not yours.
local CYAN = {0.15, 0.85, 1.0}
local PURPLE = {0.55, 0.20, 0.95}
local AMBER = {1.0, 0.62, 0.12}
local WARM = {1.0, 0.72, 0.45}
local COLD_WHITE = {0.72, 0.85, 1.0}

-- {colour, intensity, range}. The six orbs, then the overhead opening.
local function preset_lights(orb, sky, orb_i, sky_i)
	local l = {}
	for i = 1, 6 do
		-- Tight, so an orb's light dies before it reaches the sideways
		-- faces of the neighbouring slabs, which can see into a
		-- neighbour's pocket -- the one leak the normal does not cover,
		-- and a range is cheaper than a shadow map
		-- **Tight, and tighter now the pockets are** (user's fourth
		-- condition): an orb's light has to die before it reaches the
		-- sideways faces of neighbouring slabs, which can see into a
		-- neighbour's pocket -- the one leak the wall's own normal does
		-- not cover, and a range is cheaper than a cube shadow map. At
		-- 11 voxels it lit warm blotches the width of the wall.
		l[i] = {orb, orb_i, 4 * U}
	end
	l[7] = {sky, sky_i, 60 * U}
	return l
end

local PRESETS = {
	{
		-- The reference frame's own scheme: warm orbs in the wall, cold
		-- light from outside it
		name = "cold_in_warm_out",
		lights = preset_lights(WARM, COLD_WHITE, 7.0, 1.6),
	},
	{
		name = "warm_in_cold_out",
		lights = preset_lights(CYAN, AMBER, 7.0, 1.6),
	},
	{
		name = "all_cold",
		lights = preset_lights(COLD_WHITE, CYAN, 7.0, 1.6),
	},
	{
		-- Deliberately wrong, and the useful one
		name = "wrong",
		lights = preset_lights(PURPLE, AMBER, 8.0, 3.0),
	},
}

-- Urho3D's PBR shaders want a light an order of magnitude brighter than
-- the non-PBR ones for the same picture: their falloff is physical and
-- brightness is radiant intensity, not a 0..1 dimmer. A preset's numbers
-- above are relative to each other, and this is the one place the scale
-- lives. Getting this wrong is what made PBR look like it did not work
-- at all -- the room came out black and the render path got the blame.
local PBR_INTENSITY = 25

-- Shadows on, and a map big enough for a wall of relief: they are
-- required rather than optional here ([LAUNCH_WORLD]'s wall)
magic.renderer.drawShadows = true
magic.renderer.shadowMapSize = 2048

local lights = {}
for i, place in ipairs(LIGHT_PLACES) do
	local node = scene:CreateChild("light")
	node.position = V(place[1], place[2], place[3])
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	-- A handful of sharp point lights with hard shadows; only the key pair
	-- casts, because a shadow map each is the one real cost here
	light.castShadows = false
	light.shadowBias = magic.BiasParameters(0.00025, 0.5)
	lights[i] = light
end

local current = 0
local function set_preset(n)
	local preset = PRESETS[n]
	if preset == nil then return end
	current = n
	for i, light in ipairs(lights) do
		local e = preset.lights[i]
		light.color = magic.Color(e[1][1], e[1][2], e[1][3], 1)
		local spec = ORBS[i] or ORBS[i - 10]
		if spec and spec.empty then
			-- An empty niche is a dark one, and the one amber thing in
			-- the room is allowed to be the invitation to fill it
			light.color = magic.Color(1.0, 0.62, 0.12, 1)
		end
		-- An orb is its own light made visible, so it wears the colour it
		-- casts, well above 1 so it reads as a source and not as a pale
		-- ball -- and so the probe carries it to the chrome
		if orb_mats[i] then
			orb_mats[i]:SetShaderParameter("MatDiffColor",
					magic.Color(e[1][1] * 3.4, e[1][2] * 3.4, e[1][3] * 3.4, 1))
		end
		light.brightness = e[2] * PBR_INTENSITY *
				((spec and spec.empty) and 0.22 or 1.0)
		light.range = e[3]
	end
	if label then
		label:SetText(preset.name .. "  (1-" .. #PRESETS .. ")")
	end
	log:info("palette preset " .. n .. ": " .. preset.name)
end

-- The one viewpoint every picture is taken from: standing in the room,
-- the open side behind the camera, the chrome and the plinth in frame
local camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
-- placed from the camera state below, once it exists
-- [LAUNCH_WORLD] step 2: the reflection probe, which is a prerequisite
-- and not an upgrade -- a PBR metal reflects its surroundings and nothing
-- else, so with no environment it is black but for its highlight, and
-- half the reference frame is reflections.
--
-- The room is static: no mapgen, no day, nothing that moves the light. So
-- the environment is rendered once into a cubemap and hung on the zone,
-- and that is the whole feature. Float16, because what a probe carries is
-- radiance and the emissive orbs are well above 1.
--
-- simplified: one probe for the whole room, at a point named by hand, so
-- a reflection is right where the probe is and progressively wrong away
-- from it. The upgrade is a probe per bay with the nearest chosen per
-- object, which Urho3D will not do for us.
local PROBE_SIZE = 256
-- Urho3D's cube faces in its own order (+X, -X, +Y, -Y, +Z, -Z), as the
-- pitch and yaw a camera needs to look down each
local PROBE_FACES = {
	{0, 90}, {0, -90}, {-90, 0}, {90, 0}, {0, 0}, {0, 180},
}
local probe_surfaces = {}
probe_on = true
local function reflection_probe(at)
	local cube = magic.TextureCube:new()
	-- **RGBA8, not float16, and that is not a preference** ([PBR_HDR]):
	-- a float16 cube map on the zone with HDR rendering on costs the
	-- frame its red and green -- a pixel that reads 60 71 89 in LDR
	-- reads 0 0 111 -- and the same cube in eight bits renders the room
	-- correctly in HDR. One keypress separates the two readings, F5
	-- being the probe's own toggle. A float cube is the right thing and
	-- the client-wide fault is filed; until it is fixed, HDR on the
	-- frame is worth more than radiance in the reflections.
	--
	-- simplified: an emissive orb clips to white where it is reflected,
	-- since eight bits cannot carry it. The upgrade is the float cube
	-- back, once [PBR_HDR] is repaired.
	assert(cube:SetSize(PROBE_SIZE, magic.Graphics.GetRGBAFormat(),
			magic.TEXTURE_RENDERTARGET), "the probe's cubemap")
	cube.filterMode = magic.FILTER_BILINEAR
	kept.probe = cube
	for i, a in ipairs(PROBE_FACES) do
		local node = scene:CreateChild("probe_face")
		node.position = at
		node.rotation = magic.Quaternion(a[1], a[2], 0)
		local cam = node:CreateComponent("Camera")
		cam.fov = 90
		cam.aspectRatio = 1
		cam.nearClip = 0.05 * U
		cam.farClip = 120 * U
		local vp = magic.Viewport:new(scene, cam)
		local surface = cube:GetRenderSurface(i - 1)
		surface:SetViewport(0, vp)
		-- Drawn when asked rather than every frame: six more views a frame
		-- for a room that does not change is exactly the kind of cost this
		-- whole thing is a showcase of leaving out
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		probe_surfaces[i] = surface
		kept[#kept + 1] = vp
	end
	zone.zoneTexture = cube
	-- What the zone wears when the probe is taken away: an environment of
	-- nothing, rather than no environment at all. The property will not
	-- take nil, and an unbound cubemap reads bright rather than black.
	local dark = magic.TextureCube:new()
	assert(dark:SetSize(4, magic.Graphics.GetRGBAFloat16Format(), 0),
			"the empty environment")
	local black = magic.Image:new()
	assert(black:SetSize(4, 4, 3), "the empty environment's face")
	black:Clear(magic.Color(0, 0, 0, 1))
	for face = 0, 5 do
		dark:SetData(face, black)
	end
	kept.dark_probe = dark
	kept[#kept + 1] = black
	return cube
end
reflection_probe(V(0, 2.0, 0.0))

-- The first frames, not the first: at boot the materials and the
-- generated textures are not on the GPU yet and a probe taken then is a
-- picture of nothing. Cheap to ask a few times and then stop.
local probe_frames = 0
function handle_probe_update()
	if probe_frames > 90 then
		return
	end
	probe_frames = probe_frames + 1
	for _, s in ipairs(probe_surfaces) do
		s:QueueUpdate()
	end
end
magic.SubscribeToEvent("Update", "handle_probe_update")

local viewport = magic.Viewport:new(scene,
		camera_node:GetComponent("Camera"))
-- **The viewport is registered before the render path is touched**,
-- which is the order games/voxel_lighting uses and the last difference
-- between the two that was left to try.
magic.set_preferred_viewports({viewport})

-- **The tonemap**, which is the last thing between this room and the
-- reference frame: a path trace rolls its highlights off and a frame
-- with none can only clip them (3.58 per cent of this one is pure
-- white against the reference's 0.31).
--
-- **It does not work yet, and the hook is left here because the next
-- attempt should not start from nothing.** BUILDAT_LAUNCH_TONEMAP names
-- which of Urho3D's own post-process effects to append, comma
-- separated. What is known:
--   * all three together draw a black frame, and so does Tonemap alone
--     (mean 1 of 255), so it is not AutoExposure or BloomHDR
--   * Tonemap.xml is not missing its parameters -- it declares
--     TonemapExposureBias itself, so the "unset reads as zero" rule is
--     not the cause
--   * every command in it reads the texture named "viewport" and writes
--     it back, and this game's scene goes through
--     set_preferred_viewports(), which renders it to an offscreen
--     texture of its own. That is the first thing to suspect: the
--     effect is reading a viewport the scene was never drawn into.
-- The room is lit to fit in the range meanwhile, so the orbs clip to
-- white -- which is what a source should do -- and the wall stops short
-- of it.
do
	-- **On by default, and without HDR.** Urho3D's Tonemap works
	-- appended to the client's own render path; what draws a black frame
	-- is `HDRRendering`. So the room is tonemapped in LDR: the
	-- highlights roll off instead of clipping, which took the pure-white
	-- share from 3.58 per cent to nothing.
	--
	-- **What HDR does here, exactly** (BUILDAT_LAUNCH_HDR=1 to see it):
	-- the frame is not black, it is *only the unlit materials* -- the
	-- orbs and the readout draw and everything lit by a point light does
	-- not. Brighten the shot six times and that is what is in it. So the
	-- light passes are not reaching the HDR buffer, and the base pass
	-- is. games/voxel_lighting renders in HDR with the same three
	-- effects appended in the same order, and the difference that is
	-- left is that its scene is lit by a **directional** light and this
	-- one by points. That is where the next look starts, and it is a
	-- client-wide question rather than this room's: nothing else in the
	-- tree lights an HDR scene with point lights.
	local want = buildat.get_env("BUILDAT_LAUNCH_TONEMAP") or "Tonemap"
	-- **HDR is on** (user, 2026-09-23: a float target is non-negotiable
	-- here). A renderer that clips every radiance at 1.0 before the
	-- tonemap measures a clamp rather than light, and a source then
	-- cannot be brighter than a fully-lit wall. BUILDAT_LAUNCH_NOHDR=1
	-- goes back to LDR, which is what the two can be compared with.
	local hdr = (buildat.get_env("BUILDAT_LAUNCH_NOHDR") or "") == ""
	-- BUILDAT_LAUNCH_SUN adds one directional light, to settle whether
	-- it is point lights in particular that the HDR path drops
	if (buildat.get_env("BUILDAT_LAUNCH_SUN") or "") ~= "" then
		local node = scene:CreateChild("sun")
		node.direction = magic.Vector3(-0.4, -0.8, 0.45)
		local sun = node:CreateComponent("Light")
		sun.lightType = magic.LIGHT_DIRECTIONAL
		sun.color = magic.Color(1, 0.95, 0.85, 1)
		sun.brightness = 1.4
		sun.castShadows = false
		kept[#kept + 1] = sun
		log:info("tonemap: a directional light added")
	end
	if want ~= "" or hdr then
		-- HDR on its own, so it can be told apart from the effects
		magic.renderer.HDRRendering = hdr
		log:info("tonemap: HDR " .. tostring(hdr))
		local rp = viewport.renderPath:Clone()
		for fx in want:gmatch("[^,]+") do
			local xml = magic.cache:GetResource("XMLFile",
					"PostProcess/" .. fx .. ".xml")
			if xml then
				local before = rp:GetNumCommands()
				rp:Append(xml)
				log:info("tonemap: " .. fx .. " added " ..
						(rp:GetNumCommands() - before) .. " commands")
			else
				log:warning("tonemap: no PostProcess/" .. fx .. ".xml")
			end
		end
		-- **Uncharted2, not Reinhard.** Tonemap.xml ships three curves
		-- with the Reinhard one enabled; Reinhard lifts the blacks and
		-- caps the highlights, which is the opposite of the reference
		-- frame's deep blacks and bright sources (its median is 38 and
		-- its 99th 252; Reinhard at a bias that reached 80 put the 99th
		-- at 184). The filmic curve keeps the toe low and rolls the
		-- shoulder off.
		rp:SetEnabled("TonemapReinhardEq3", false)
		rp:SetEnabled("TonemapUncharted2", true)
		rp:SetShaderParameter("TonemapExposureBias",
				tonumber(buildat.get_env("BUILDAT_LAUNCH_BIAS") or "") or 1.05)
		rp:SetShaderParameter("TonemapMaxWhite",
				tonumber(buildat.get_env("BUILDAT_LAUNCH_WHITE") or "") or 1.8)
		rp:SetShaderParameter("AutoExposureAdaptRate", 2.0)
		rp:SetShaderParameter("AutoExposureLumRange",
				magic.Vector2(0.06, 2.0))
		rp:SetShaderParameter("AutoExposureMiddleGrey", 0.12)
		viewport.renderPath = rp
		log:info("tonemap: " .. want .. ", " .. rp:GetNumCommands() ..
				" commands, HDR on")
	end
end


-- The name of the preset in the corner, so a picture says which it is
label = magic.ui.root:CreateChild("Text")
label:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
label.horizontalAlignment = magic.HA_LEFT
label.verticalAlignment = magic.VA_BOTTOM
label:SetPosition(8, -8)

-- **The servers are a patch bay** (the brief): a port each, the name
-- above it, the most recently used nearest spawn, **the ping as the
-- blink rate of its link LED** and a dead host unlit. A server list
-- genuinely *is* a set of connections, which is why this mapping is the
-- honest one rather than a list pinned to a wall.
--
-- simplified: the ports are the server orbs' own entries, with a ping
-- written beside them, because nothing in this room talks to a network
-- yet. The upgrade is the launcher's own list and its pings, which is
-- the same table with another source.
local PATCH = {}
for _, o in ipairs(ORBS) do
	if not o.warm then
		PATCH[#PATCH + 1] = o
	end
end
-- One dead host, because "unlit" has to be visible to mean anything
PATCH[#PATCH + 1] = {name = "gone.example.com", warm = false, ping = nil}

local patch_leds = {}
do
	-- Along the room's right-hand side as the camera sees it, which is
	-- +x: the bay faces the middle, so a port is read side-on from spawn
	-- and square-on by whoever walks to it
	local x0, y0, z0 = 8.2, 0.0, 4.2
	local pitch = 2.2
	-- The rack the ports are set into
	part("Box", magic.Vector3(x0, 1.7, z0 - #PATCH * pitch / 2 + pitch / 2),
			magic.Vector3(0.7, 3.6, #PATCH * pitch), machined)
	for i, srv in ipairs(PATCH) do
		local z = z0 - (i - 1) * pitch
		-- The port itself: a recess with a ring round it, which is a
		-- socket in the language of stacked boxes
		part("Box", magic.Vector3(x0 - 0.42, 1.9, z),
				magic.Vector3(0.18, 1.1, 1.1), stone)
		part("Cylinder", magic.Vector3(x0 - 0.52, 1.9, z),
				magic.Vector3(0.62, 0.16, 0.62), chrome)
		-- The link LED, which is the whole readout: lit and blinking for
		-- a live host, dark for one that does not answer
		local led_mat = glow(magic.Color(0, 0, 0, 1))
		part("Box", magic.Vector3(x0 - 0.56, 1.05, z),
				magic.Vector3(0.12, 0.16, 0.34), led_mat)
		patch_leds[i] = {mat = led_mat, ping = srv.ping}
		-- The name above the port, always on here: a patch bay is read by
		-- walking along it, and three labels is not a label wall
		local label = scene:CreateChild("port_name")
		label.position = V(x0 - 0.7, 2.75, z)
		local t = label:CreateComponent("Text3D")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 30)
		t:SetColor(srv.ping and magic.Color(0.55, 0.75, 0.85, 1) or
				magic.Color(0.32, 0.30, 0.30, 1))
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		t.text = srv.name
		t.faceCameraMode = magic.FC_ROTATE_Y
	end
end

-- The blink: a live port's LED is on for a moment once every ping's
-- worth of milliseconds, so a near server flickers quickly and a far one
-- pulses. Nothing here polls anything; the rate is the reading.
patch_t = 0
function handle_patch_update(event_type, event_data)
	patch_t = patch_t + event_data:GetFloat("TimeStep")
	for _, led in ipairs(patch_leds) do
		local on = false
		if led.ping then
			local period = led.ping / 1000
			on = (patch_t % period) < period * 0.35
		end
		led.mat:SetShaderParameter("MatDiffColor", on and
				magic.Color(0.4, 2.6, 3.0, 1) or magic.Color(0.02, 0.06, 0.07, 1))
	end
end
magic.SubscribeToEvent("Update", "handle_patch_update")

-- **The version, as a readout rather than as text on a HUD**
-- ([BOX_PLAYTEST_4]'s complaint answered with geometry): a seven-segment
-- display standing on the floor at spawn, its lit segments unlit-bright
-- and its dark ones just visible, the way a VFD's unlit segments are. It
-- is a real light source, as every readout in this room is.
local SEG_ON = {
	["0"] = "abcdef", ["1"] = "bc", ["2"] = "abdeg", ["3"] = "abcdg",
	["4"] = "bcfg", ["5"] = "acdfg", ["6"] = "acdefg", ["7"] = "abc",
	["8"] = "abcdefg", ["9"] = "abcdfg", ["-"] = "g", ["."] = "p",
	-- The letters a version string can carry, in the shapes a
	-- seven-segment display has for them
	["b"] = "cdefg", ["d"] = "bcdeg", ["a"] = "abcefg", ["e"] = "adefg",
	["f"] = "aefg", ["c"] = "adef", ["r"] = "eg", ["t"] = "defg",
	["v"] = "cde", ["o"] = "cdeg", ["n"] = "ceg", ["i"] = "e",
	["g"] = "acdfg", ["l"] = "def", ["p"] = "abefg", ["u"] = "cde",
}
-- Each segment as {x, y, w, h} in a digit's own box, 1 wide and 2 high
local SEG_BOX = {
	a = {0.5, 1.90, 0.76, 0.16}, g = {0.5, 1.00, 0.76, 0.16},
	d = {0.5, 0.10, 0.76, 0.16}, f = {0.10, 1.47, 0.16, 0.70},
	b = {0.90, 1.47, 0.16, 0.70}, e = {0.10, 0.53, 0.16, 0.70},
	c = {0.90, 0.53, 0.16, 0.70}, p = {1.02, 0.10, 0.16, 0.16},
}

local function readout(text, at, scale, colour)
	local lit = glow(magic.Color(colour.r * 2.5, colour.g * 2.5,
			colour.b * 2.5, 1))
	-- What an unlit segment is: the same shape, barely there, so the
	-- display reads as a device with digits in it rather than as floating
	-- strokes
	local dim = glow(magic.Color(colour.r * 0.10, colour.g * 0.10,
			colour.b * 0.10, 1))
	local x = at.x
	for i = 1, #text do
		local ch = text:sub(i, i)
		local on = SEG_ON[ch] or ""
		if ch ~= "." then
			-- The face the digit is cut out of, which is what makes the
			-- dark segments read
			part("Box", magic.Vector3(x + 0.5 * scale, at.y + scale,
					at.z - 0.06 * scale),
					magic.Vector3(1.24 * scale, 2.24 * scale, 0.10 * scale),
					machined)
		end
		for seg, b in pairs(SEG_BOX) do
			if (seg == "p") == (ch == ".") then
				part("Box", magic.Vector3(x + b[1] * scale,
						at.y + b[2] * scale, at.z),
						magic.Vector3(b[3] * scale, b[4] * scale,
						0.10 * scale),
						on:find(seg, 1, true) and lit or dim)
			end
		end
		-- Leftwards in x, which is rightwards on screen: the camera looks
		-- down -Z and Urho3D is left-handed, so a string advancing +x
		-- reads back to front
		x = x - (ch == "." and 0.40 or 1.30) * scale
	end
	-- A readout that lights what is around it, which is the whole reason
	-- they are objects here and not a HUD
	local node = scene:CreateChild("readout_light")
	node.position = V(at.x - #text * 0.6 * scale, at.y + scale, at.z + 0.6)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.color = colour
	light.brightness = 0.9 * PBR_INTENSITY
	light.range = 5 * U
	light.castShadows = false
end

-- Standing at spawn, low and to the left, turned a little out of the wall
readout("b" .. buildat.version(), {x = 9.0, y = 0.25, z = -1.0}, 0.34,
		magic.Color(0.15, 0.85, 1.0, 1))

-- **The orb turns to face whoever approaches** (user), and the name is
-- over the one being pointed at only -- not always on, which is what
-- keeps the room from being a label wall.
--
-- simplified: the turn snaps rather than slerping, which is invisible
-- while the camera is fixed and wants a slerp the moment it moves; and
-- "pointed at" is the smallest angle to the view direction, which is
-- the crosshair's own ray as long as the crosshair is the screen's
-- middle.
-- **The camera is a state, not a constant**, because the fast path flies
-- it: where it is and what it looks at are numbers that get lerped, and
-- the pointing below reads them rather than the two it was set up with.
-- Copies, not the node's own vectors -- a position property hands back a
-- reference that follows the node.
-- **A standing eye, and the room is judged from nowhere else** (user,
-- 2026-09-23: the options renders read as too small a voxel against the
-- eye). The grid was not the fault -- 45 cm as asked -- the viewpoint
-- was: this stood at 2.75 m and 21 m back, so every voxel read 1.7
-- times too small. 1.6 m it is, and close enough to reach the pockets,
-- whose floors are at Y 0 to 3.
local HOME_FROM = {x = 0.0, y = 1.6, z = 14.0}
local HOME_AT = {x = 0, y = 1.1, z = -6.0}
local cam = {
	from = {x = HOME_FROM.x, y = HOME_FROM.y, z = HOME_FROM.z},
	at = {x = HOME_AT.x, y = HOME_AT.y, z = HOME_AT.z},
	to_from = nil, to_at = nil, t = 0,
}
local view_from = V(cam.from.x, cam.from.y, cam.from.z)
local view_dir = magic.Vector3(0, 0, -1)

local function apply_camera()
	camera_node.position = V(cam.from.x, cam.from.y, cam.from.z)
	camera_node:LookAt(V(cam.at.x, cam.at.y, cam.at.z))
	view_from = V(cam.from.x, cam.from.y, cam.from.z)
	local dx, dy, dz = cam.at.x - cam.from.x, cam.at.y - cam.from.y,
			cam.at.z - cam.from.z
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	view_dir = magic.Vector3(dx / l, dy / l, dz / l)
end

-- **The camera flies to what was picked**, which is how the fast path
-- teaches the room: someone who typed a name sees where that name lives
-- on the way in.
local FLY_SECONDS = 1.3
local function fly_to(from, at)
	cam.to_from, cam.to_at, cam.t = from, at, 0
	cam.was_from = {x = cam.from.x, y = cam.from.y, z = cam.from.z}
	cam.was_at = {x = cam.at.x, y = cam.at.y, z = cam.at.z}
end

function handle_camera_update(event_type, event_data)
	if not cam.to_from then
		return
	end
	cam.t = math.min(1, cam.t + event_data:GetFloat("TimeStep") / FLY_SECONDS)
	local e = cam.t * cam.t * (3 - 2 * cam.t)
	for _, k in ipairs({"x", "y", "z"}) do
		cam.from[k] = cam.was_from[k] + (cam.to_from[k] - cam.was_from[k]) * e
		cam.at[k] = cam.was_at[k] + (cam.to_at[k] - cam.was_at[k]) * e
	end
	apply_camera()
	if cam.t >= 1 then
		cam.to_from, cam.to_at = nil, nil
	end
end
magic.SubscribeToEvent("Update", "handle_camera_update")
apply_camera()

local name_node = scene:CreateChild("orb_name")
local name_text = name_node:CreateComponent("Text3D")
-- **Typography as graphic design**, which is what that era did with a
-- name: huge letterforms and wide tracking, not a centred column of
-- small labels. There is no tracking setting on a Text3D, so the
-- spacing is spaces -- which is how it was done then too.
name_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 64)
name_text:SetColor(magic.Color(1, 1, 1, 1))
name_text:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
name_text.text = ""
-- The ceiling is the font ([TRANSLATION_FONT]): Latin-1 and Cyrillic, so
-- a CJK name does not draw and whoever widens the font settles this too
name_text.faceCameraMode = magic.FC_ROTATE_Y

pointed_orb = 0
function handle_orb_update()
	local best, best_dot = 0, -1
	-- Not ipairs: an empty niche leaves a hole in the list and ipairs
	-- stops at it, which would hide every orb past the empty one
	for i = 1, #orb_places do
		local node = orb_nodes[i]
		if node then
			local p = node.position
			local dx, dy, dz = p.x - view_from.x, p.y - view_from.y,
					p.z - view_from.z
			local l = math.sqrt(dx * dx + dy * dy + dz * dz)
			local dot = (dx * view_dir.x + dy * view_dir.y +
					dz * view_dir.z) / l
			if dot > best_dot then
				best, best_dot = i, dot
			end
			-- Present the face: the mark sits in the middle of the
			-- sphere's UVs, which Sphere.mdl puts on -Z, so the orb looks
			-- away from the viewer to show it to them
			node:LookAt(magic.Vector3(view_from.x * 2 - p.x,
					view_from.y * 2 - p.y, view_from.z * 2 - p.z))
		end
	end
	if best ~= pointed_orb then
		pointed_orb = best
		local o = ORBS[best]
		name_text.text = o and o.name:upper():gsub("(.)", "%1 "):gsub(" $", "")
				or ""
		log:info("pointing at orb " .. best .. ": " ..
				(o and o.name or "?"))
	end
	if best > 0 then
		local p = orb_nodes[best].position
		-- In front of the wall, not above the orb: the orb sits in a
		-- niche and anything above it is inside the stone
		name_node.position = magic.Vector3(p.x, p.y + 2.6 * U,
				(BAY_Z + 2.5) * VOXEL_M * U)
	end
end
magic.SubscribeToEvent("Update", "handle_orb_update")

-- The room's bed. One source on one stream, topped up every frame; the
-- number of orbs alight is the number of drone voices, so what the room
-- hums is the list of games ([LAUNCH_WORLD]'s own reason for generating
-- the audio rather than looping a file).
log:info(synth.self_check(magic))
local bed = synth.new(magic, log)
bed:set_voices(#orb_nodes)
bed:play(scene:CreateChild("sound"))
kept.bed = bed
function handle_synth_update()
	bed:update()
end
magic.SubscribeToEvent("Update", "handle_synth_update")

-- **The dissolve**: a bay un-builds into flying slabs, and it is the
-- only transition there is. The voxels stop being there -- the server is
-- told, and puts them back from the room's own description when the bay
-- shuts -- and what flies is a cube per voxel that was on the bay's
-- face, made here and thrown away when it lands.
--
-- States are configurations of one scene, not screens with a camera
-- parked in each, so a bay is a number in 0..1 and every cube's place is
-- read off it: reversible, interruptible, no keyframes. Where a cube
-- goes is decided once from its own index, since a wall that scatters
-- differently each time reads as noise rather than as a mechanism.
--
-- simplified: only the bay's front plane flies, which is 378 cubes at
-- the widest instead of fifteen hundred, and is the face anyone is
-- looking at. The upgrade is the whole depth, and a budget.
local DISSOLVE_SECONDS = 0.9
local bay_state = {}
for b = 1, BAYS do
	bay_state[b] = {t = 0, target = 0, slabs = {}}
end

-- The pocket's own box, which is what comes apart: the mouth stands
-- wherever the slabs around it put it, so the sweep goes from the deepest
-- a face can be to the furthest it can stand.
local function dissolve_voxels(b, open)
	local bx, by = bay_x(b), bay_y(b)
	local p = room.pockets[b]
	rewrite_box(p.x0 - 2, p.x0 + p.sx + 1, p.y0 - 2, p.y0 + p.sy + 1,
			p.mouth - p.sz - 2, p.mouth + 2, open)
end

local function build_flying(b)
	local st = bay_state[b]
	if #st.slabs > 0 then
		return
	end
	local p = room.pockets[b]
	local i = 0
	-- The pocket's own mouth and the wall around it, which is what comes
	-- apart; the face stands wherever the slabs put it, so a column of
	-- voxels is walked until one is found
	for x = p.x0 - 2, p.x0 + p.sx + 1 do
		for y = p.y0 - 2, p.y0 + p.sy + 1 do
			local v, vz = nil, nil
			for z = p.mouth + 2, p.mouth - p.sz - 2, -1 do
				local id = room.voxel_at(x, y, z)
				if id ~= room.id.air then
					v, vz = id, z
					break
				end
			end
			if v then
				i = i + 1
				local node = part("Box",
						magic.Vector3(x * VOXEL_M, (y + 0.5) * VOXEL_M,
						vz * VOXEL_M),
						magic.Vector3(VOXEL_M, VOXEL_M, VOXEL_M), stone)
				local pos = node.position
				local dir = ((i % 2 == 0) and 1 or -1)
				st.slabs[i] = {
					node = node,
					-- The numbers, not the Vector3: a position property
					-- hands back the node's own vector, so a home kept as
					-- that object follows the cube as it flies
					home = {x = pos.x, y = pos.y, z = pos.z},
					away = {x = pos.x + dir * (2.0 + (i % 7) * 0.5) * U,
							y = pos.y + (1.0 + (i % 5) * 0.4) * U,
							z = pos.z + (1.8 + (i % 3) * 0.7) * U},
					spin = {i * 11 % 40 - 20, i * 27 % 60 - 30,
							i * 17 % 50 - 25},
				}
			end
		end
	end
	log:info("dissolve: bay " .. b .. " has " .. i .. " cubes to fly")
end

local function drop_flying(b)
	local st = bay_state[b]
	for _, sl in ipairs(st.slabs) do
		sl.node:Remove()
	end
	st.slabs = {}
end

local function ease(t)
	-- Slow at both ends, which is what makes a heavy slab read as heavy
	return t * t * (3 - 2 * t)
end

function dissolve_bay(b, open)
	local st = bay_state[b]
	if not st or (st.target == (open and 1 or 0)) then
		return
	end
	if open then
		-- The cubes are made from the voxels that are there, and only
		-- then are the voxels taken away
		build_flying(b)
		dissolve_voxels(b, true)
	end
	st.target = open and 1 or 0
end

function handle_dissolve_update(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	for b = 1, BAYS do
		local st = bay_state[b]
		if st.t ~= st.target then
			local step = dt / DISSOLVE_SECONDS
			if st.target > st.t then
				st.t = math.min(st.target, st.t + step)
			else
				st.t = math.max(st.target, st.t - step)
			end
			local e = ease(st.t)
			for _, sl in ipairs(st.slabs) do
				sl.node.position = magic.Vector3(
						sl.home.x + (sl.away.x - sl.home.x) * e,
						sl.home.y + (sl.away.y - sl.home.y) * e,
						sl.home.z + (sl.away.z - sl.home.z) * e)
				sl.node.rotation = magic.Quaternion(sl.spin[1] * e,
						sl.spin[2] * e, sl.spin[3] * e)
			end
			if st.t == 0 and st.target == 0 then
				-- Landed: the voxels come back and the cubes go
				dissolve_voxels(b, false)
				drop_flying(b)
				log:info("dissolve: bay " .. b .. " rebuilt")
			end
		end
	end
end
magic.SubscribeToEvent("Update", "handle_dissolve_update")

-- **Nothing is ever static.** The era this room refers to treated a
-- still frame as a bug: idle rotation, breathing, drift. So the orbs
-- breathe on their own clocks and the loose chrome turns, slowly enough
-- that it reads as the room being alive rather than as animation.
--
-- **F7 freezes it**, which is what the checks use: every comparison
-- here is between two frames and a room that drifts has no two frames
-- alike. The freeze is the exception that proves the rule, and the
-- runner asserts the drift is there before turning it off.
still = false
idle_t = 0
local idle_bob = {}
for i, o in ipairs(orb_places) do
	idle_bob[i] = {node = orb_nodes[i], y = o.y, phase = i * 1.7}
end

-- **The attract mode**: left alone, the room shows itself off. The
-- camera leaves its standing place and drifts along the bays, and the
-- first key press brings it back -- which is the era's own habit and
-- costs a sine.
--
-- simplified: one path, a slow sweep across the room and back, rather
-- than a tour of the objects. A tour wants the objects to say where
-- they are, which they will when there is a launcher behind them.
-- Long enough that it never fires while the room is being used, and
-- **F8 starts it at once**, which is how a run gets at it without
-- waiting: a short timer for the check's sake would fire between the
-- check's own keys and eat the next one, which is exactly what it did.
local ATTRACT_AFTER = tonumber(
		buildat.get_env("BUILDAT_LAUNCH_ATTRACT") or "") or 14
idle_quiet = 0
attracting = false

function handle_idle_update(event_type, event_data)
	if still then
		return
	end
	local dt = event_data:GetFloat("TimeStep")
	idle_quiet = idle_quiet + dt
	if not attracting and not terminal_open and not cam.to_from and
			idle_quiet > ATTRACT_AFTER then
		attracting = true
		log:info("attract: the room is showing itself off")
	end
	if attracting then
		local a = idle_quiet - ATTRACT_AFTER
		-- A sweep along the bays and back, low and slow, looking at the
		-- wall the orbs are in
		local sway = math.sin(a * 0.22)
		cam.from.x = HOME_FROM.x + sway * 9.0
		cam.from.y = HOME_FROM.y + math.sin(a * 0.15) * 0.8
		cam.from.z = HOME_FROM.z - 3.0 + math.cos(a * 0.22) * 2.0
		cam.at.x = HOME_AT.x + sway * 4.0
		cam.at.y = HOME_AT.y + 0.6
		cam.at.z = HOME_AT.z
		apply_camera()
	end
	idle_t = idle_t + dt
	for _, b in ipairs(idle_bob) do
		if b.node then
			local p = b.node.position
			b.node.position = magic.Vector3(p.x,
					(b.y + math.sin(idle_t * 0.7 + b.phase) * 0.09) * U, p.z)
		end
	end
	-- The loose chrome turns, each at its own rate: a sphere turning is
	-- only visible in what it reflects, which is exactly the point of
	-- putting a checkerboard under it
	for i, n in ipairs(prop_nodes) do
		n.rotation = magic.Quaternion(0, idle_t * (4 + i * 1.3) % 360, 0)
	end
end
magic.SubscribeToEvent("Update", "handle_idle_update")

-- **The loading reel**: it turns because the frame genuinely turns, and
-- it turns while a bay is coming apart -- which in this room is what
-- loading is. Honest only now that the connect is off the main thread
-- ([BOX_PLAYTEST_2] (12)): a reel that freezes when the client stalls is
-- a reel that lies.
local reel_nodes = {}
do
	local x, y, z = 7.0, 2.35, 5.6
	part("Box", magic.Vector3(x, y - 1.2, z),
			magic.Vector3(2.6, 0.3, 1.4), machined)
	for i, dx in ipairs({-0.72, 0.72}) do
		local hub = part("Cylinder", magic.Vector3(x + dx, y, z),
				magic.Vector3(1.0, 0.22, 1.0), chrome)
		-- Lying on its side, so it reads as a reel and not as a drum
		hub.rotation = magic.Quaternion(90, 0, 0)
		-- A spoke across the hub, so that a turning reel is visibly
		-- turning. It is its own node turned in place rather than a
		-- child of the hub: Node's parent is not on the whitelist, and a
		-- spoke centred on the hub needs nothing more than its own
		-- rotation anyway.
		local spoke = part("Box", magic.Vector3(x + dx, y, z),
				magic.Vector3(1.5, 0.1, 0.16), machined)
		reel_nodes[i] = {hub = hub, spoke = spoke}
	end
end

reel_angle = 0
function handle_reel_update(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	local busy = false
	for b = 1, BAYS do
		if bay_state[b] and bay_state[b].t ~= bay_state[b].target then
			busy = true
		end
	end
	if not busy then
		-- **It parks.** Otherwise the spokes stop wherever they were and
		-- the room's state is no longer a function of the bays alone --
		-- a bay shut again would come back to a different picture, which
		-- is the one thing the dissolve's own check is about.
		if reel_angle ~= 0 then
			reel_angle = 0
			for _, r in ipairs(reel_nodes) do
				r.spoke.rotation = magic.Quaternion(0, 0, 0)
			end
		end
		return
	end
	reel_angle = (reel_angle + dt * 220) % 360
	for i, r in ipairs(reel_nodes) do
		r.spoke.rotation = magic.Quaternion(0,
				reel_angle * (i == 1 and 1 or -1), 0)
	end
end
magic.SubscribeToEvent("Update", "handle_reel_update")


set_preset(1)

-- **The keyboard path, untouched**: typing anywhere opens a one-line
-- prompt that fuzzy-matches a game or a server, Enter launches it, and
-- the camera flies to the matching object on the way out so the fast
-- path teaches the room. Digits pick slots. A returning user never
-- walks anywhere.
--
-- simplified: the prompt is a Text element and the keys are read
-- straight off KeyDown rather than through a LineEdit -- no style to
-- load, no focus to take and give back, and a room whose whole point is
-- how much it leaves out can spell twenty-six letters itself. The
-- upgrade is a LineEdit the moment anything needs a caret or paste.
local prompt_text = magic.ui.root:CreateChild("Text")
prompt_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 26)
prompt_text.horizontalAlignment = magic.HA_CENTER
prompt_text.verticalAlignment = magic.VA_BOTTOM
prompt_text:SetPosition(0, -40)
prompt_text:SetColor(magic.Color(0.55, 0.95, 1.0, 1))
prompt_text.text = ""
prompt_open = false
prompt_str = ""
ornament_on = true

-- A subsequence match, which is what "fuzzy" has to mean when the list
-- is six names: every letter typed appears in order. The best match is
-- the one whose letters sit closest to the front.
local function fuzzy(query, name)
	local q, n = query:lower(), name:lower()
	local at, score = 1, 0
	for i = 1, #q do
		local found = n:find(q:sub(i, i), at, true)
		if not found then
			return nil
		end
		score = score + found
		at = found + 1
	end
	return score
end

-- What the prompt can find: the orbs, and the terminal, which is the
-- one thing in the room that is not one
local function best_match(query)
	local best, best_score = nil, nil
	local term = fuzzy(query, "settings terminal contentdb")
	if term then
		best, best_score = "terminal", term
	end
	for i, o in ipairs(ORBS) do
		local sc = fuzzy(query, o.name)
		if sc and (best_score == nil or sc < best_score) then
			best, best_score = i, sc
		end
	end
	return best
end

local function match_name(b)
	return b == "terminal" and "settings / ContentDB" or
			(b and ORBS[b] and ORBS[b].name)
end

-- **The terminal**: settings and the ContentDB listing are a thing you
-- walk to and sit at, and what is drawn on it is an ordinary
-- information-dense widget at full readable density. The rule that
-- keeps the whole room from being a circus (the brief): **physical to
-- find, flat to read, never a 3D prop pretending to be a scrollbar.**
--
-- So the console is geometry -- a plinth, an angled screen, a keyboard
-- ledge -- and the moment the camera is square-on to it the panel that
-- appears is flat UI with rows of text in it.
local TERMINAL = {x = -7.4, y = 0.0, z = 6.2}
do
	local t = TERMINAL
	part("Box", magic.Vector3(t.x, t.y + 0.45, t.z),
			magic.Vector3(3.0, 0.9, 1.7), stone)
	part("Box", magic.Vector3(t.x, t.y + 0.95, t.z + 0.55),
			magic.Vector3(2.6, 0.12, 0.7), machined)
	-- The screen: dark glass in a housing, which is what it is when
	-- nobody is sitting at it
	part("Box", magic.Vector3(t.x, t.y + 1.75, t.z - 0.42),
			magic.Vector3(2.8, 1.7, 0.22), machined)
	part("Box", magic.Vector3(t.x, t.y + 1.75, t.z - 0.30),
			magic.Vector3(2.5, 1.45, 0.06),
			glow(magic.Color(0.03, 0.10, 0.13, 1)))
end

-- The flat half. Hidden until the camera is at the desk; nothing here
-- pretends to be an object.
local panel = magic.ui.root:CreateChild("BorderImage")
panel.visible = false
panel.priority = 50
panel.horizontalAlignment = magic.HA_CENTER
panel.verticalAlignment = magic.VA_CENTER
panel.color = magic.Color(0.02, 0.05, 0.07, 0.94)
-- A flat white texel to tint: an image element with no texture draws
-- nothing at all
panel.texture = checker_texture(2, 1, magic.Color(1, 1, 1, 1),
		magic.Color(1, 1, 1, 1))
panel.imageRect = magic.IntRect(0, 0, 2, 2)
-- **After the texture**: an image element takes its texture's size when
-- one is set, so a size asked for first is thrown away and the panel
-- comes out two pixels across
panel.size = magic.IntVector2(760, 420)

local function panel_row(y, left, right, colour)
	local t = panel:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 17)
	t:SetPosition(26, y)
	t:SetColor(colour or magic.Color(0.62, 0.86, 0.95, 1))
	t.text = string.format("%-26s %s", left, right)
	return t
end

local panel_rows = {}
local function draw_panel()
	for _, t in ipairs(panel_rows) do
		t:Remove()
	end
	panel_rows = {}
	local y = 18
	local function row(l, r, c)
		panel_rows[#panel_rows + 1] = panel_row(y, l, r, c)
		y = y + 24
	end
	row("SETTINGS", "", magic.Color(1, 1, 1, 1))
	row("palette", PRESETS[current].name .. "  (F1-F4)")
	row("reflection probe", probe_on and "on  (P)" or "off  (P)")
	row("voxel", string.format("%.2f m, %d bays", VOXEL_M, BAYS))
	row("ornament", "generated at boot, no files")
	row("sound", "synthesised, " .. #orb_nodes .. " drone voices")
	y = y + 14
	row("CONTENTDB", "", magic.Color(1, 1, 1, 1))
	for i, o in ipairs(ORBS) do
		if o.empty then
			row("(empty slot " .. i .. ")", "pick a game to install",
					magic.Color(1.0, 0.72, 0.30, 1))
		else
			row(o.name, o.warm and "installed" or
					("server" .. (o.ping and (", " .. o.ping .. " ms") or
					", no answer")))
		end
	end
	y = y + 14
	row("", "Escape leaves the desk", magic.Color(0.45, 0.6, 0.66, 1))
end

terminal_open = false
local function sit_at_terminal()
	terminal_open = true
	draw_panel()
	panel.visible = true
	-- Square-on and close, which is what "the camera snaps flat onto it"
	-- has to mean for a screen to be readable
	fly_to({x = TERMINAL.x, y = TERMINAL.y + 1.75, z = TERMINAL.z + 2.6},
			{x = TERMINAL.x, y = TERMINAL.y + 1.75, z = TERMINAL.z - 0.3})
	log:info("terminal: sat down")
end

local function leave_terminal()
	if not terminal_open then
		return false
	end
	terminal_open = false
	panel.visible = false
	log:info("terminal: stood up")
	return true
end

local function show_prompt()
	if prompt_str == "" then
		prompt_text.text = prompt_open and "type a name" or ""
		return
	end
	local b = best_match(prompt_str)
	prompt_text.text = "> " .. prompt_str ..
			(b and ("   -- " .. match_name(b)) or "   -- no match")
end

-- Launching, in this room, is the bay coming apart and the camera going
-- in: there is nothing behind it to run yet, and the transition is the
-- content.
local function launch(b)
	if kept.bed then
		kept.bed:thunk()
	end
	if b == "terminal" then
		sit_at_terminal()
		return
	end
	if not b or not orb_places[b] then
		return
	end
	local o = orb_places[b]
	fly_to({x = o.x, y = o.y + 0.8, z = o.z + 7.0},
			{x = o.x, y = o.y, z = o.z})
	dissolve_bay(b, true)
	log:info("launch: " .. (ORBS[b] and ORBS[b].name or "?") ..
			" (bay " .. b .. ")")
end

function prompt_key(key)
	-- Digits pick the nearest slots, which is the path a returning user
	-- actually takes
	for n = 1, BAYS do
		if key == magic["KEY_" .. n] then
			prompt_open = false
			prompt_str = ""
			show_prompt()
			launch(n)
			return true
		end
	end
	if key == magic.KEY_ESCAPE then
		prompt_open = false
		prompt_str = ""
		show_prompt()
		if leave_terminal() then
			fly_to(HOME_FROM, HOME_AT)
			return true
		end
		-- Escape from the room's own view is the way back out of a launch
		fly_to(HOME_FROM, HOME_AT)
		for b = 1, BAYS do
			dissolve_bay(b, false)
		end
		return true
	end
	if key == magic.KEY_RETURN then
		if prompt_open then
			local b = best_match(prompt_str)
			prompt_open = false
			prompt_str = ""
			show_prompt()
			launch(b)
			return true
		end
		return false
	end
	if key == magic.KEY_BACKSPACE and prompt_open then
		prompt_str = prompt_str:sub(1, #prompt_str - 1)
		show_prompt()
		return true
	end
	-- Any letter opens the prompt and is its first character
	for i = 0, 25 do
		local ch = string.char(97 + i)
		if key == magic["KEY_" .. ch:upper()] then
			prompt_open = true
			prompt_str = prompt_str .. ch
			show_prompt()
			return true
		end
	end
	if key == magic.KEY_SPACE and prompt_open then
		prompt_str = prompt_str .. " "
		show_prompt()
		return true
	end
	return false
end

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	-- F8 starts the attract mode; any other key ends it and brings the
	-- camera home, the room being in use again
	if key == magic.KEY_F8 then
		attracting = true
		idle_quiet = ATTRACT_AFTER
		log:info("attract: the room is showing itself off")
		return
	end
	idle_quiet = 0
	if attracting then
		attracting = false
		fly_to(HOME_FROM, HOME_AT)
		log:info("attract: back to the standing place")
		return
	end
	-- The prompt eats what it wants first, so a name with a "p" in it
	-- does not toggle the probe halfway through being typed
	if prompt_key(key) then
		return
	end
	if key == magic.KEY_ESCAPE then
		-- simplified: the room's only way out is out of the program. The
		-- pause dialog with "switch to launch_menu" is step 7 of the
		-- launcher plan's remaining order.
		__buildat_disconnect()
	end
	-- The palette presets are on F1 to F4: the digits are the room's
	-- own, for picking a slot without walking to it
	for n = 1, #PRESETS do
		if key == magic["KEY_F" .. n] then
			set_preset(n)
		end
	end
	-- **F5** takes the probe off the zone and puts it back, which is how
	-- a run shoots the same frame with and without it. A letter would be
	-- eaten by the prompt -- and was: for a day the probe's own check
	-- was passing on the prompt text "> p" appearing at the bottom of
	-- the frame rather than on anything the probe did.: a metal with nothing to
	-- reflect is black but for its highlight, and that difference is the
	-- whole of what the probe is for
	-- Return opens the bay of the orb being pointed at, which is the
	-- only transition the room has; Backspace closes it again
	if key == magic.KEY_RETURN and pointed_orb > 0 then
		dissolve_bay(pointed_orb, true)
		log:info("dissolve: bay " .. pointed_orb .. " opening")
	elseif key == magic.KEY_BACKSPACE and pointed_orb > 0 then
		dissolve_bay(pointed_orb, false)
		log:info("dissolve: bay " .. pointed_orb .. " closing")
	end
	-- **F6 strips the ornament**, and not a letter: the prompt eats
	-- every letter before the room sees it, which is what it is for. The generator has its own check and it
	-- passed for a whole day while nothing in the room wore what it
	-- made: the bays carried the meander until they became voxels, and
	-- then the materials sat in the file drawing nothing. So a run
	-- shoots the frame with the friezes plain and asserts it changed.
	if key == magic.KEY_RETURN or key == magic.KEY_ESCAPE then
		if kept.bed then
			kept.bed:thunk()
		end
	end
	if key == magic.KEY_F7 then
		still = not still
		log:info("idle drift " .. (still and "frozen" or "running"))
	end
	if key == magic.KEY_F6 then
		ornament_on = not ornament_on
		for _, f in ipairs(frieze_nodes) do
			f[1].enabled = ornament_on
			f[2].enabled = not ornament_on
		end
		log:info("ornament " .. (ornament_on and "on" or "off"))
	end
	if key == magic.KEY_F5 then
		probe_on = not probe_on
		zone.zoneTexture = probe_on and kept.probe or kept.dark_probe
		log:info("reflection probe " .. (probe_on and "on" or "off"))
		return
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

magic.ui:SetFocusElement(nil)

-- vim: set noet ts=4 sw=4:
