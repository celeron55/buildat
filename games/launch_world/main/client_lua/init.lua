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
-- No sky and no day: nothing in this room is lit by anything but the
-- orbs, so there is no skylight to flood
voxelworld.use_skylight = false
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
		{base = magic.Color(0.34, 0.35, 0.38, 1),
		inlay = magic.Color(0.17, 0.10, 0.22, 1), roughness = 0.70})
local socket_h, socket_i = ornament.sockets(ORN_SIZE,
		{cells = 3, depth = 2, seed = 7})
local socket_mat = ornamented(socket_h, socket_i,
		{base = magic.Color(0.24, 0.25, 0.28, 1),
		inlay = magic.Color(0.05, 0.05, 0.06, 1), roughness = 0.85})
local sigil_h, sigil_i = ornament.sigil(ORN_SIZE,
		ornament.seed_of("buildat.example.org:30000"), 4)
local sigil_mat = ornamented(sigil_h, sigil_i,
		{base = magic.Color(0.28, 0.29, 0.33, 1),
		inlay = magic.Color(0.10, 0.34, 0.42, 1), roughness = 0.55,
		metallic = 0.6})

-- The floor: a checkerboard in perspective is half the classic raytrace
-- picture, and in the reference frame it carries the reflections of
-- everything standing on it
local floor_mat = material(magic.Color(1, 1, 1, 1), 0.18, 0.0,
		checker_texture(256, 20, magic.Color(0.04, 0.04, 0.05, 1),
		magic.Color(0.62, 0.63, 0.66, 1), magic.FILTER_TRILINEAR))
-- (the floor is the voxelworld's checkerboard now)

-- The architecture: six bays of stacked slabs across the back, each with
-- an orb wedged behind it. **The composition rule** (user), read off the
-- reference frame and against the evenly-lit set that was rejected:
-- every view has a light source occluded by something -- so the orb sits
-- behind its bay and the stone silhouettes against it.
local BAYS = 6
local BAY_W = 6.4          -- metres between bay centres
local BAY_X0 = -(BAYS - 1) * 6.4 / 2
local SLAB = {h = 1.15, d = 1.6}
-- Where each bay's orb sits, as the tier it glows through: the tiers
-- differ bay to bay so the wall is not a row of identical holes
local BAY_TIER = {2, 4, 1, 3, 5, 2}
-- **The orbs are the games** (user): warm is what you own, cold is a
-- server you can reach. The name is what a mark is generated from and
-- what Text3D says over the one being pointed at.
local ORBS = {
	{name = "Vanilla", warm = true},
	{name = "Undermine", warm = true},
	{name = "Digger", warm = true},
	{name = "buildat.example.org", warm = false},
	{name = "Aggregate", warm = true},
	{name = "mine.example.net", warm = false},
}
local orb_places = {}
-- Every slab, with the bay it belongs to: the dissolve needs to know
-- which wall is coming apart
local bay_slabs = {}
for b = 1, BAYS do
	local x = BAY_X0 + (b - 1) * BAY_W
	bay_slabs[b] = {}
	-- The pillar: stacked slabs, each a little narrower than the one
	-- under it, which is the tomb read and is a loop rather than a model
	for tier = 0, 5 do
		local w = 4.4 - tier * 0.45
		local y = SLAB.h / 2 + tier * (SLAB.h + 0.12)
		local face = (b == 4) and sigil_mat or socket_mat
		if tier == BAY_TIER[b] then
			-- The tier the orb glows through: two posts and a gap
			for _, side in ipairs({-1, 1}) do
				bay_slabs[b][#bay_slabs[b] + 1] = part("Box",
						magic.Vector3(x + side * (w / 2 - 0.55), y, -8),
						magic.Vector3(1.1, SLAB.h, SLAB.d), face)
			end
			orb_places[#orb_places + 1] = {x = x, y = y, z = -9.6}
		else
			bay_slabs[b][#bay_slabs[b] + 1] = part("Box",
					magic.Vector3(x, y, -8),
					magic.Vector3(w, SLAB.h, SLAB.d), face)
		end
	end
	-- A lintel across the top of the bay, deeper than the stack, so the
	-- wall has a front plane as well as a back one
	bay_slabs[b][#bay_slabs[b] + 1] = part("Box",
			magic.Vector3(x, 6.0 + SLAB.h, -7.2),
			magic.Vector3(BAY_W - 0.5, 0.5, 2.6), meander_mat)
end
-- (the mass the room is cut out of is the voxelworld's now, so there is
-- no back wall here)

-- The orbs. Warm is what you own; the palette's own entry says which
-- colour each carries, and the light at it is what lights the room.
local orb_mats = {}
local orb_nodes = {}
for i, o in ipairs(orb_places) do
	orb_mats[i] = glow(magic.Color(1, 1, 1, 1), ORBS[i] and ORBS[i].name)
	local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
			magic.Vector3(1.7, 1.7, 1.7), orb_mats[i])
	node:GetComponent("StaticModel").castShadows = false
	orb_nodes[i] = node
end

-- The foreground: ten shipped primitives on the checkerboard, the chrome
-- ones doing what a perfect sphere under a sharp light does
local PROPS = {
	{"Sphere", -8.0, 1.05, -1.0, 2.1, "chrome"},
	{"Sphere", -4.2, 0.80, 1.8, 1.6, "chrome"},
	{"Sphere", 0.6, 1.20, -2.4, 2.4, "chrome"},
	{"Sphere", 5.2, 0.90, 1.0, 1.8, "chrome"},
	{"Sphere", 9.0, 1.30, -1.6, 2.6, "chrome"},
	{"Cone", -6.0, 1.05, 2.6, 2.1, "machined"},
	{"Cylinder", 3.0, 1.00, 3.4, 2.0, "machined"},
	{"Torus", -1.6, 0.45, 3.0, 2.2, "chrome"},
	{"Pyramid", 7.2, 0.90, 3.2, 1.8, "stone"},
	-- Not Dome.mdl: it is Urho3D's skydome and at any scale it arches
	-- over the whole room
	{"Pyramid", -10.4, 0.85, 2.2, 1.7, "machined"},
}
local MATS = {chrome = chrome, machined = machined, stone = stone}
for _, o in ipairs(PROPS) do
	part(o[1], magic.Vector3(o[2], o[3], o[4]),
			magic.Vector3(o[5], o[5], o[5]), MATS[o[6]])
end

-- The ten lights are the experiment. Their places are the room's and do
-- not move; a preset says what colour, how bright and how far each is.
-- Roles, from the plan: 1-2 the interior key pair, 3-6 the readouts
-- (every readout is a real light source), 7-8 the structure's own glow,
-- 9 the one amber thing that wants you, 10 the horizon through the
-- opening.
-- The first six lights are the orbs -- each sits inside its own sphere,
-- so what lights the room is the thing you can see lighting it. The last
-- four are fill: two low at the sides and two picking out the
-- foreground, which is what keeps the chrome from being a black ball
-- with one highlight.
local LIGHT_PLACES = {}
for i, o in ipairs(orb_places) do
	LIGHT_PLACES[i] = {o.x, o.y, o.z}
end
LIGHT_PLACES[#LIGHT_PLACES + 1] = {-11.0, 1.6, 2.0}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {11.0, 1.6, 2.0}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, 5.5, 6.0}
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, 1.2, 10.0}
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
		l[i] = {orb, orb_i, 17 * U}
	end
	l[7] = {fill, fill_i, 11 * U}
	l[8] = {fill, fill_i, 11 * U}
	l[9] = {fill, fill_i * 0.7, 13 * U}
	l[10] = {fill, fill_i * 0.5, 10 * U}
	return l
end

local PRESETS = {
	{
		-- The reference frame's own scheme and the plan's proposal: warm
		-- orbs beyond a cold room, so the stone silhouettes against them
		-- and the eye goes to the light rather than to the wall
		name = "cold_in_warm_out",
		lights = preset_lights(WARM, CYAN, 4.0, 0.30),
	},
	{
		-- The mirror, to see what was given up
		name = "warm_in_cold_out",
		lights = preset_lights(CYAN, AMBER, 4.0, 0.30),
	},
	{
		-- No warm anywhere: whether the room needs a warm point at all
		name = "all_cold",
		lights = preset_lights(COLD_WHITE, CYAN, 4.0, 0.30),
	},
	{
		-- Deliberately wrong, and the useful one: every colour loud, the
		-- purple as bright as the cyan, nothing scarce
		name = "wrong",
		lights = preset_lights(PURPLE, AMBER, 5.0, 1.6),
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
	light.castShadows = (i <= 2)
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
		-- An orb is its own light made visible, so it wears the colour it
		-- casts, well above 1 so it reads as a source and not as a pale
		-- ball -- and so the probe carries it to the chrome
		if orb_mats[i] then
			orb_mats[i]:SetShaderParameter("MatDiffColor",
					magic.Color(e[1][1] * 3.0, e[1][2] * 3.0, e[1][3] * 3.0, 1))
		end
		light.brightness = e[2] * PBR_INTENSITY
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
camera_node.position = V(0.0, 2.75, 15.5)
camera_node:LookAt(V(0, 1.45, -6.0))
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
-- voxelworld streams around the camera, which in this room never moves
voxelworld.set_camera(camera_node)
magic.set_preferred_viewports({viewport})

-- The name of the preset in the corner, so a picture says which it is
label = magic.ui.root:CreateChild("Text")
label:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
label.horizontalAlignment = magic.HA_LEFT
label.verticalAlignment = magic.VA_BOTTOM
label:SetPosition(8, -8)

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
local view_from = V(0.0, 2.75, 15.5)
local view_at = V(0, 1.45, -6.0)
local view_dir = magic.Vector3(view_at.x - view_from.x,
		view_at.y - view_from.y, view_at.z - view_from.z)
do
	local l = math.sqrt(view_dir.x ^ 2 + view_dir.y ^ 2 + view_dir.z ^ 2)
	view_dir = magic.Vector3(view_dir.x / l, view_dir.y / l, view_dir.z / l)
end

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
	for i, node in ipairs(orb_nodes) do
		local p = node.position
		local dx, dy, dz = p.x - view_from.x, p.y - view_from.y,
				p.z - view_from.z
		local l = math.sqrt(dx * dx + dy * dy + dz * dz)
		local dot = (dx * view_dir.x + dy * view_dir.y + dz * view_dir.z) / l
		if dot > best_dot then
			best, best_dot = i, dot
		end
		-- Present the face: the mark sits in the middle of the sphere's
		-- UVs, which Sphere.mdl puts on -Z, so the orb looks away from
		-- the viewer to show it to them
		node:LookAt(magic.Vector3(view_from.x * 2 - p.x,
				view_from.y * 2 - p.y, view_from.z * 2 - p.z))
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
-- only transition there is. States are configurations of one scene, not
-- screens with a camera parked in each, so a bay is a number in 0..1 and
-- every slab's place is read off it -- which makes it reversible,
-- interruptible and free of keyframes.
--
-- Where a slab goes is decided once from its own index, so the wall
-- comes apart the same way every time; a wall that scatters differently
-- on each open reads as noise rather than as a mechanism.
local DISSOLVE_SECONDS = 0.9
local bay_state = {}
for b = 1, BAYS do
	bay_state[b] = {t = 0, target = 0, slabs = {}}
	for i, node in ipairs(bay_slabs[b] or {}) do
		-- The numbers, not the Vector3: Node's position property hands
		-- back a reference to the node's own vector, so a "home" kept as
		-- that object follows the slab as it flies and the close lerps
		-- towards where it already is -- the bay opened and never shut
		-- (2026-09-23). Same trap as a const Vector3& property.
		local p = node.position
		local home = {x = p.x, y = p.y, z = p.z}
		-- Outward from the bay's middle, upward with the tier, and a
		-- little towards the viewer: the wall opens rather than explodes
		local dir = ((i % 2 == 0) and 1 or -1)
		bay_state[b].slabs[i] = {
			node = node,
			home = home,
			away = {x = home.x + dir * (2.5 + i * 0.35) * U,
					y = home.y + (1.2 + i * 0.28) * U,
					z = home.z + (2.2 + (i % 3) * 0.6) * U},
			-- The tumble as three angles rather than a quaternion to
			-- slerp towards: Quaternion:Slerp is not on the sandbox's
			-- whitelist, and scaling the eulers is the same picture for
			-- a slab that turns twenty degrees
			spin = {i * 11 % 40 - 20, i * 27 % 60 - 30, i * 17 % 50 - 25},
		}
	end
end

local function ease(t)
	-- Slow at both ends, which is what makes a heavy slab read as heavy
	return t * t * (3 - 2 * t)
end

function dissolve_bay(b, open)
	local st = bay_state[b]
	if st then
		st.target = open and 1 or 0
	end
end

function handle_dissolve_update(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	for b = 1, BAYS do
		local st = bay_state[b]
		if st.t ~= st.target then
			local was = st.t
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
			if st.t == st.target and was ~= st.target then
				log:info("dissolve: bay " .. b .. " settled at " .. st.t)
			end
		end
	end
end
magic.SubscribeToEvent("Update", "handle_dissolve_update")

set_preset(1)

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESCAPE then
		buildat.disconnect()
	end
	for n = 1, #PRESETS do
		if key == magic["KEY_" .. n] then
			set_preset(n)
		end
	end
	-- P takes the probe off the zone and puts it back, which is how a run
	-- shoots the same frame with and without it: a metal with nothing to
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
	if key == magic.KEY_P then
		probe_on = not probe_on
		zone.zoneTexture = probe_on and kept.probe or kept.dark_probe
		log:info("reflection probe " .. (probe_on and "on" or "off"))
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

magic.ui:SetFocusElement(nil)

-- vim: set noet ts=4 sw=4:
