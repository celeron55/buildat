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

-- Held at module scope: a Lua-owned Image, Texture2D or Material is freed
-- when the last Lua reference goes, whatever is drawing with it
local kept = {}

-- The classic raytrace floor, built rather than loaded: a 2x2 checker is
-- the one texture the look actually needs
local function checker_texture(size, a, b)
	local image = magic.Image:new()
	assert(image:SetSize(size, size, 3), "Image:SetSize")
	local half = size / 2
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local dark = ((x < half) ~= (y < half))
			image:SetPixel(x, y, dark and a or b)
		end
	end
	local texture = magic.Texture2D:new()
	assert(texture:SetData(image), "Texture2D:SetData")
	-- Pixel art, not a smoothed gradient: FILTER_NEAREST keeps the edge
	texture.filterMode = magic.FILTER_NEAREST
	kept[#kept + 1] = image
	kept[#kept + 1] = texture
	return texture
end

-- Urho3D's PBR techniques, on the client's own render path -- no render
-- path control needed, and none of the preferred-viewport machinery is in
-- the way. What they do want is PBR_INTENSITY below.
-- simplified: a diffuse colour and a specular colour, not the metallic and
-- roughness the PBR shaders also read, and no material maps at all. The
-- material library is step 3 of the work and this room is step 1.
-- Polished dielectrics, not metals: a PBR metal reflects its surroundings
-- and nothing else, and with no IBL cubemap in the zone there are no
-- surroundings, so metallic 1 comes out black but for the highlight. A
-- low roughness at metallic 0 is the classic raytrace chrome here -- one
-- continuous sweeping highlight off a sphere under a sharp point light,
-- over an albedo that is still lit. An IBL probe is the upgrade, and it
-- belongs with the material library rather than with the palette.
local function material(colour, roughness, metallic, texture)
	local m = magic.Material:new()
	local t = magic.cache:GetResource("Technique",
			texture and "Techniques/PBR/PBRDiff.xml" or "Techniques/PBR/PBRNoTexture.xml")
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
zone.fogStart = 14
zone.fogEnd = 34

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

local chrome = material(magic.Color(0.82, 0.85, 0.90, 1), 0.08, 0.0)
local machined = material(magic.Color(0.38, 0.40, 0.45, 1), 0.35, 0.0)
local stone = material(magic.Color(0.26, 0.26, 0.29, 1), 0.85, 0.0)

-- The floor, and the checker on it
local floor_mat = material(magic.Color(1, 1, 1, 1), 0.45, 0.0,
		checker_texture(64, magic.Color(0.06, 0.06, 0.08, 1),
		magic.Color(0.55, 0.56, 0.60, 1)))
part("Plane", magic.Vector3(0, 0, 0), magic.Vector3(24, 1, 24), floor_mat)

-- The tomb's mass: three walls of stacked tiers, symmetric, with the
-- fourth side left open to the horizon. Ornament is a for loop.
for _, side in ipairs({{0, -9, 0}, {-9, 0, 90}, {9, 0, 90}}) do
	for tier = 0, 2 do
		local w = 18 - tier * 2
		local h = 1.6
		local y = 0.8 + tier * h
		local node = part("Box", magic.Vector3(side[1], y, side[2]),
				magic.Vector3(side[3] == 90 and 1.2 or w, h,
				side[3] == 90 and w or 1.2), stone)
	end
end

-- The chrome the classic raytrace scene is for: a sphere and a torus under
-- a sharp point light give one continuous sweeping highlight, which is the
-- whole look
part("Sphere", magic.Vector3(-2.6, 1.4, 0), magic.Vector3(2.4, 2.4, 2.4), chrome)
part("Torus", magic.Vector3(2.8, 1.0, -0.6), magic.Vector3(3.0, 3.0, 3.0), chrome)
part("Cylinder", magic.Vector3(0.2, 1.3, 3.2), magic.Vector3(1.0, 2.6, 1.0),
		machined)
-- A plinth: three stacked boxes is a sarcophagus
for tier = 0, 2 do
	part("Box", magic.Vector3(0, 0.15 + tier * 0.3, 0),
			magic.Vector3(9 - tier * 1.4, 0.3, 6 - tier * 1.0), stone)
end
-- A ring of twelve, because repetition is what reads as ornate
for i = 0, 11 do
	local a = i * math.pi / 6
	part("Box", magic.Vector3(math.cos(a) * 7.2, 0.25, math.sin(a) * 7.2),
			magic.Vector3(0.5, 0.5, 0.5), machined)
end

-- The ten lights are the experiment. Their places are the room's and do
-- not move; a preset says what colour, how bright and how far each is.
-- Roles, from the plan: 1-2 the interior key pair, 3-6 the readouts
-- (every readout is a real light source), 7-8 the structure's own glow,
-- 9 the one amber thing that wants you, 10 the horizon through the
-- opening.
local LIGHT_PLACES = {
	{-5.0, 5.2, -4.0}, {5.0, 5.0, 4.5},
	{-8.0, 2.2, 3.0}, {8.0, 2.2, -3.0}, {-8.0, 2.2, -5.0}, {8.0, 2.2, 5.5},
	{0.0, 4.4, -8.0}, {0.0, 1.0, 0.0},
	{2.8, 2.6, 4.6},
	{0.0, 3.0, 16.0},
}
local CYAN = {0.15, 0.85, 1.0}
local PURPLE = {0.55, 0.20, 0.95}
local AMBER = {1.0, 0.62, 0.12}
local WARM = {1.0, 0.72, 0.45}
local COLD_WHITE = {0.72, 0.85, 1.0}

-- {colour, intensity, range}
local PRESETS = {
	{
		name = "cold_in_warm_out",
		-- The proposal: cold inside, warm outside. The room is a tomb full
		-- of machines and cold is what dead-but-powered looks like; the
		-- warm horizon is the one thing not under the player's control.
		lights = {
			{COLD_WHITE, 1.10, 16}, {CYAN, 0.55, 14},
			{CYAN, 0.45, 6}, {CYAN, 0.45, 6}, {CYAN, 0.30, 6}, {CYAN, 0.30, 6},
			{PURPLE, 0.35, 10}, {PURPLE, 0.25, 7},
			{AMBER, 0.70, 7},
			{WARM, 0.55, 40},
		},
	},
	{
		name = "warm_in_cold_out",
		-- The mirror, to see what was given up: a warm interior reads cosy,
		-- which is what the tavern was thrown out for
		lights = {
			{WARM, 1.10, 16}, {AMBER, 0.55, 14},
			{AMBER, 0.45, 6}, {AMBER, 0.45, 6}, {WARM, 0.30, 6}, {WARM, 0.30, 6},
			{AMBER, 0.35, 10}, {AMBER, 0.25, 7},
			{CYAN, 0.70, 7},
			{COLD_WHITE, 0.55, 40},
		},
	},
	{
		name = "all_cold",
		-- No warm anywhere, so the question "does the room need a warm
		-- point at all" gets its own picture
		lights = {
			{COLD_WHITE, 1.10, 16}, {CYAN, 0.55, 14},
			{CYAN, 0.45, 6}, {CYAN, 0.45, 6}, {CYAN, 0.30, 6}, {CYAN, 0.30, 6},
			{PURPLE, 0.35, 10}, {PURPLE, 0.25, 7},
			{CYAN, 0.70, 7},
			{CYAN, 0.55, 40},
		},
	},
	{
		name = "wrong",
		-- Deliberately wrong, and it is the useful one: every colour bright,
		-- purple as loud as the cyan, amber everywhere instead of scarce.
		-- This is what the scheme collapses into if the rules are dropped.
		lights = {
			{PURPLE, 1.20, 20}, {AMBER, 1.20, 20},
			{AMBER, 1.00, 12}, {PURPLE, 1.00, 12}, {AMBER, 1.00, 12},
			{PURPLE, 1.00, 12},
			{{0.2, 1.0, 0.3}, 1.00, 16}, {AMBER, 1.00, 12},
			{AMBER, 1.20, 14},
			{{1.0, 0.2, 0.6}, 1.00, 40},
		},
	},
}

-- Urho3D's PBR shaders want a light an order of magnitude brighter than
-- the non-PBR ones for the same picture: their falloff is physical and
-- brightness is radiant intensity, not a 0..1 dimmer. A preset's numbers
-- below are relative to each other, and this is the one place the scale
-- lives. Getting this wrong is what made PBR look like it did not work at
-- all -- the room came out black and the render path got the blame.
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
camera_node.position = magic.Vector3(0.6, 3.4, 11.0)
camera_node:LookAt(magic.Vector3(0, 1.4, 0))
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
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

magic.ui:SetFocusElement(nil)

-- vim: set noet ts=4 sw=4:
