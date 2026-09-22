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
-- The ornament generator and the maps it feeds; see ornament.lua
local ok_orn, err_orn, ornament = buildat.run_script_file("main/ornament.lua")
if not ok_orn or type(ornament) ~= "table" then
	error("ornament.lua: " .. tostring(err_orn))
end

-- Held at module scope: a Lua-owned Image, Texture2D or Material is freed
-- when the last Lua reference goes, whatever is drawing with it
local kept = {}

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

scene = magic.Scene()
scene:CreateComponent("Octree")

-- Ambient near zero: nothing in this room is lit by "the environment",
-- everything is lit by a source you can point at
local zone_node = scene:CreateChild("Zone")
local zone = zone_node:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(-200, 200)
zone.ambientColor = magic.Color(0.01, 0.01, 0.015, 1)
zone.fogColor = magic.Color(0, 0, 0, 1)
zone.fogStart = 26
zone.fogEnd = 64

local function part(model, pos, scale, mat)
	local node = scene:CreateChild("part")
	node.position = pos
	node.scale = scale
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
local function glow(colour)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureUnlit.xml"))
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
part("Plane", magic.Vector3(0, 0, 0), magic.Vector3(40, 1, 40), floor_mat)

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
local orb_places = {}
for b = 1, BAYS do
	local x = BAY_X0 + (b - 1) * BAY_W
	-- The pillar: stacked slabs, each a little narrower than the one
	-- under it, which is the tomb read and is a loop rather than a model
	for tier = 0, 5 do
		local w = 4.4 - tier * 0.45
		local y = SLAB.h / 2 + tier * (SLAB.h + 0.12)
		local face = (b == 4) and sigil_mat or socket_mat
		if tier == BAY_TIER[b] then
			-- The tier the orb glows through: two posts and a gap
			for _, side in ipairs({-1, 1}) do
				part("Box", magic.Vector3(x + side * (w / 2 - 0.55), y, -8),
						magic.Vector3(1.1, SLAB.h, SLAB.d), face)
			end
			orb_places[#orb_places + 1] = {x = x, y = y, z = -9.6}
		else
			part("Box", magic.Vector3(x, y, -8),
					magic.Vector3(w, SLAB.h, SLAB.d), face)
		end
	end
	-- A lintel across the top of the bay, deeper than the stack, so the
	-- wall has a front plane as well as a back one
	part("Box", magic.Vector3(x, 6.0 + SLAB.h, -7.2),
			magic.Vector3(BAY_W - 0.5, 0.5, 2.6), meander_mat)
end
-- And the back wall itself, so the orbs glow out of something rather
-- than out of the void
part("Box", magic.Vector3(0, 4.5, -11.2),
		magic.Vector3(BAYS * BAY_W + 6, 13.0, 0.8), stone)

-- The orbs. Warm is what you own; the palette's own entry says which
-- colour each carries, and the light at it is what lights the room.
local orb_mats = {}
for i, o in ipairs(orb_places) do
	orb_mats[i] = glow(magic.Color(1, 1, 1, 1))
	local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
			magic.Vector3(1.7, 1.7, 1.7), orb_mats[i])
	node:GetComponent("StaticModel").castShadows = false
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
		l[i] = {orb, orb_i, 17}
	end
	l[7] = {fill, fill_i, 11}
	l[8] = {fill, fill_i, 11}
	l[9] = {fill, fill_i * 0.7, 13}
	l[10] = {fill, fill_i * 0.5, 10}
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
	node.position = magic.Vector3(place[1], place[2], place[3])
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
camera_node.position = magic.Vector3(0.0, 2.75, 15.5)
camera_node:LookAt(magic.Vector3(0, 1.45, -6.0))
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
		cam.nearClip = 0.05
		cam.farClip = 120
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
	return cube
end
reflection_probe(magic.Vector3(0, 2.0, 0.0))

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
magic.set_preferred_viewports({viewport})

-- The name of the preset in the corner, so a picture says which it is
label = magic.ui.root:CreateChild("Text")
label:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
label.horizontalAlignment = magic.HA_LEFT
label.verticalAlignment = magic.VA_BOTTOM
label:SetPosition(8, -8)

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
	if key == magic.KEY_P then
		probe_on = not probe_on
		zone.zoneTexture = probe_on and kept.probe or nil
		log:info("reflection probe " .. (probe_on and "on" or "off"))
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

magic.ui:SetFocusElement(nil)

-- vim: set noet ts=4 sw=4:
