-- games/launch_world: [LAUNCH_WORLD]'s palette experiment.
--
-- Not the room -- a bare stand-in for it, built only so the four lighting
-- presets can be argued about with pictures instead of words. The
-- materials get tuned to the light, so the light is settled first; see
-- "Experiment before the materials are tuned" in doc/plan/launcher_plan.md.
--
-- Keys 1 to 4 cycle the presets. games/launch_world/check.sh shoots one
-- picture of each from the one viewpoint and puts them in
-- local/options_for_LAUNCH_WORLD/.
--
-- simplified: primitives and one procedural checker only -- no voxels, no
-- composed objects, no procedural material library, no readouts. Those are
-- steps 3 to 5 of the work in the launcher plan and none of them changes
-- what a preset does to the eye.
local log = buildat.Logger("launch_world")
local magic = require("buildat/extension/urho3d")
-- **The room's shell is a voxelworld at 45 cm** (user's call): the floor
-- the checkerboard is made of and the mass the room is cut out of come
-- from the server's own table, not from primitives. What hands it over is
-- more than a mesh -- the AO, the light nibbles and voxel removal for the
-- dissolve are voxelworld's, and none of them would be worth writing
-- again here.
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
voxelworld.allow_streaming()
-- **The skylight flood is on, even though this room has no sky.** With
-- it off the light nibbles are never written and the shader reads
-- whatever they were: at 45 cm a face is two or three pixels across a
-- room away, so per-voxel rubbish looks exactly like per-pixel noise,
-- and the wall came out as static (2026-09-23). On, the flood writes
-- nought everywhere the sky cannot reach -- which is everywhere in
-- here -- and the wall is a wall.
voxelworld.use_skylight = true
-- The voxels are drawn by builtin/voxel_shading's technique set, which is
-- what voxelworld's client half asks for; without it the room's shell is
-- there and black
local voxel_shading = require("buildat/module/voxel_shading")
-- The ornament generator and the maps it feeds; see ornament.lua
local ok_orn, err_orn, ornament = buildat.run_script_file("main/ornament.lua")
if not ok_orn or type(ornament) ~= "table" then
	error("ornament.lua: " .. tostring(err_orn))
end
-- The room's sound, synthesised; see synth.lua
local ok_syn, err_syn, synth = buildat.run_script_file("main/synth.lua")
if not ok_syn or type(synth) ~= "table" then
	error("synth.lua: " .. tostring(err_syn))
end

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
	local t = magic.cache:GetResource("Technique",
			texture and "Techniques/PBR/PBRDiff.xml" or
			"Techniques/PBR/PBRNoTexture.xml")
	assert(t ~= nil, "the technique loaded")
	m:SetTechnique(0, t)
	if texture then m:SetTexture(magic.TU_DIFFUSE, texture) end
	m:SetShaderParameter("MatDiffColor", colour)
	m:SetShaderParameter("Roughness", roughness)
	m:SetShaderParameter("Metallic", metallic)
	kept[#kept + 1] = m
	return m
end

-- **The server's scene, not one of our own**: the voxelworld's sections
-- are nodes in the replicated scene, so anything that wants to be in the
-- same room as them has to be in it too. A scene made here would draw
-- the primitives and leave the room's shell in a scene nobody looks at,
-- which is exactly what it did (2026-09-23).
scene = replicate.main_scene

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

-- **Three generated materials**, which with the plain stone is what the
-- reference frame is made of: a meander for the frieze courses, a socket
-- field for the perforated blocks, and a sigil for the one slab that
-- stands for a server's own mark. Built once at boot -- a SetPixel a
-- texel is fine there and hopeless per frame, which is what keeps this
-- honest by construction.
log:info(ornament.self_check(ORN_SIZE))
local meander_h, meander_i = ornament.meander(ORN_SIZE, {units = 3, depth = 2})
local meander_mat = ornamented(meander_h, meander_i,
		{base = magic.Color(0.52, 0.54, 0.58, 1),
		inlay = magic.Color(0.20, 0.21, 0.26, 1), roughness = 0.70,
		relief = 0.85, strength = 5, uv = {7, 1}})
local socket_h, socket_i = ornament.sockets(ORN_SIZE,
		{cells = 3, depth = 2, seed = 7})
local socket_mat = ornamented(socket_h, socket_i,
		{base = magic.Color(0.40, 0.42, 0.46, 1),
		inlay = magic.Color(0.04, 0.04, 0.05, 1), roughness = 0.85,
		relief = 0.85, strength = 5, uv = {1, 2}})
local sigil_h, sigil_i = ornament.sigil(ORN_SIZE,
		ornament.seed_of("buildat.example.org:30000"), 4)
local sigil_mat = ornamented(sigil_h, sigil_i,
		{base = magic.Color(0.42, 0.44, 0.50, 1),
		inlay = magic.Color(0.08, 0.30, 0.38, 1), roughness = 0.55,
		metallic = 0.6, relief = 0.85, strength = 5, uv = {1, 2}})

-- The floor: a checkerboard in perspective is half the classic raytrace
-- picture, and in the reference frame it carries the reflections of
-- everything standing on it
local floor_mat = material(magic.Color(1, 1, 1, 1), 0.18, 0.0,
		checker_texture(256, 20, magic.Color(0.04, 0.04, 0.05, 1),
		magic.Color(0.62, 0.63, 0.66, 1), magic.FILTER_TRILINEAR))
-- (the floor is the voxelworld's checkerboard now)

-- **The architecture is the voxelworld's now** (see main.cpp's Room):
-- six bays of stacked slabs across the back, each with one tier left
-- open and a niche behind it for an orb to glow out of. **The
-- composition rule** (user), read off the reference frame and against
-- the evenly-lit set that was rejected: every view has a light source
-- occluded by something -- so the orb sits in the niche and the stone
-- silhouettes against it.
--
-- These six numbers are the server's, written twice: the room is carved
-- there and the orbs are placed here. The check compares the two lists
-- and fails if they ever drift, which is cheaper than the packet round
-- trip the single copy would need before anything can be built.
local BAYS = 6
local BAY_SPACING = 14        -- voxels between bay centres
local SLAB_H = 3              -- voxels in one slab course
local BAY_Z = -18             -- the stacks' front face, in voxels
local BAY_DEPTH = 4
local NICHE_DEPTH = 3
local BAY_TIER = {2, 4, 1, 3, 5, 2}   -- 0-based, as the server has them
local function bay_x(i) return (i - 3) * BAY_SPACING - 7 end

-- **The orbs are the games** (user): warm is what you own, cold is a
-- server you can reach. The name is what a mark is generated from and
-- what Text3D says over the one being pointed at.
local ORBS = {
	{name = "Vanilla", warm = true},
	{name = "Undermine", warm = true},
	{name = "Digger", warm = true},
	{name = "buildat.example.org", warm = false, ping = 38},
	-- **Chekhov's empty shelf**: a bay with nothing in it, which is what
	-- says there is room for another game and is the way to ContentDB.
	-- The cartridge rack the earlier draft had is gone -- "the orbs are
	-- the games" settled that, and a rack beside them would be the same
	-- list twice.
	{name = "install a game", warm = true, empty = true},
	{name = "mine.example.net", warm = false, ping = 210},
}
local function bay_width(tier) return 10 - tier end

local orb_places = {}
local bay_desc = {}
for b = 1, BAYS do
	local tier = BAY_TIER[b]
	orb_places[b] = {
		x = bay_x(b) * VOXEL_M,
		y = (tier * SLAB_H + SLAB_H / 2) * VOXEL_M,
		z = (BAY_Z - BAY_DEPTH - 1) * VOXEL_M,
	}
	bay_desc[#bay_desc + 1] = string.format("%d %d %d", bay_x(b), tier,
			bay_width(tier))
end
log:info("bays " .. BAYS .. " " .. SLAB_H .. " " .. BAY_Z .. " " ..
		BAY_DEPTH .. " " .. NICHE_DEPTH .. " " ..
		table.concat(bay_desc, " "))

-- **The ornament, on primitives in front of the voxels.** The bays are
-- voxel mass and the ornament is a generated texture, and the two cannot
-- meet: a voxel's tile is loaded by resource name out of Urho3D's
-- ResourceCache and there is no way to put a generated Image in there.
-- So the friezes are what the plan's own "three representations, each
-- where it is better" asks for -- boxes carrying the meander and the
-- socket field, standing a little proud of the wall the way a course of
-- dressed stone stands proud of rubble.
frieze_nodes = {}
-- **Two nodes, not two materials.** Putting a material back on a model
-- later reads freed memory -- a Material in this sandbox lives only
-- while the engine holds it, and a Lua table holding the wrapper is not
-- enough (SIGSEGV in RefCounted::AddRef under StaticModel::SetMaterial,
-- which is what F6 did the first time it was written). So each frieze
-- is built twice, ornamented and plain, and the toggle enables one.
local function frieze(pos, scale, mat)
	local a = part("Box", pos, scale, mat)
	local b = part("Box", pos, scale, stone)
	b.enabled = false
	frieze_nodes[#frieze_nodes + 1] = {a, b}
end
do
	local z = (BAY_Z + 0.55) * VOXEL_M
	for b = 1, BAYS do
		local x = bay_x(b) * VOXEL_M
		local tier = BAY_TIER[b]
		local w = bay_width(tier) * VOXEL_M * 2
		-- The frieze over the opening, and its answer below it
		frieze(magic.Vector3(x, (tier * SLAB_H + SLAB_H + 0.6) * VOXEL_M, z),
				magic.Vector3(w, 1.05, 0.30), meander_mat)
		frieze(magic.Vector3(x, (tier * SLAB_H - 0.7) * VOXEL_M, z),
				magic.Vector3(w, 0.75, 0.30), meander_mat)
		-- The jambs: the socket field, which is the perforated block of
		-- the reference frame, down each side of the opening
		for _, side in ipairs({-1, 1}) do
			frieze(magic.Vector3(x + side * w * 0.42,
					(tier * SLAB_H + SLAB_H / 2) * VOXEL_M, z),
					magic.Vector3(w * 0.16, SLAB_H * VOXEL_M * 1.5, 0.28),
					b == 4 and sigil_mat or socket_mat)
		end
	end
	-- And one long course across the whole wall, above the bays, which is
	-- what makes the room read as built rather than as cut
	frieze(magic.Vector3(0, 19.5 * VOXEL_M, z),
			magic.Vector3(BAYS * BAY_SPACING * VOXEL_M, 1.35, 0.26),
			meander_mat)
end

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
				magic.Vector3(1.9, 1.9, 1.9), machined)
	else
		orb_mats[i] = glow(magic.Color(1, 1, 1, 1), spec and spec.name)
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				magic.Vector3(1.7, 1.7, 1.7), orb_mats[i])
		node:GetComponent("StaticModel").castShadows = false
		orb_nodes[i] = node
	end
end

-- The foreground: ten shipped primitives on the checkerboard, the chrome
-- ones doing what a perfect sphere under a sharp light does
local PROPS = {
	{"Sphere", -9.4, 1.55, 3.4, 3.1, "chrome"},
	{"Sphere", -4.6, 1.15, 6.0, 2.3, "chrome"},
	{"Sphere", 0.8, 1.55, 1.8, 3.1, "chrome"},
	{"Sphere", 5.8, 1.30, 5.2, 2.6, "chrome"},
	{"Sphere", 10.6, 1.60, 0.8, 3.2, "chrome"},
	{"Cone", -7.0, 1.35, 5.6, 2.7, "machined"},
	{"Cylinder", 3.6, 1.25, 6.4, 2.5, "machined"},
	{"Torus", -2.2, 0.60, 6.6, 2.6, "chrome"},
	{"Pyramid", 8.4, 1.15, 6.2, 2.3, "stone"},
	{"Pyramid", -12.0, 1.10, 4.8, 2.2, "machined"},
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
local LIGHT_PLACES = {}
for i, o in ipairs(orb_places) do
	-- A voxel forward of the orb, towards the opening: the orb is the
	-- thing you see and the light is what gets out of the niche, and a
	-- source at the very back of a recess mostly lights its own back
	LIGHT_PLACES[i] = {o.x, o.y, o.z + 1.2 * VOXEL_M}
end
-- **The fill lives in the foreground, not on the wall.** Matching the
-- reference frame's histogram with a long-range flood got the numbers
-- right and the picture wrong: the stone went evenly lit and stopped
-- silhouetting against the orbs, which is the whole composition. What
-- the reference is bright with is a lit floor and lit chrome in front
-- of dark stone, so the fill sits low and forward and falls off before
-- it reaches the bays.
LIGHT_PLACES[#LIGHT_PLACES + 1] = {-10.0, 1.3, 7.5}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {10.0, 1.3, 7.5}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, 4.2, 11.0}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, 1.0, 14.0}
-- **A wash per bay**, standing for the light that leaves a niche,
-- bounces off the floor and comes back onto the stone around the
-- opening -- which is where the reference frame's lit wall comes from
-- and which nothing in a direct-light room does by itself. It wears the
-- orb's own colour at a quarter strength, so it is that orb's spill and
-- not a new source, and it sits in front of the wall where a bounce
-- would be.
for i, o in ipairs(orb_places) do
	LIGHT_PLACES[#LIGHT_PLACES + 1] = {o.x, o.y * 0.55, o.z + 4.4}
end
local CYAN = {0.15, 0.85, 1.0}
local PURPLE = {0.55, 0.20, 0.95}
local AMBER = {1.0, 0.62, 0.12}
local WARM = {1.0, 0.72, 0.45}
local COLD_WHITE = {0.72, 0.85, 1.0}

-- {colour, intensity, range}. The first six are the orbs, in the order
-- the bays were built; the last four are fill. A preset says only what
-- colour each is, how bright and how far.
local function preset_lights(orb, fill, orb_i, fill_i)
	local l = {}
	for i = 1, 6 do
		l[i] = {orb, orb_i, 20 * U}
	end
	for i = 1, 6 do
		l[10 + i] = {orb, orb_i * 0.22, 9 * U}
	end
	l[7] = {fill, fill_i, 15 * U}
	l[8] = {fill, fill_i, 15 * U}
	l[9] = {fill, fill_i * 0.8, 17 * U}
	l[10] = {fill, fill_i * 0.7, 16 * U}
	return l
end

local PRESETS = {
	{
		-- The reference frame's own scheme and the plan's proposal: warm
		-- orbs beyond a cold room, so the stone silhouettes against them
		-- and the eye goes to the light rather than to the wall
		name = "cold_in_warm_out",
		lights = preset_lights(WARM, COLD_WHITE, 9.0, 2.5),
	},
	{
		-- The mirror, to see what was given up
		name = "warm_in_cold_out",
		lights = preset_lights(CYAN, AMBER, 9.0, 2.5),
	},
	{
		-- No warm anywhere: whether the room needs a warm point at all
		name = "all_cold",
		lights = preset_lights(COLD_WHITE, CYAN, 9.0, 2.5),
	},
	{
		-- Deliberately wrong, and the useful one: every colour loud, the
		-- purple as bright as the cyan, nothing scarce
		name = "wrong",
		lights = preset_lights(PURPLE, AMBER, 10.5, 4.5),
	},
}

-- Urho3D's PBR shaders want a light an order of magnitude brighter than
-- the non-PBR ones for the same picture: their falloff is physical and
-- brightness is radiant intensity, not a 0..1 dimmer. A preset's numbers
-- above are relative to each other, and this is the one place the scale
-- lives. Getting this wrong is what made PBR look like it did not work
-- at all -- the room came out black and the render path got the blame.
local PBR_INTENSITY = 25

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
	assert(cube:SetSize(PROBE_SIZE, magic.Graphics.GetRGBAFloat16Format(),
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
	local hdr = (buildat.get_env("BUILDAT_LAUNCH_HDR") or "") ~= ""
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
		-- The suspicion under test: set_preferred_viewports() renders the
		-- scene to an offscreen texture, and the effect reads the one
		-- named "viewport". BUILDAT_LAUNCH_RAWVIEW puts the scene on the
		-- renderer's own viewport instead, which is the same picture
		-- without that indirection.
		if (buildat.get_env("BUILDAT_LAUNCH_RAWVIEW") or "") ~= "" then
			magic.renderer:SetViewport(0, viewport)
			tonemap_raw = true
			log:info("tonemap: on the renderer's own viewport")
		end
		log:info("tonemap: " .. want .. ", " .. rp:GetNumCommands() ..
				" commands, HDR on")
	end
end
if not tonemap_raw then
	magic.set_preferred_viewports({viewport})
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
readout("b" .. buildat.version(), {x = 4.4, y = 0.25, z = 6.8}, 0.34,
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
local HOME_FROM = {x = 0.0, y = 2.75, z = 15.5}
local HOME_AT = {x = 0, y = 1.45, z = -6.0}
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
name_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 36)
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
		name_text.text = o and o.name or ""
		log:info("pointing at orb " .. best .. ": " ..
				(o and o.name or "?"))
	end
	if best > 0 then
		local p = orb_nodes[best].position
		name_node.position = magic.Vector3(p.x, p.y + 1.6 * U, p.z)
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

local function build_flying(b)
	local st = bay_state[b]
	if #st.slabs > 0 then
		return
	end
	local tier = BAY_TIER[b]
	local w = bay_width(tier)
	local x0 = bay_x(b)
	local i = 0
	for x = x0 - w, x0 + w do
		for y = 0, BAYS * SLAB_H - 1 do
			local v = voxelworld.get_static_voxel(
					buildat.Vector3(x, y, BAY_Z))
			if v and v.id >= 2 then
				i = i + 1
				local node = part("Box",
						magic.Vector3(x * VOXEL_M, (y + 0.5) * VOXEL_M,
						BAY_Z * VOXEL_M),
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
		buildat.send_packet("main:dissolve", (b - 1) .. " 1")
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
				buildat.send_packet("main:dissolve", (b - 1) .. " 0")
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
		buildat.disconnect()
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
