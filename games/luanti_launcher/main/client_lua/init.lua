-- Buildat: luanti_launcher/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A window onto a Luanti world running inside buildat_server, and the player
-- standing in it: the box walks, falls, climbs a step and is stopped by what
-- it runs into, and the camera sits where its eyes are. The physics is
-- player.lua, copied from extensions/luanti_client, which is also where its
-- checks live; what is here is the keys, the camera and the world to ask
-- about.
local log = buildat.Logger("luanti_launcher")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")
-- The module's own client half: what a Luanti game's textures are made of,
-- when a tile is an expression rather than a file, and what the player is
-- carrying
local luanti = require("buildat/module/luanti")

local scene = replicate.main_scene

-- Where the module's client half puts the objects: a Luanti world's dropped
-- items and entities are drawn by it, into whatever scene this game has
luanti.set_scene(scene)

-- Seen from outside itself, so nothing drops to a reduced LOD, and nothing
-- here walks on anything
voxelworld.lod_distance = 1000
-- The terrain's horizon into every chunk's mesh, and the vertex alpha
-- packed with it; the shader reads it so ([PBR_FIT] 2c)
voxelworld.horizon = true
voxel_shading.set_packed_sky(true)
voxelworld.physics_distance = 1
voxelworld.use_skylight = true

-- A Luanti world's light value says how much sky reaches a voxel, so that is
-- what says whether the sun reaches a surface: without this the sun lights
-- the walls of a cave it cannot see into, because a shadow map cannot tell
-- a cave from a canopy. See use_sun_gate() in builtin/voxel_shading.
voxel_shading.use_sun_gate(true)

-- And Luanti's own shaders rather than buildat's. One set, in
-- extensions/luanti_client/res/, used by both Luanti clients: this launcher
-- and the extension. builtin/voxel_shading is nine other games' look and
-- stays theirs -- it is still what chooses between these eight and what
-- pushes their parameters, and the .glsl behind them is the extension's.
-- See [SHADER_HOME] in doc/plan/master_plan.md.
voxel_shading.use_technique_set({
	plain = "luanti_client/res/LuantiVoxel.xml",
	modifiers = "luanti_client/res/LuantiVoxelModifiers.xml",
	alpha = "luanti_client/res/LuantiVoxelAlpha.xml",
	masked = "luanti_client/res/LuantiVoxelMasked.xml",
	sun = "luanti_client/res/LuantiVoxelSun.xml",
	sun_modifiers = "luanti_client/res/LuantiVoxelSunModifiers.xml",
	sun_alpha = "luanti_client/res/LuantiVoxelSunAlpha.xml",
	sun_masked = "luanti_client/res/LuantiVoxelSunMasked.xml",
})

-- Luanti's origin is where its mods build, so that is what the camera frames
local LOOK_AT = {x = 0, y = 2, z = 0}
local CAMERA_DISTANCE = 34
-- Luanti's own default, and what extensions/luanti_client uses
-- (BASE_FOV = 72): the two are compared frame against frame, and nothing in
-- a frame lines up while the cameras see different amounts of the world
local CAMERA_FOV = 72
local FAR_CLIP = 400
local VIEW_DIR = {x = -0.7, y = -0.55, z = -0.7}

local MOUSE_SENSITIVITY = 0.15

-- Below this a landing costs nothing, in nodes a second. Luanti's own
-- number, BS*14 on its wire; the server has it too and is the one that
-- decides, this only keeps a packet from going for every step off a kerb.
local FALL_TOLERANCE = 14

-- The player's own physics, which knows neither the protocol nor Urho3D:
-- see the header of player.lua
local ok_player, err_player, player_physics =
		buildat.run_script_file("main/player.lua")
if not ok_player or type(player_physics) ~= "table" then
	error("luanti_launcher: could not load player.lua: " .. tostring(err_player))
end

-- A game's own sky, which is six pictures rather than a gradient; see the
-- header of skybox.lua
local ok_sky, err_sky, skybox = buildat.run_script_file("main/skybox.lua")
if not ok_sky or type(skybox) ~= "table" then
	error("luanti_launcher: could not load skybox.lua: " .. tostring(err_sky))
end

-- And the sky itself, which is Luanti's own shader rather than buildat's;
-- see the header of luanti_sky.lua
local ok_lsky, err_lsky, luanti_sky =
		buildat.run_script_file("main/luanti_sky.lua")
if not ok_lsky or type(luanti_sky) ~= "table" then
	error("luanti_launcher: could not load luanti_sky.lua: " ..
			tostring(err_lsky))
end

-- The keys, in one place, so that what the player is told and what the code
-- reads cannot drift apart. Luanti's own defaults, and the F5 line below
-- lists them. `name` is what a player is shown, because a key constant is
-- not something to put in front of one.
local BINDINGS = {
	{action = "forward", key = magic.KEY_W, name = "W", what = "Walk forward"},
	{action = "back", key = magic.KEY_S, name = "S", what = "Walk back"},
	{action = "left", key = magic.KEY_A, name = "A", what = "Walk left"},
	{action = "right", key = magic.KEY_D, name = "D", what = "Walk right"},
	{action = "jump", key = magic.KEY_SPACE, name = "Space",
			what = "Jump, and up while flying"},
	{action = "sneak", key = magic.KEY_LSHIFT, name = "Shift",
			what = "Sneak, and down while flying"},
	{action = "fast", key = magic.KEY_LCTRL, name = "Ctrl", what = "Move fast"},
	{action = "fly", key = magic.KEY_K, name = "K", what = "Fly on and off"},
	{action = "noclip", key = magic.KEY_H, name = "H",
			what = "Through walls on and off"},
	{action = "hotbar", first = magic.KEY_1, last = magic.KEY_9,
			name = "1 - 9", what = "Pick a hotbar slot"},
	{action = "chat", key = magic.KEY_T, name = "T",
			what = "Say something - a line starting with / is a command"},
	{action = "inventory", key = magic.KEY_I, name = "I", what = "Inventory"},
	{action = "drop", key = magic.KEY_Q, name = "Q",
			what = "Drop what is held - with Ctrl, one of it"},
	{action = "mouse", key = magic.KEY_TAB, name = "Tab",
			what = "The mouse in the world or on the screen"},
	{action = "hud", key = magic.KEY_F1, name = "F1",
			what = "The HUD on and off"},
	{action = "chatlog", key = magic.KEY_F2, name = "F2",
			what = "The chat log on and off"},
	{action = "detail", key = magic.KEY_F5, name = "F5",
			what = "The line of detail on and off"},
	{action = "menu", key = magic.KEY_ESCAPE, name = "Escape",
			what = "The pause menu, or close what is open"},
	-- Listed for the player's sake; the code for these is the mouse
	-- handling rather than a key lookup
	{action = "dig", name = "Left mouse", what = "Dig"},
	{action = "place", name = "Right mouse", what = "Place, or use"},
	{action = "wield", name = "Mouse wheel", what = "Pick a hotbar slot"},
}

local BIND = {}
for _, b in ipairs(BINDINGS) do
	BIND[b.action] = b
end

local function key_down(action)
	local b = BIND[action]
	return b ~= nil and b.key ~= nil and magic.input:GetKeyDown(b.key)
end

-- The same PBR setup the lighting games use; games/voxel_lighting's README
-- says why these numbers are what they are. These are what noon looks like;
-- the sun moves with the world's clock, and night is the same sun dimmed
-- and turned blue -- see update_sky() below.
-- Luanti's own hue, at this game's own level. Its get_sunlight_color() is
-- all but neutral at noon -- 0.96, 0.96, 1.058, a tenth more blue than red
-- -- where this was nearly twice as blue as red and a quarter more green.
-- The mesher bakes the skylight into the vertex colour's alpha and the
-- shader adds cAmbientColor * alpha + rgb, so the ambient colour multiplies
-- every sky-lit surface: a blue ambient is a blue world.
--
-- **Set against pictures** (2026-09-16), which is what the note here used to
-- say this was waiting for. At 13:00 the reference shots put the module's
-- sunlit surfaces where official Luanti's are -- the 90th percentile of the
-- frame was 0.757 against 0.769 -- and its shade at nearly twice Luanti's:
-- 0.365 against 0.200. A sunlit surface is mostly sun and a shaded one is
-- almost all ambient, so the ambient is the term that separates them, and it
-- is [TOO_BRIGHT]'s "the top slightly above Luanti's, the bottom far below
-- it" in one number. The hue stays Luanti's, neutral.
local SKY_AMBIENT = magic.Color(0.144, 0.144, 0.158)
-- What is left when the sun is down. **Set against pictures** (2026-09-16):
-- at 20:30 the old value put the ground four times brighter than official
-- Luanti's, where extensions/luanti_client -- which derives its night ambient
-- from the sky with a floor of 0.015 of the moon's own colour -- lands within
-- a percent of it. The same hue, at the level the reference shots ask for;
-- see [TOO_BRIGHT] in doc/plan/rendering_plan.md.
local NIGHT_AMBIENT = magic.Color(0.012, 0.0144, 0.024)
-- **Set against pictures** (2026-09-16). At 13:00 a patch of sunlit grass
-- measured twice official Luanti's -- 0.396, 0.483, 0.349 against 0.186,
-- 0.234, 0.153, and the same ratio at a second patch -- while a shaded cliff
-- face measured 1.09 times its and the sky 1.04 times its. So the sun was the
-- whole of what was left, and twice is not the "slightly brighter than
-- non-PBR official Luanti, crisper, not excessive" the brief asks for. It
-- also blew the brightest surfaces out: foreground sand came back 1.00, 1.00,
-- 0.91 where its own texture is 0.87, 0.67, 0.50 and official Luanti draws it
-- at 0.85, 0.64, 0.48 -- white, and with the colour of the sand gone. See
-- [TOO_BRIGHT] in doc/plan/rendering_plan.md.
local SUN_BRIGHTNESS = 28.0
-- A fiftieth of the sun, which is extensions/luanti_client's number and is
-- not a measurement: real moonlight would render as nothing. It is a night
-- lit coldly from where the moon is, far enough above the sky's own light
-- that the moon casts a shadow. See [LIGHT_SHAPE].
local MOON_BRIGHTNESS = 1.0
-- [PBR_FIT] term 1: on the pbr path the sun and the sky are in the
-- path-traced reference's units, read off its EXRs (doc/plan/
-- rendering_plan.md, the fit's first term), and SUN_BRIGHTNESS, MOON_-
-- BRIGHTNESS, SKY_AMBIENT and NIGHT_AMBIENT above are the parity modes'
-- alone. The metering takes the absolute scale; what these set is the
-- ratio of sun to sky to moon, which is what contrast is made of.
--   sun_e0, sun_tau  the sun's irradiance normal to it, E0 * exp(-tau /
--                    sin(elevation)): 170 at 64 degrees, which puts the
--                    render's sky patch over its sunlit snow at 10:00
--                    (sky_to_sun 0.25) once the snow's albedo is read
--                    decoded, and 93 at ten degrees, which is
--                    what its block top at 05:45 reads (1.9, 1.4, 1.0)
--                    off an albedo of 0.3 with the Rayleigh sun and a
--                    dome of 1.5 solved together (dawn_sun_dirt)
--   sky_zenith,      the sky's radiance at the zenith and the horizon
--   sky_horizon      by day: the render's 13:00 reads 4.9 near the
--                    zenith, 7.7 thirty degrees up, 12 at the horizon;
--                    fading over the last twelve degrees of the sun's
--                    elevation
--   bounce           light off the surroundings where the sky does not
--                    reach, as a share of the sky's mean (term 2)
--   ground           the ground's albedo, for what the lower hemisphere
--                    of a face outdoors sees: dirt and grass, warm
--   moon_e           the moon lamp's irradiance, the render's own
--   night_sky        what the sky is with the sun down: a floor for
--                    airglow, since Nishita gives none and the night's
--                    target is a sky under a fortieth of moonlit snow
-- simplified: the sky keeps Luanti's hue at this radiance, and the sun
-- its colour below; the colours are the terms after this one.
local PHYS = {sun_e0 = 195, sun_tau = 0.127, sky_zenith = 4.5,
		sky_horizon = 12.0, moon_e = 0.0025, night_sky = 0.00005,
		bounce = 0.15, lamp = 8, dome = 0.9, ground = {r = 0.50, g = 0.44, b = 0.30}, -- doubled 2026-09-19 with groundSeen cubed,
		-- the transmitted light through a leaf, over Lambert through its
		-- colour ([PBR_FIT] 3b, canopy_dawn)
		translucency = 1.0,
		-- how bright a thin noon cloud is against the sky's zenith patch:
		-- picked by the user off a ladder of 1.5 to 20 ([CLOUD_LIGHT],
		-- 2026-09-19); BUILDAT_LUANTI_CLOUD_N overrides
		cloud_n = 8,
		day_zenith = {r = 0.57, g = 0.76, b = 1.0},
		-- the horizon just over the sea at 13:00 reads (14.7, 14.9, 15.0)
		-- in the render: white, not Luanti's pale blue
		day_horizon = {r = 0.99, g = 0.995, b = 1.0}}
-- The sky's radiance factor at a sun height (sin elevation): full by
-- day, gone over the last twelve degrees, the floor below
-- The zenith and the dome go first: at ten degrees the render's block
-- top is lit by a sun of about 74 over a dome of about 1.5, a third of
-- noon's, while its horizon band is still 9. The horizon keeps the old
-- short fade.
function PHYS.sky(height)
	return math.max(0, math.min(1, (height + 0.02) / 0.55))
end
function PHYS.horizon(height)
	return math.max(0, math.min(1, (height + 0.05) / 0.21))
end
function PHYS.sun(height)
	if height <= 0 then
		return 0
	end
	return PHYS.sun_e0 * math.exp(-PHYS.sun_tau / math.max(height, 0.05))
end
PHYS.SUN_COLOR = magic.Color(1.0, 0.96, 0.88)
PHYS.MOON_COLOR = magic.Color(0.55, 0.68, 1.0)
-- Reassigned when a game says what its horizon is; see sub_sky below
local DAY_FOG = magic.Color(0.60, 0.72, 0.88)
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
local EXPOSURE_BIAS = 1.6
-- [PT_EXPOSURE]: the pbr path meters its exposure by Urho3D's
-- AutoExposure.xml -- log-average luminance as the key, clamped to the
-- range, the frame scaled by middle grey over it -- which is the rule the
-- path-traced reference applies to its own frame (pathtrace_render.py,
-- LUM_RANGE and MIDDLE_GREY). The reference's constants are in radiance;
-- this frame is in the shader's own light scale until [PBR_TARGET]'s
-- Luanti-isms are out, so these are that scale's, and become the
-- reference's numbers the day the two scales meet. The adaptation rate is
-- this client's alone: a still has no time axis.
-- The floor is how far the eye may adapt into the dark: 0.05 was a
-- daylight-adapted eye looking at the night, and the moonlit snow field
-- rendered pitch black under it. 0.003 puts that field's probe at a
-- median of 39 of 255 in the render with the sky still at 0, which is
-- [PT_NIGHT]'s target; the same number is LUM_RANGE in
-- pathtrace_render.py.
local AUTO_EXPOSURE = {
	adapt_rate = 0.6,
	lum_range = {0.003, 100.0},
	middle_grey = 0.18,
	-- Frames left before the rate goes back after a reset; in this
	-- table since the chunk is at Lua 5.1's two hundred locals
	reset_frames = 0,
}

local function normalized(v)
	local l = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return {x = v.x/l, y = v.y/l, z = v.z/l}
end

-- Urho is left-handed and Y-up: yaw 0 looks towards +Z, and euler pitch is
-- positive downwards
local function angles_from_dir(d)
	d = normalized(d)
	return math.deg(math.atan2(d.x, d.z)), math.deg(math.asin(-d.y))
end

-- Level, and facing the way VIEW_DIR does, until the server says which way
-- the player was facing: a world they have been in before saved that along
-- with where they stood, and a level view for the moment before it arrives
-- reads as waiting where a confidently wrong angle reads as a bug. See
-- luanti.sub_player_pos() below.
local yaw = angles_from_dir(VIEW_DIR)
local pitch = 0
-- Whether the mouse turns the player's head or points at the screen. In the
-- world while playing, on the screen while a form is open or Tab says so.
local mouse_in_world = false

local function set_mouse_in_world(enable)
	mouse_in_world = enable
	magic.input:SetMouseVisible(not enable)
end

-- A form is clicked with the pointer, so while one is open the mouse is on
-- the screen and not in the world, and it goes back where it was when the
-- form goes. **Which form it is does not matter**: the server opens one by
-- itself -- a sign, a chest, /help -- and the keys here are not in it, so
-- the state is followed rather than set at the places that open one.
do
	local was_open = false
	local before = false
	magic.SubscribeToEvent("Update", function()
		local open = luanti.form_open()
		if open == was_open then
			return
		end
		was_open = open
		if open then
			before = mouse_in_world
			set_mouse_in_world(false)
		else
			set_mouse_in_world(before)
		end
	end)
end

local zone = nil
-- The sun and the moon, both in the scene: {sun_node, sun, moon_node, moon}.
-- One table rather than four locals because this file's main chunk is at
-- Lua 5.1's limit of two hundred of them.
local sky_lights = {}
-- The render path the world is drawn with, set where the viewport is; a
-- second view of the same world wants the same one
local world_render_path = nil

do
	local zone_node = scene:CreateChild("Zone")
	zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	-- Seven tenths of the way out, which is where
	-- extensions/luanti_client's starts; see [LIGHT_SHAPE]
	zone.fogStart = FAR_CLIP * 0.7
	zone.fogEnd = FAR_CLIP
	zone.priority = -1
	zone.override = true
	-- What the voxel shader reflects; without it its IBL term samples
	-- nothing and every reflection is black
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

-- **Two lights, not one that turns round at midnight.** The moon is the
-- same light from the other side of the sky, and having it as a light of its
-- own is what lets each be faded out over the hour it crosses the horizon
-- instead of the one direction flipping the instant the sun goes down --
-- which snapped every shadow in the world round at dawn and at dusk. Both
-- are in the scene for that hour, which is two shadow maps for two hours of
-- the day and one for the rest of it. extensions/luanti_client's shape; see
-- [LIGHT_SHAPE] in doc/plan/rendering_plan.md.
do
	local function body_light(name, color, brightness)
		local node = scene:CreateChild(name)
		node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
		local light = node:CreateComponent("Light")
		light.lightType = magic.LIGHT_DIRECTIONAL
		light.castShadows = true
		light.brightness = brightness
		light.color = color
		light.specularIntensity = 1.0
		-- Voxel faces at a grazing sun angle are the classic shadow acne
		-- case: a whole flat face falls inside one shadow texel and shadows
		-- itself in stripes. A slope-scaled bias on top of the automatic
		-- one, and a normal offset, which is the one that works on a face
		-- that is flat and wide. extensions/luanti_client's own numbers;
		-- see [WOBBLY_SHADOWS].
		light.shadowBias = magic.BiasParameters(0.00005, 0.8, 0.002)
		-- Two cascades rather than Urho3D's one spread over the whole
		-- shadow distance. The near one is confined to where the player is
		-- looking, so a node gets the texels it needs; without the split
		-- the same sparse grid slides under static geometry as the shadow
		-- camera is refitted each frame, which is the wobble.
		--
		-- 24 nodes and 96, not the far clip: a shadow map stretched over
		-- four hundred nodes has no density left where the player is.
		light.shadowCascade = magic.CascadeParameters(24, 96, 0, 0, 0.8)
		return node, light
	end
	sky_lights.sun_node, sky_lights.sun =
			body_light("Sun", PHYS.SUN_COLOR, SUN_BRIGHTNESS)
	sky_lights.moon_node, sky_lights.moon =
			body_light("Moon", PHYS.MOON_COLOR, MOON_BRIGHTNESS)
	-- Past the far cascade the world is ambient-lit, which at that range
	-- reads as haze rather than as a missing shadow.
	magic.renderer.shadowMapSize = 1024
	magic.renderer.shadowQuality = magic.SHADOWQUALITY_SIMPLE_16BIT
	magic.renderer.drawShadows = true
end

-- The sky the world stands under. builtin/voxel_shading's gradient sky is
-- not made at all: its sky setters all begin "if not skybox_material then
-- return", so the ones this file used to call become no-ops of their own
-- accord, and what it still owns -- the voxel materials, the reflections'
-- own cube map, set_sky_light() and set_sky_tint() -- is untouched.
local world_sky = luanti_sky.new(scene, SUN_DIR,
		voxel_shading.sky_defaults)

-- What the world reflects on the pbr path: the sky as it is drawn, into
-- a cube of its own, re-rendered when the hour or the sun moves. The
-- parity modes read no cube map, and a game's own skybox replaces it
-- below. See [SKY_REFLECTIONS] in doc/plan/rendering_plan.md.
-- One table, since this chunk is at Lua 5.1's two hundred locals: the
-- cube, and when it is next due -- the sun's direction moves every frame
-- and the cube is six renders, so once a second, which nobody sees jump
local sky_cube = {cube = require("buildat/extension/skycube").new(
		magic, world_sky.material), due = 0}
zone.zoneTexture = sky_cube.cube.texture
-- Microseconds the cube's render took since the frame peak last read it
sky_cube.us = 0
function sky_cube.refresh(force)
	local now = scene.elapsedTime
	if force or now >= sky_cube.due then
		sky_cube.due = now + 1
		local t0 = buildat.get_time_us()
		sky_cube.cube:update()
		sky_cube.us = sky_cube.us + buildat.get_time_us() - t0
	end
end

local game_skybox = skybox.new(scene, world_sky.node,
		function(expr) return luanti.texture(expr) end)

local camera_node = scene:CreateChild("Camera")
-- The component, because a waypoint asks it where a place in the world is
-- on the screen
local camera = nil
do
	local d = normalized(VIEW_DIR)
	camera_node.position = magic.Vector3(
			LOOK_AT.x - d.x * CAMERA_DISTANCE,
			LOOK_AT.y - d.y * CAMERA_DISTANCE,
			LOOK_AT.z - d.z * CAMERA_DISTANCE)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	camera = camera_node:CreateComponent("Camera")
	-- Luanti's own near plane, with its scaling undone: it sets
	-- 0.1 * BS in Camera::updateViewingRange() and BS is ten units to the
	-- node, so a tenth of a node. A standing player's eye is inside a node
	-- of any wall it is against, which at 1.0 clipped the wall away.
	camera.nearClip = 0.1
	camera.farClip = FAR_CLIP
	camera.fov = CAMERA_FOV

	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})

	-- Where the sounds are heard from, which is where the eyes are. How
	-- loud they are altogether is the user's own preference and not this
	-- game's to set.
	local listener = camera_node:CreateComponent("SoundListener")
	if magic.audio then
		magic.audio.listener = listener
	end

	magic.renderer.HDRRendering = true
	local base = viewport.renderPath
	local rp = base:Clone()
	-- The exposure first and the bloom after it: the bloom's threshold
	-- (0.8) is a screen value, and taken before the exposure on a world at
	-- the reference's radiances ([PBR_FIT], a sky of 5 and snow of 30) it
	-- passed every pixel, and the 40% blur it mixed back in was a haze
	-- that took the shadows with it.
	rp:Append(magic.cache:GetResource("XMLFile",
			"luanti_client/res/LuantiAutoExposure.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	rp:SetEnabled("TonemapReinhardEq3", false)
	-- BUILDAT_LUANTI_LINEAR=1: the metered frame clipped, no curve, which
	-- is what the path-traced reference's PNGs are; the reference runners
	-- set it so the fit's probes read linear against linear ([PBR_FIT])
	rp:SetEnabled("TonemapUncharted2",
			buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1")
	-- and no bloom either: the render has none, and a bright pass blurred
	-- over a probe crop is a white the crop did not earn
	rp:SetEnabled("BloomHDR", buildat.get_env("BUILDAT_LUANTI_LINEAR") ~= "1")
	-- The bloom's threshold is against the exposed frame, so it sits where
	-- that frame clips (the tonemap's shoulder starts above 1.0), and the
	-- stock 40% mix is a haze over a whole daylight picture; 15% is a glow
	-- on what clips ([BLOOM_PLACE]). How much is grade ([PBR_FIT] step 5).
	rp:SetShaderParameter("BloomHDRThreshold", 1.2)
	rp:SetShaderParameter("BloomHDRMix", magic.Vector2(1.0, 0.15))
	-- No bias on top of the meter: the meter owns the level and a bias is
	-- a second exposure that pushes the lit parts up the curve's shoulder
	-- ([PBR_FIT] term 4). EXPOSURE_BIAS stays the minimap's, which is not
	-- metered.
	rp:SetShaderParameter("TonemapExposureBias", 1.0)
	rp:SetShaderParameter("AutoExposureAdaptRate", AUTO_EXPOSURE.adapt_rate)
	-- BUILDAT_LUANTI_KEY=<lum> pins the metered key by closing the range on
	-- it, so an ablation's frames are comparable in absolute terms: with
	-- the key free, a term turned off re-exposes everything else
	local key = tonumber(buildat.get_env("BUILDAT_LUANTI_KEY") or "")
	if key then AUTO_EXPOSURE.lum_range = {key, key} end
	-- BUILDAT_LUANTI_ADAPT=<rate>: the adaptation rate, for a run that
	-- asks whether the meter had settled
	AUTO_EXPOSURE.adapt_rate = tonumber(
			buildat.get_env("BUILDAT_LUANTI_ADAPT") or "") or
			AUTO_EXPOSURE.adapt_rate
	rp:SetShaderParameter("AutoExposureLumRange",
			magic.Vector2(AUTO_EXPOSURE.lum_range[1],
			AUTO_EXPOSURE.lum_range[2]))
	rp:SetShaderParameter("AutoExposureMiddleGrey", AUTO_EXPOSURE.middle_grey)
	viewport.renderPath = rp
	-- A reference picture is taken at a settled exposure ([PT_SETTLE]):
	-- the reference fixture asks for this before the shot, and the
	-- adaptation -- adapted + (lum - adapted) * (1 - exp(-dt * rate)) in
	-- AutoExposure.glsl, kept in a persistent 1x1 target -- lands on the
	-- frame's own key in one frame at a rate of a million, and the rate
	-- goes back the frame after. Deterministic, and no wait.
	luanti.exposure_reset = function()
		rp:SetShaderParameter("AutoExposureAdaptRate", 1000000)
		AUTO_EXPOSURE.reset_frames = 2
	end
	-- The key pinned at one value, as BUILDAT_LUANTI_KEY does at start
	luanti.exposure_pin = function(k)
		AUTO_EXPOSURE.lum_range = {k, k}
		rp:SetShaderParameter("AutoExposureLumRange", magic.Vector2(k, k))
	end
	-- What a second view of the same world is drawn with -- the minimap.
	-- The tonemap is not optional: the world is rendered in HDR and an
	-- eight-bit picture of it without one is white. The bloom is, and it is
	-- left out: a picture the size of a stamp has nothing to bloom.
	world_render_path = base:Clone()
	world_render_path:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/Tonemap.xml"))
	world_render_path:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	world_render_path:SetEnabled("TonemapReinhardEq3", false)
	world_render_path:SetEnabled("TonemapUncharted2", true)
	world_render_path:SetShaderParameter("TonemapExposureBias", EXPOSURE_BIAS)
end



voxelworld.set_camera(camera_node)
voxel_shading.set_camera(camera_node)

magic.input:SetMouseVisible(true)

-- Every line of the HUD is drawn over a world that may be snow, sand or a
-- dark cave, so all of them carry a shadow; without it a white world takes
-- white text with it.
-- Whether the HUD and the chat log are drawn at all, which F1 and F2 are.
-- The game can take either away as well; both have to say yes -- see
-- draw_hud().
local hud_shown = true
local chat_shown = true

local function hud_text(size)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size or 15)
	t:SetTextEffect(magic.TE_SHADOW)
	t.effectColor = magic.Color(0, 0, 0, 0.85)
	return t
end

-- One line of a game's text, in as many pieces as it has colours in it: a
-- mod writes core.colorize() into a line and each piece is drawn in the
-- colour it asks for. Returns how wide and how tall the line came out.
local function draw_text_line(parent, line, x0, y0, base, size)
	local font = magic.cache:GetResource("Font", buildat.font_mono)
	local x, h = 0, 0
	for _, piece in ipairs(luanti.text_segments(line)) do
		local t = parent:CreateChild("Text")
		t:SetFont(font, size or 15)
		t:SetTextEffect(magic.TE_SHADOW)
		t.effectColor = magic.Color(0, 0, 0, 0.85)
		t:SetText(luanti.strip_escapes(piece.text))
		t.color = piece.color and magic.Color(piece.color.r, piece.color.g,
				piece.color.b) or base
		t:SetPosition(math.floor(x0 + x), math.floor(y0))
		x = x + t.width
		h = math.max(h, t.height)
	end
	return x, h
end

local crosshair = hud_text(20)
crosshair:SetText("+")
crosshair.horizontalAlignment = magic.HA_CENTER
crosshair.verticalAlignment = magic.VA_CENTER
crosshair:SetPosition(0, 0)

--
-- The hotbar
--
-- The first slots of the player's own inventory, along the bottom where
-- Luanti puts them: what is in each, how many, and which one is in hand.
-- The keys 1-8 and the wheel pick one, and the server is told -- what is in
-- hand is what a dig or a place asks it about.
-- How many are drawn is the game's to say -- hud_set_hotbar_itemcount() --
-- and this is Luanti's own ceiling on it. They are all built once and the
-- ones past the count are hidden, because the number changes when a game
-- says so and rebuilding them would be the same slots again.
local HOTBAR_MAX = 32
-- Luanti's own numbers, out of Hud::readScalingSetting() and
-- Hud::drawItems(): a slot's picture is 48 screen pixels times the display
-- density and the user's hud_scaling, its padding is a twelfth of that, and
-- a slot is the picture with padding on both sides. **The window size is not
-- in it**: the hotbar is a fixed size on the screen and does not grow with
-- the window.
--
-- This UI is not in screen pixels -- magic.ui.root is 1920 wide on a 1280
-- window -- so the 48 is converted, which is what keeps the row the same
-- number of screen pixels Luanti would have drawn.
local HOTBAR_IMAGE_SIZE = 48
-- hud_hotbar_max_width's default. Past this share of the window the row
-- splits in two, the first half above the second, which is what a game that
-- asks for a lot of slots hits.
--
-- simplified: the setting itself is the game's and does not cross to the
-- client yet, so this is Luanti's default rather than what the game said.
local HOTBAR_MAX_WIDTH = 1.0
local WHITE = luanti.texture("[fill:1x1:#ffffffff")

-- Luanti's own m_scale_factor, which every size and offset a HUD element
-- carries is multiplied by before it is drawn: Luanti's is the user's
-- hud_scaling times the display density, and its numbers are screen pixels.
-- This UI is not in screen pixels -- magic.ui.root is 1920 wide on a 1280
-- window -- so this is the conversion, and it is what keeps a HUD the same
-- number of screen pixels Luanti would have drawn it.
local function hud_scale()
	return magic.ui.root.width / math.max(1, magic.graphics.width)
end

-- The three numbers everything below is drawn from, in this UI's units
local function hotbar_metrics()
	local per_pixel = hud_scale()
	local imagesize = math.floor(HOTBAR_IMAGE_SIZE * per_pixel + 0.5)
	local padding = math.floor(imagesize / 12)
	-- And how far above the bottom of the screen it sits: Luanti's default
	-- hotbar element is at (0.5, 1) with an offset of four scaled pixels
	local margin = math.floor(4 * per_pixel + 0.5)
	return imagesize, padding, imagesize + padding * 2, margin
end

-- A slot's size, for what is drawn beside the hotbar rather than in it:
-- the line of text above it sits a slot and a bit higher
local SLOT
do
	local _, _, slot_size = hotbar_metrics()
	SLOT = slot_size
end

local hotbar = {}
local hotbar_stacks = {}
local hotbar_bg = nil
local hotbar_shown = true
local wield_index = 1

-- "basenodes:stone 7" -> the name and the count
local function parse_stack(str)
	if str == nil or str == "" then
		return nil
	end
	local name, count = string.match(str, "^([^ ]+) *(%d*)")
	if name == nil or name == "" then
		return nil
	end
	return name, tonumber(count) or 1
end

local function game_texture(resource)
	if not resource then
		return nil
	end
	local tex = magic.cache:GetResource("Texture2D", resource)
	if tex then
		-- A node's tile is sixteen pixels across and is drawn at forty:
		-- anything but nearest turns it to soup
		tex.filterMode = magic.FILTER_NEAREST
	end
	return tex
end

-- What a game's own sun or moon is drawn as, composed once per name: this is
-- asked for every frame and the answer changes twice a day
-- One cache per body, because both are up at once now and a single one
-- would recompose on every frame the two names differed
local body_picture_name, body_picture = {}, {}

local function body_picture_of(slot, name)
	if name ~= body_picture_name[slot] then
		body_picture_name[slot] = name
		body_picture[slot] = game_texture(luanti.texture(name))
	end
	return body_picture[slot]
end

do
	local white = game_texture(WHITE)
	-- Built before the slots so that they are behind them: a UI element's
	-- children are drawn in the order they were made. One per row, because
	-- Luanti draws the hotbar image once per row rather than once per slot.
	hotbar_bg = {}
	for r = 1, 2 do
		local bg = magic.ui.root:CreateChild("BorderImage")
		bg.horizontalAlignment = magic.HA_CENTER
		bg.verticalAlignment = magic.VA_BOTTOM
		bg.blendMode = magic.BLEND_ALPHA
		bg.visible = false
		hotbar_bg[r] = bg
	end
	for i = 1, HOTBAR_MAX do
		local frame = magic.ui.root:CreateChild("BorderImage")
		if white then
			frame.texture = white
		end
		-- What a slot wears when the game has given no hotbar image, which
		-- is Luanti's own fallback: half-transparent black, per slot
		frame.color = magic.Color(0, 0, 0, 0.5)
		frame.horizontalAlignment = magic.HA_CENTER
		frame.verticalAlignment = magic.VA_BOTTOM
		frame.visible = false
		-- The game's own mark for the slot in hand, under the item the way
		-- Luanti draws it; see hud_set_hotbar_selected_image()
		local marker = frame:CreateChild("BorderImage")
		marker.blendMode = magic.BLEND_ALPHA
		marker.visible = false
		local image = frame:CreateChild("BorderImage")
		image.visible = false
		local count = frame:CreateChild("Text")
		count:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 12)
		count:SetTextEffect(magic.TE_SHADOW)
		count.effectColor = magic.Color(0, 0, 0, 0.9)
		count.horizontalAlignment = magic.HA_RIGHT
		count.verticalAlignment = magic.VA_BOTTOM
		count:SetPosition(-3, -2)
		hotbar[i] = {frame = frame, image = image, count = count,
				marker = marker}
	end
end

-- What is in hand, drawn in front of the camera the way Luanti draws it: a
-- cube wearing the item's own image, turned so that three of its faces show.
--
-- simplified: a cube for everything, and unlit. A craftitem is a flat
-- picture in Luanti and a node is drawn as the node it places, with the
-- light where the player stands; here it is one shape and always visible.
local wield_node = camera_node:CreateChild("wielded")
local wield_model = wield_node:CreateComponent("StaticModel")
local wield_material = magic.Material.new()
-- Cut out by the picture's own alpha rather than opaque, because an item's
-- picture is a cutout: a plant, a tool, a sapling. Drawn opaque the holes in
-- it are black, and drawn blended a picture that is mostly holes is a ghost.
-- See builtin/luanti's client_data, which is where the technique is.
wield_material:SetTechnique(0, magic.cache:GetResource("Technique",
		"luanti/UnlitAlphaMask.xml"))
wield_model:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
wield_model.material = wield_material
-- Where a hand is: nearer than the player's own collision box is wide, so
-- that no wall can come between it and the eye -- which is what the near
-- plane at a tenth of a node allows. It is the same size on the screen as
-- it was out at 1.5: the distance and the scale came down together.
--
-- Luanti never makes this trade: it draws the wielded tool in a scene
-- manager of its own with the depth buffer cleared. This one is a child of
-- the camera node in the world's own scene, so what it has to clear is the
-- world's near plane.
--
-- The three numbers below were measured at a 45 degree field of view and
-- mean a place on the screen rather than a place in the world, so they
-- follow the camera: a wider view maps the same offset to a smaller part of
-- the frame, and the hand would walk towards the middle of the screen and
-- shrink. CAMERA_FOV is 72 now, which is Luanti's own.
local WIELD_TUNED_FOV = 45
local wield_k = math.tan(math.rad(CAMERA_FOV / 2)) /
		math.tan(math.rad(WIELD_TUNED_FOV / 2))
wield_node.position = magic.Vector3(0.103 * wield_k, -0.077 * wield_k, 0.25)
wield_node.rotation = magic.Quaternion(-18, 35, 8)
wield_node.scale = magic.Vector3(0.033 * wield_k, 0.033 * wield_k,
		0.033 * wield_k)
wield_node.enabled = false

local function draw_wielded(item_name)
	-- One face of it and not the whole picture: a node's item image is the
	-- little cube an inventory draws, and a cube wearing a picture of a cube
	-- is not what the hand holds
	local tex = item_name and
			game_texture(luanti.item_face_texture(item_name))
	if tex == nil or not luanti.hud_flag("wielditem") then
		wield_node.enabled = false
		return
	end
	wield_material:SetTexture(magic.TU_DIFFUSE, tex)
	wield_node.enabled = true
end

-- The name of what is in hand, above the slots: Luanti shows it when the
-- player switches, and it is what says an empty-looking slot has something
-- in it that has no image
local wielded_text = hud_text(14)
wielded_text:SetText("")
wielded_text.horizontalAlignment = magic.HA_CENTER
wielded_text.verticalAlignment = magic.VA_BOTTOM
wielded_text:SetPosition(0, -(8 + SLOT + 30))

-- The pictures the game named, kept as textures because these are asked for
-- on every redraw and a name is composed anew each time it is looked up
local hotbar_pictures = {}

local function hotbar_picture(name)
	if name == nil then
		return nil
	end
	if hotbar_pictures[name] == nil then
		-- false rather than nil, so that a game whose picture was never
		-- shipped is not composed again on every redraw
		hotbar_pictures[name] = game_texture(luanti.texture(name)) or false
	end
	return hotbar_pictures[name] or nil
end

local function draw_hotbar()
	local shown = luanti.hotbar or {}
	local n = math.max(1, math.min(HOTBAR_MAX, shown.count or 8))
	local imagesize, padding, slot_size, margin = hotbar_metrics()
	-- Luanti splits the row in two when it would be wider than this share
	-- of the window, the first half above the second
	local upper = 0
	if (n * slot_size) / magic.ui.root.width > HOTBAR_MAX_WIDTH then
		upper = math.floor(n / 2)
	end
	local rows = {
		{first = upper + 1, last = n, y = 0},
		{first = 1, last = upper, y = imagesize + padding},
	}
	-- The picture the game puts behind a row, half a padding proud of it on
	-- every side, which is where Luanti's own hud.cpp puts it -- one image
	-- stretched over the row rather than one per slot
	local bg = hotbar_picture(shown.image)
	local selected = hotbar_picture(shown.selected_image)
	local at_row, at_x = {}, {}
	for r, row in ipairs(rows) do
		local count = row.last - row.first + 1
		local row_width = count * slot_size
		local element = hotbar_bg[r]
		if bg and count > 0 then
			element.texture = bg
			element.size = magic.IntVector2(
					math.floor(row_width + padding),
					math.floor(slot_size + padding))
			-- Half a padding proud of the slots on every side, which is
			-- what hud.cpp draws it as
			element:SetPosition(0,
					-math.floor(margin + row.y - padding / 2))
		end
		element.visible = hotbar_shown and bg ~= nil and count > 0
		for i = row.first, row.last do
			at_row[i] = row
			-- A centred element's position is where its own centre goes,
			-- so the half slot is what puts the row's left edge on the
			-- left edge of the picture behind it
			at_x[i] = math.floor(-row_width / 2 +
					(i - row.first) * slot_size + slot_size / 2)
		end
	end
	for i = 1, HOTBAR_MAX do
		local slot = hotbar[i]
		slot.frame.visible = hotbar_shown and i <= n
		if i <= n then
			slot.frame.size = magic.IntVector2(slot_size, slot_size)
			slot.frame:SetPosition(at_x[i], -(margin + at_row[i].y))
			-- The game's mark is the item's own square grown by two
			-- paddings on every side, which is bigger than the slot: see
			-- drawItem() in Luanti's hud.cpp
			slot.marker:SetPosition(-padding, -padding)
			slot.marker.size = magic.IntVector2(
					imagesize + padding * 4, imagesize + padding * 4)
			slot.image:SetPosition(padding, padding)
			slot.image.size = magic.IntVector2(imagesize, imagesize)
		end
		local name, count = parse_stack(hotbar_stacks[i])
		local tex = name and game_texture(luanti.item_texture(name))
		-- Assigned only when there is one: the sandbox takes a Texture and
		-- not a nil, and an empty slot is an image that is not drawn
		-- The rect said outright ([ITEM_TILED]): while it is zero Urho
		-- spans the element's width in texels, and a texture that had no
		-- size at assignment tiled sixteen pickaxes to a slot
		if tex then
			slot.image.texture = tex
			if tex.width > 0 then
				slot.image.imageRect = magic.IntRect(0, 0, tex.width, tex.height)
			elseif not hotbar_pictures["size:" .. tostring(tex.name)] then
				hotbar_pictures["size:" .. tostring(tex.name)] = true
				log:info("picture " .. tostring(tex.name) ..
						" has no size yet at assignment ([ITEM_TILED])")
			end
		end
		slot.image.visible = tex ~= nil and tex.width > 0
		-- Luanti's own per-slot background, which is what a game that names
		-- no hotbar image gets; a game that names one has it behind the
		-- whole row instead, so the slots themselves are not drawn
		local marked = i == wield_index
		slot.frame.color = (name and tex == nil) and
				magic.Color(0.5, 0.3, 0.5, 0.75) or
				magic.Color(0, 0, 0, bg and 0 or 0.5)
		if marked and selected == nil then
			slot.frame.color = magic.Color(0.9, 0.9, 0.7, 0.55)
		end
		if selected then
			slot.marker.texture = selected
		end
		slot.marker.visible = marked and selected ~= nil
		slot.count:SetText((count and count > 1) and tostring(count) or "")
	end
	local name = parse_stack(hotbar_stacks[wield_index])
	wielded_text:SetText(name or "")
	draw_wielded(name)
end

-- Set once the HUD is built: a HUD element that draws a list of the player's
-- own has to follow it, and what the game sends is only the element
local hud_follows_inventory = nil

-- The images arrive after the inventory does -- the server sends one and the
-- client asks for the other -- so what was drawn without them is drawn again
luanti.sub_item_images(function()
	draw_hotbar()
end)

luanti.sub_inventory(function(lists)
	hotbar_stacks = lists.main or {}
	draw_hotbar()
	if hud_follows_inventory then
		hud_follows_inventory()
	end
end)

local function set_wield(i)
	local n = math.max(1, math.min(HOTBAR_MAX,
			(luanti.hotbar and luanti.hotbar.count) or 8))
	if i < 1 then
		i = n
	elseif i > n then
		i = 1
	end
	if i == wield_index then
		return
	end
	wield_index = i
	draw_hotbar()
	buildat.send_packet("main:wield",
			cereal.binary_output({tostring(i)}, {"array", "string"}))
end

draw_hotbar()

magic.ui:SetFocusElement(nil)

-- Mods load for several seconds before there is anything to draw, and what is
-- on the screen until then is sky
local wait_text = hud_text(24)
wait_text:SetText("Loading the world...")
wait_text.horizontalAlignment = magic.HA_CENTER
wait_text.verticalAlignment = magic.VA_CENTER
wait_text:SetPosition(0, 0)
voxelworld.sub_geometry_update(function(node)
	wait_text:SetText("")
end)
-- The forms' font sizes rasterized now, under the loading line
-- ([FORMSPEC_FRAME]); the first inventory then draws in a frame
luanti.warm_fonts()

--
-- The sky, and what time it is
--
-- The server says what time it is every few seconds and the clock is
-- carried on here in between, because a sky that jumps every five seconds is
-- worse than one that drifts. Luanti's day is one whole unit: 0.25 is
-- sunrise, 0.5 is noon, 0.75 is sunset.
--
-- simplified: the voxels' own light is what the mesher baked -- the sky
-- light a node has -- so a wall lit by the sky stays as bright at midnight
-- as it is at noon, dimmed only by the sun going away. Luanti's day-night
-- ratio, which scales the sky light per node, is the upgrade path.
local time_of_day = nil
local time_speed = 72

local function blend(a, b, t)
	return magic.Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
			a.b + (b.b - a.b) * t)
end

-- What the last sky update worked out, for the line of detail
local sky_now = {height = 0, day = 0}

-- **Registered after sky_now**, which it writes to: a closure made before
-- that local exists closes over a global of the same name instead, and the
-- handler then dies on its first line with nothing switched -- which is
-- exactly what happened, and what made three sets of reference shots that
-- were all pbr look like three modes that draw the same.
-- Or one of the two parity modes, if this session asked for one. **A startup
-- choice and not a toggle** -- the atlas's surface maps have to be on from the
-- first texture it builds -- so it arrives with luanti:world_info, which the
-- module asks for as its client half loads, well before the first chunk has
-- been meshed. What is already drawn keeps the technique it was drawn with,
-- which is what use_technique_set() says of itself.
--
-- | mode | what it draws | what it matches |
-- | unlit | the baked light and nothing else | official Luanti, shadows off |
-- | shadows | the same, with the sun's shadow map multiplying it | official Luanti as the reference runs it |
-- | pbr | this launcher's own look, and the default | nothing but the sunlit anchor |
--
-- See [RENDER_MODES] in doc/plan/rendering_plan.md.
--
-- **Four names for two files, and nothing new was written for unlit.**
-- VoxelUnlit discards below half alpha already, which is the whole of what
-- masked means; no Luanti game binds surface modifiers, so that name is the
-- plain one; and the sun-gated four go the same way, an unlit surface having
-- no sun to gate. The cube map, set_sky_light() and set_sky_tint() are left
-- alone: neither unlit shader reads any of them.
luanti.sub_world_info(function(info)
	local mode = info.mode or "pbr"
	if mode == "pbr" then
		return
	end
	log:info("BUILDAT_LUANTI_PBR=" .. mode .. ": drawing the world " .. mode)
	-- pbr_debug_shadows: pbr's path with the shadow-kind diagnostic on
	-- ([PBR_FIT] 2c). The mesher, which runs in this client and reads the
	-- same variable, colours each occlusion term into its own channel --
	-- terrain red, corners green, rays blue -- and the shader draws the
	-- vertex colour as it is; the sun and the moon go out (see the
	-- ablation) and the key is pinned at middle grey so a full term reads
	-- as one. BUILDAT_LUANTI_LINEAR=1 beside it, or the curve is on it.
	if mode == "pbr_debug_shadows" then
		sky_now.debug_shadows = true
		voxel_shading.set_shadow_kinds(true)
		if luanti.exposure_pin then luanti.exposure_pin(0.18) end
		return
	end
	-- On sky_now rather than locals of their own: init.lua's main chunk is at
	-- Lua 5.1's two hundred locals and has been for a while
	sky_now.unlit = true
	sky_now.shadows = mode == "shadows"
	-- **And no tonemap, which is half of what either parity mode means.** The
	-- unlit shader writes the light the mesher baked, which is already the
	-- number that belongs on the screen; put that through an HDR buffer, an
	-- exposure bias of 1.6 and Uncharted2 and the world comes out white.
	-- Official Luanti has no tonemap either, and being comparable to it is
	-- what these modes are for. The commands are disabled rather than removed
	-- because that is what a RenderPath offers.
	local vp = magic.renderer:GetViewport(0)
	local rp = vp and vp.renderPath
	if rp then
		rp:SetEnabled("BloomHDR", false)
		rp:SetEnabled("AutoExposure", false)
		rp:SetEnabled("TonemapUncharted2", false)
		rp:SetEnabled("GammaCorrection", false)
	end
	-- The minimap draws the same world through its own path
	if world_render_path then
		world_render_path:SetEnabled("TonemapUncharted2", false)
		world_render_path:SetEnabled("GammaCorrection", false)
	end
	magic.renderer.HDRRendering = false
	-- The difference between the two modes is one technique: LuantiVoxelUnlit
	-- adds a light pass that multiplies by the shadow factor, VoxelUnlit does
	-- not. Water is VoxelUnlitAlpha either way, being unshadowed in both.
	local opaque = sky_now.shadows and
			"luanti_client/res/LuantiVoxelUnlit.xml" or
			"luanti_client/res/VoxelUnlit.xml"
	voxel_shading.use_technique_set({
		plain = opaque,
		modifiers = opaque,
		masked = opaque,
		alpha = "luanti_client/res/VoxelUnlitAlpha.xml",
		sun = opaque,
		sun_modifiers = opaque,
		sun_masked = opaque,
		sun_alpha = "luanti_client/res/VoxelUnlitAlpha.xml",
	})
end)
-- Whether the eye is in a node that tints the screen
local underwater = false
-- What the game said its sky is, as luanti.sub_sky() gives it
local game_sky = {}

-- Luanti's indoors colour, the game's own or its default #646464, at a
-- brightness: what a direction that cannot see the sky is drawn as, and
-- what the fog underground is. See [CAVE_SKY].
local function indoors_of(k)
	local c = game_sky.indoors or {r = 0.39, g = 0.39, b = 0.39}
	return {r = c.r * k, g = c.g * k, b = c.b * k}
end

-- The moon has a colour of its own in the sky shader now, so nothing here
-- needs one; see set_moon_look() in luanti_sky.lua
-- A picture of a sun is drawn as itself: the colour multiplies it, so
-- anything but white would tint the game's own art
local WHITE_DISC_COLOR = {r = 1, g = 1, b = 1}

-- The sky at this hour: dark at night, the game's own colour by day, and the
-- dawn colour in between, with the stars fading as the light comes. Luanti
-- keeps three colours for exactly this and blends between them as the sun
-- goes round.
--
-- simplified: three colours and one factor, where Luanti's Sky::update()
-- has a separate brightness for the horizon, a sunrise band and a tonemap.
-- What this is for is a night that looks like night; the rest is the
-- difference between this sky and a photograph of Luanti's.
local function apply_sky_of_hour()
	local defaults = voxel_shading.sky_defaults
	local day_zenith = game_sky.zenith or defaults.zenith
	local day_horizon = game_sky.horizon or defaults.horizon
	if not sky_now.unlit then
		-- pbr: the day's hue is the render's, the game's own being
		-- display colours for Luanti's sky, not a radiance -- Nishita's (Nishita at 13:00, zenith (2.6, 5.1, 9.4), horizon
		-- (8.5, 12.6, 16.4)), given here display-encoded since dim()
		-- decodes. Luanti's (97, 146, 255) decodes to a zenith three
		-- times as blue as green, and a shadow lit by it read (0.95,
		-- 0.63, 1.8) against the render's (0.35, 0.39, 0.6) -- the
		-- desaturation of every shaded face ([PBR_FIT]).
		day_zenith = PHYS.day_zenith
		day_horizon = PHYS.day_horizon
	end
	-- A night sky the game did not name is its own day sky with the light
	-- taken out of it, which keeps a game's own colour rather than putting
	-- Luanti's blue over it
	local night_zenith = game_sky.night_zenith or
			{r = day_zenith.r * 0.10, g = day_zenith.g * 0.10,
			b = day_zenith.b * 0.14}
	local night_horizon = game_sky.night_horizon or
			{r = day_horizon.r * 0.10, g = day_horizon.g * 0.10,
			b = day_horizon.b * 0.14}
	local dawn_zenith = game_sky.dawn_zenith or
			{r = (day_zenith.r + night_zenith.r) * 0.5,
			g = (day_zenith.g + night_zenith.g) * 0.5,
			b = (day_zenith.b + night_zenith.b) * 0.5}
	local dawn_horizon = game_sky.dawn_horizon or
			{r = day_horizon.r * 0.75, g = day_horizon.g * 0.52,
			b = day_horizon.b * 0.45}
	local function three(night, dawn, day, t)
		local a, b, k
		if t < 0.5 then
			a, b, k = night, dawn, t * 2
		else
			a, b, k = dawn, day, (t - 0.5) * 2
		end
		return {r = a.r + (b.r - a.r) * k, g = a.g + (b.g - a.g) * k,
				b = a.b + (b.b - a.b) * k}
	end
	local t = sky_now.day
	-- The hour's own brightness, out of update_sky. Without it the launcher
	-- drew VoxeLibre's night_horizon #4A6790 as it stands and the night sky
	-- came out sixteen times official Luanti's.
	local lit = sky_now.lit or 1
	-- **The game's sky colours are sRGB and this pipeline is linear.** Luanti
	-- multiplies its colours by the hour and writes the product to an 8-bit
	-- buffer, so what it draws at midnight is that product as it stands;
	-- here the product goes into an HDR buffer and comes back out through
	-- GammaCorrection at the end of the render path, which lifts a dark value
	-- enormously -- a night sky Luanti draws at 0.008 was reaching the screen
	-- at 0.052, six times it. Converting once, here, is what makes the two
	-- ends meet: the day sky survives the round trip unchanged and the night
	-- lands where Luanti puts it.
	local function dim(c)
		local function one(v)
			local x = v * lit
			return x > 0 and x ^ 2.2 or 0
		end
		return {r = one(c.r), g = one(c.g), b = one(c.b)}
	end
	local horizon_now = dim(three(night_horizon, dawn_horizon, day_horizon, t))
	local zenith_now = dim(three(night_zenith, dawn_zenith, day_zenith, t))
	if not sky_now.unlit then
		-- pbr: Luanti's hue at the reference's radiance ([PBR_FIT] term 1)
		local function at(c, radiance)
			local lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			if lum <= 1e-6 then
				return {r = radiance, g = radiance, b = radiance}
			end
			local k = radiance / lum
			return {r = c.r * k, g = c.g * k, b = c.b * k}
		end
		local f = PHYS.sky(sky_now.height or 0)
		zenith_now = at(zenith_now,
				PHYS.night_sky + (PHYS.sky_zenith - PHYS.night_sky) * f)
		horizon_now = at(horizon_now, PHYS.night_sky +
				(PHYS.sky_horizon - PHYS.night_sky) * PHYS.horizon(sky_now.height or 0))
	end
	world_sky:set_look(zenith_now, horizon_now, nil)
	-- For the fog below, which on the pbr path is this horizon: the same
	-- radiance the sky meets the ground with, not a display colour
	sky_now.horizon_radiance = (not sky_now.unlit) and horizon_now or nil
	-- The dome's hue for the ambient: two parts zenith, one horizon, the
	-- cosine weighting a face sees -- a dawn's warm horizon reaches a
	-- wall, which is what the render's dawn dirt face is lit by
	-- With the horizon white on the pbr path the third of it made every
	-- shade too warm: the render's open shaded wall reads B/R 0.92 and
	-- pbr's 0.68 ([PBR_FIT], open_shade_dirt). Five parts zenith, one
	-- horizon: the band is bright but narrow under the cosine.
	sky_now.dome = {r = (5 * zenith_now.r + horizon_now.r) / 6,
			g = (5 * zenith_now.g + horizon_now.g) / 6,
			b = (5 * zenith_now.b + horizon_now.b) / 6}

	-- What the sun shines with now: its own colour, going red while it is
	-- crossing the horizon, which is where that colour belongs. It does not
	-- blend towards the moon any more -- the moon is a light of its own and
	-- has its own colour. The window is luanti_sky.sun_tint_share(), where
	-- the check is.
	--
	-- The colour is the game's own where it gave one, which is Luanti's
	-- fog_sun_tint and fog_moon_tint; the defaults behind them are Luanti's
	-- too. The moon takes the same handover on the other side of the sky,
	-- where it is crossing the horizon at the same hours.
	--
	-- simplified: fog_tint_type is carried but not read. "default" is
	-- Luanti's classic tinting, which goes through the tonemaps this sky
	-- has nowhere to put -- the drawing half of [SKY_LEFTOVERS] -- so both
	-- modes use the two colours, which is what was hardcoded before.
	local share = luanti_sky.sun_tint_share(sky_now.daylight)
	sky_lights.sun.color = blend(PHYS.SUN_COLOR,
			game_sky.sun_tint or luanti_sky.SUN_TINT, share)
	if not sky_now.unlit then
		-- pbr: the sun's colour from its elevation, not a tint at a
		-- clock ([PBR_FIT] term 3): Rayleigh transmittance through an
		-- air mass of 1 / sin(elevation), normalised to a luminance of
		-- one so PHYS.sun() keeps the level. The optical depths are sea
		-- level's at 680, 550 and 440 nm; white overhead, red across the
		-- horizon. simplified: no ozone, no aerosol; the dawn's target
		-- is the render's 05:45 (see the plan).
		local m = 1 / math.max(sky_now.height or 0, 0.05)
		local r, g, b = math.exp(-0.05 * m), math.exp(-0.10 * m),
				math.exp(-0.24 * m)
		local lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
		sky_lights.sun.color = magic.Color(r / lum, g / lum, b / lum)
		-- And the disc drawn at that: E0 of the hour over the disc's
		-- solid angle, pi times the half-width squared (0.075 is the
		-- tangent of the half-angle, near enough), in the same colour.
		-- The path trace's disc is this and clips white at every hour;
		-- Luanti's square at texture brightness sat under the snow after
		-- metering ([PBR_FIT] step 2). rgba16f holds 65 504, which the
		-- noon sun's eleven thousand is inside.
		local half = (game_sky.sun_scale or 1) *
				voxel_shading.sky_defaults.sun_half
		local disc = PHYS.sun(sky_now.height or 0) /
				(math.pi * half * half)
		disc = math.min(disc, 65504)
		local sc = sky_lights.sun.color
		world_sky:set_sun_radiance(disc * sc.r, disc * sc.g, disc * sc.b)
	end
	sky_lights.moon.color = blend(PHYS.MOON_COLOR,
			game_sky.moon_tint or luanti_sky.MOON_TINT, share)

	-- The sun and the moon are two bodies, drawn at once: the shader puts
	-- the moon opposite the sun, which is where Luanti puts it, so both are
	-- in the sky together and which one can be seen is which way the player
	-- is facing. It used to be one square that changed colour at nightfall,
	-- and a game that shows its moon in the day could not say so.
	--
	-- The game's own picture of each, if it gave one and the client could
	-- compose it -- Luanti's own sun.png and moon.png when the game said
	-- nothing, which is what it draws too. Without one each is the shader's
	-- own painted square, and the moon has its own colour there.
	local sun_picture = body_picture_of("sun", game_sky.sun_texture)
	world_sky:set_sun_texture(sun_picture)
	world_sky:set_sun_look(
			(game_sky.sun_visible ~= false) and
					defaults.sun_half * (game_sky.sun_scale or 1) or 0,
			sun_picture and WHITE_DISC_COLOR or defaults.sun_color)

	local moon_picture = body_picture_of("moon", game_sky.moon_texture)
	world_sky:set_moon_texture(moon_picture)
	world_sky:set_moon_look((game_sky.moon_visible ~= false) and
			luanti_sky.MOON_HALF * (game_sky.moon_scale or 1) or 0)

	-- The stars come out as the light goes: Luanti's day_opacity is zero by
	-- default, which is a sky with none in it until the sun is down
	local count = game_sky.star_count or luanti_sky.STARS_DEFAULT
	-- How many cells of the sky's grid have a star in them. The grid is a
	-- quarter of a million cells, not the ten thousand this used to divide
	-- by, so a game's thousand stars was putting **twenty-five times** that
	-- many in the sky -- which is most of why the module's night sky read
	-- three times brighter than official Luanti's. A game that hides its
	-- stars has none.
	local density = (game_sky.stars_visible ~= false) and
			math.min(0.5, luanti_sky.STAR_DENSITY_DEFAULT * count /
					luanti_sky.STARS_DEFAULT) or 0
	-- The count and the night ramp go to different parameters here, which
	-- is what LuantiSky keeps apart and buildat's sky folded together; see
	-- set_star_look() in luanti_sky.lua
	world_sky:set_star_look(density, game_sky.star_color, (1 - t) * (1 - t))

	-- What a direction that cannot see the sky is drawn as: Luanti's indoors
	-- colour, dimmed by the hour, and the game's own say over whether it
	-- happens at all. **By the same brightness the gradient is dimmed by**:
	-- Luanti keeps its indoors colour in the same bright-colour it keeps the
	-- sky's two ends in and multiplies all three by m_brightness at once. A
	-- linear tenth at midnight is five times that, which is enough to be the
	-- night sky -- it is mixed in wherever the sky-visibility cube says a
	-- direction is less than open, which outdoors is most of the low sky.
	world_sky:set_indoors(indoors_of(1), sky_now.lit or 1)
	-- The dim is Luanti's stand-in for the eye adapting to a cave, and
	-- pbr has the real thing in the meter: dimmed by the gate and keyed by
	-- the meter, the sky through a cave mouth read under its lit rim
	-- ([PBR_FIT], cave_opening). The parity modes keep it.
	world_sky:set_auto_dim(sky_now.unlit and
			game_sky.auto_dim_skybox ~= false or false)
	world_sky:set_physical(not sky_now.unlit)

	-- The clouds are white because the sun is on them, so they go with it --
	-- by the same brightness everything else up there goes by, which is what
	-- Luanti does: its Sky keeps a bright cloud colour and hands the Clouds
	-- what is left of it at this hour. The tenth-and-a-bit this used to floor
	-- at is eight times `lit` at midnight, and at viewpoint 1 at 20:30 the
	-- clouds were most of what was left of the night sky's brightness: the
	-- band measured 0.070, 0.080, 0.087 against official Luanti's 0.016,
	-- 0.022, 0.032, where the gradient behind them computes to less than
	-- official's on its own.
	world_sky:set_cloud_light(sky_now.lit or 1)
	if not sky_now.unlit then
		-- pbr: the cloud is a reflectance lit by the sun and the sky
		-- ([CLOUD_LIGHT]), not a display colour in a radiance sky. The
		-- game's cloud colour is the albedo (a cloud top's is near 0.9);
		-- the sky's share is the dome's mean, five parts zenith to one
		-- horizon; the sun's share is E_sun of the hour times how high
		-- it is, times k_sun. k_sun is set so that at noon a thin cloud
		-- is CLOUD_N times the zenith patch -- there being no reference
		-- for it, CLOUD_N was rated by the user (PHYS.cloud_n,
		-- default 2; the options are rendered under it).
		local albedo = game_sky.cloud_color or {r = 0.9, g = 0.92, b = 0.95}
		local function lum(c)
			return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		end
		local sky_mean = {r = (5 * zenith_now.r + horizon_now.r) / 6,
				g = (5 * zenith_now.g + horizon_now.g) / 6,
				b = (5 * zenith_now.b + horizon_now.b) / 6}
		local n = tonumber(buildat.get_env("BUILDAT_LUANTI_CLOUD_N") or "")
				or PHYS.cloud_n
		local noon_mean = (5 * PHYS.sky_zenith + PHYS.sky_horizon) / 6
		local k_sun = math.max(0, (n * PHYS.sky_zenith * math.pi /
				math.max(lum(albedo), 1e-6) - noon_mean) / PHYS.sun(1))
		local e = PHYS.sun(sky_now.height or 0) *
				math.max(sky_now.height or 0, 0) * k_sun / math.pi
		local sc = sky_lights.sun.color
		world_sky:set_cloud_lit(
				{r = albedo.r * e * sc.r, g = albedo.g * e * sc.g,
					b = albedo.b * e * sc.b},
				{r = albedo.r * sky_mean.r / math.pi,
					g = albedo.g * sky_mean.g / math.pi,
					b = albedo.b * sky_mean.b / math.pi})
	end
	-- And so does what a pond mirrors: the cube map it comes from is baked
	-- at noon, so without this the water is a bright blue sky at midnight
	-- On pbr the cube is rendered from this same sky at this hour and
	-- carries the night itself, so it is not dimmed a second time
	voxel_shading.set_sky_light(sky_now.unlit and (0.10 + 0.90 * t) or 1.0)
	-- The cube's reflection at 0.7 on pbr ([PBR_FIT] tuning): at 1 the
	-- glint on a grass top carried a blue the render's has not, and the
	-- water's far reflection read 3.4 over its near against 2.5
	-- The ablation is here, where the value is set each frame: set from
	-- the ambient's pass it was overwritten before a frame was drawn
	voxel_shading.set_specular_emphasis(
			(buildat.get_env("BUILDAT_LUANTI_ABLATE") or ""):find("ibl")
			and 0 or (sky_now.unlit and 1.0 or 0.7))
	-- And what colour that sky is now, which the cube map cannot know: the
	-- reflection is moved towards the zenith of this hour as the day goes,
	-- and left alone at noon, where the cube map is already right
	voxel_shading.set_sky_tint(
			three(night_zenith, dawn_zenith, day_zenith, t), 1 - t)
	sky_cube.refresh(true)
end

local function update_sky(dt)
	if time_of_day == nil then
		return
	end
	-- A day is 24*60*60 game seconds and time_speed is how many of them a
	-- real second is
	time_of_day = (time_of_day + dt * time_speed / (24 * 60 * 60)) % 1.0

	local daylight = time_of_day * 24000

	-- Where the sun is. Luanti's own stretched day, out of luanti_sky, and
	-- with it the clocks the two lights fade on. The tilt out of the
	-- vertical plane is this game's own, so that noon does not light every
	-- face of a cube the same way.
	--
	-- **Where the shadow is cast from steps and the light does not**: a
	-- shadow map rasterized afresh each frame from a light that has turned a
	-- little between two of them has crawling edges, so the direction is
	-- held still a step at a time. How bright, what colour and whether it is
	-- up stay smooth.
	-- How far the orbit is tilted, and who decided; see
	-- luanti_sky.orbit_tilt(). The one vector it produces is the light's and
	-- the drawn sun's both.
	local tilt = luanti_sky.orbit_tilt(game_sky.body_orbit_tilt,
			(luanti.world_info() or {}).orbit_tilt)
	local sx, sy, sz =
			luanti_sky.sun_direction(luanti_sky.stepped_time(daylight), tilt)
	local _, smooth_sy = luanti_sky.sun_direction(daylight, tilt)
	local height = smooth_sy
	-- The light travels the other way, which is what a Light's direction is.
	-- **Nothing else is done to it**: the sun is drawn from this same vector
	-- below, so anything added here would move the sun away from its own
	-- light. The tilt above is the only thing that turns the orbit.
	local dir = normalized({x = -sx, y = -sy, z = -sz})
	-- And the sky is given the sun's, always: it draws the moon opposite,
	-- so there is nothing to flip at nightfall
	world_sky:set_sun_direction(dir)
	sky_cube.refresh(false)

	-- Dawn and dusk are the half hour either side of the horizon rather
	-- than a switch -- unless the game says what the light is whatever the
	-- hour, which is what a dimension of its own is made of
	local day = math.max(0, math.min(1, (height + 0.15) / 0.3))
	if luanti.day_night_override then
		day = luanti.day_night_override
	end
	-- How light it is, which is not the same as which colours the hour uses.
	-- **Luanti multiplies what it drew by this** -- the sky's two ends and
	-- the fog with them -- so a game's night colours are a base to be dimmed
	-- and not the colour of the sky at midnight. The ramp is the extension's:
	-- Luanti's day/night ratio bottoms out at 0.175 rather than nothing, and
	-- goes through its light curve, which a gamma of 2.2 is the shape of.
	sky_now.lit = (0.175 + 0.825 * day) ^ 2.2

	-- How much of each light there is: its own hour of the day, whether it
	-- is over the horizon at all, what the cloud leaves of it, and whether
	-- the game turned it off. A body that is not there casts no light --
	-- VoxeLibre turns all three off when the weather turns -- so that is a
	-- gate and not a dimming. 0.8 is what a full overcast takes.
	local through_cloud = 1 - 0.8 * (game_sky.cloud_cover or 0)
	local up = luanti_sky.sun_amount(daylight) *
			luanti_sky.above_horizon(smooth_sy) * through_cloud *
			((game_sky.sun_visible ~= false) and 1 or 0)
	local moon_up = luanti_sky.moon_amount(daylight) *
			luanti_sky.above_horizon(-smooth_sy) * through_cloud *
			((game_sky.moon_visible ~= false) and 1 or 0)
	-- A light below the horizon is taken out of the scene rather than
	-- dimmed: a directional light does not know about the horizon, and one
	-- under it lights the undersides of everything and puts the night's
	-- specular on the wrong side of the sky.
	-- **In shadows the sun is in the scene for its shadow map alone** --
	-- LuantiVoxelUnlit's light pass multiplies rather than adds, so the
	-- light's colour and brightness never reach the picture -- and **in unlit
	-- it is not there at all**, which is what matches official Luanti with
	-- its dynamic shadows off. In pbr it lights the world the usual way.
	sky_lights.sun_node.enabled = up > 0 and
			not (sky_now.unlit and not sky_now.shadows)
	if up > 0 then
		sky_lights.sun_node.direction = magic.Vector3(dir.x, dir.y, dir.z)
		sky_lights.sun.brightness = sky_now.unlit and SUN_BRIGHTNESS * up or
				PHYS.sun(height)
		-- BUILDAT_LUANTI_ABLATE=sun,shadow,amb,bounce,ground,ibl: a term turned
		-- off for a fit's ablation run ([PBR_FIT]); the sun goes with any
		local abl0 = buildat.get_env("BUILDAT_LUANTI_ABLATE") or ""
		if sky_now.debug_shadows then abl0 = abl0 .. ",sun,moon" end
		if abl0:find("sun") then
			sky_lights.sun.brightness = 0
		end
		sky_lights.sun.castShadows = not abl0:find("shadow")
	end
	sky_lights.moon_node.enabled = moon_up > 0 and
			not (sky_now.unlit and not sky_now.shadows)
	if moon_up > 0 then
		sky_lights.moon_node.direction =
				magic.Vector3(-dir.x, -dir.y, -dir.z)
		sky_lights.moon.brightness = sky_now.unlit and MOON_BRIGHTNESS * moon_up
				or PHYS.moon_e * moon_up
		if sky_now.debug_shadows or
				(buildat.get_env("BUILDAT_LUANTI_ABLATE") or ""):find("moon") then
			sky_lights.moon.brightness = 0
		end
	end

	if sky_now.unlit then
		-- Unlit reads cAmbientColor.rgb * vColor.a + vColor.rgb, where the
		-- alpha is how much sky the surface sees, so the ambient is the whole
		-- of the daylight rather than a share of it beside a sun.
		--
		-- **And Luanti's daylight is not white.** get_sunlight_color() gives
		-- `ratio - 0.04` for red and green and `0.98 * ratio + 0.078` for
		-- blue, which at noon is 0.96, 0.96, 1.058 -- a tenth more blue than
		-- red. A neutral ambient, which this was, drew official Luanti's own
		-- stone at B/R 0.90 against its 1.00 and its snow at 1.03 against
		-- 1.12; extensions/luanti_client has carried the colour all along and
		-- reads 0.99 and 1.16 on the same probes. The brightness stays
		-- `lit` -- what is taken here is the hue, normalised at green.
		-- **Linear in the day/night ratio, not through the light curve.**
		-- Luanti applies its curve to the light *level*, which is what the
		-- mesher baked into the vertex colour's alpha and what this ambient
		-- multiplies; the hour enters as get_sunlight_color(), which is
		-- `ratio - 0.04` and linear. Taking the curved value for both
		-- squared the night: the parity modes drew every 20:30 and 02:00 at
		-- a quarter of official Luanti's, which is what the check against
		-- the reference set flagged.
		local ratio = 0.175 + 0.825 * day
		local rg = math.max(ratio - 0.04, 1e-4)
		local blue = (0.98 * ratio + 0.078) / rg
		zone.ambientColor = magic.Color(ratio, ratio, ratio * blue)
	else
		-- pbr: the ambient is the sky's mean radiance, in the sky's hue
		-- -- what a face lit by the sky alone receives, which the shader
		-- multiplies by how much sky the face sees. First cut of the
		-- two-term ambient ([PBR_FIT] term 2): one colour for the whole
		-- hemisphere, no ground bounce yet.
		local f = PHYS.sky(height)
		-- What a horizontal face receives over pi: the render's grass
		-- (albedo 0.036) reads 1.50 sunlit at 13:00 and 0.15 in the
		-- shade at 05:45, which leaves the dome at about the zenith's
		-- radiance -- the horizon's band is bright but at a grazing
		-- weight. So the zenith's, not a mean that counts the horizon.
		-- 0.7 of it: the render's snow in an open shadow at 10:00 reads
		-- (1.6, 3.0, 5.3), which off snow's albedo is a dome of 3.2
		-- against a drawn zenith patch of 4.5 -- Nishita's dome is
		-- bright toward the sun and dark away, and a face sees the mean
		local mean = PHYS.night_sky +
				(PHYS.sky_zenith * PHYS.dome - PHYS.night_sky) * f
		-- In the drawn sky's own hue, which is what a shadow on snow is
		-- lit by: the render's reads (1.6, 3.0, 5.3), the sky's blue,
		-- where a grey ambient gave a grey shadow.
		local c = sky_now.dome or blend(NIGHT_AMBIENT, SKY_AMBIENT, day)
		local lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
		local k = lum > 1e-6 and mean / lum or 0
		zone.ambientColor = magic.Color(c.r * k, c.g * k, c.b * k)
		-- And what a face the sky does not reach gets instead: light off
		-- the surroundings, a share of the sky's mean in its hue -- the
		-- second term ([PBR_FIT] term 2), fitted to the render's cave
		-- mouth. simplified: one share for the whole day; the render's
		-- cave at other hours is what would fit it further.
		voxel_shading.set_bounce_light(c.r * k * PHYS.bounce,
				c.g * k * PHYS.bounce, c.b * k * PHYS.bounce)
		-- A lamp at full in the sky's units: PHYS.lamp, in the glowstone's
		-- own orange, fitted to the render's LAMP_RADIANCE on the ceiling
		-- above it ([LAMP_REF], lamp_wall). simplified: one level and one
		-- colour for every light source; a torch is not a glowstone.
		voxel_shading.set_lamp_light(PHYS.lamp * 1.0, PHYS.lamp * 0.6,
				PHYS.lamp * 0.3)
		voxel_shading.set_translucency_gain(tonumber(
				buildat.get_env("BUILDAT_LUANTI_TRANSLUCENCY") or "") or
				PHYS.translucency)
		-- And the ground as the lower hemisphere sees it: its albedo
		-- times what falls on it, the sky on all of it and a third of
		-- the sun, over pi. A third, not the half that is lit on
		-- average: the ground a shaded wall faces is partly in the same
		-- shadow, and the base pass has no shadow map to say which. The
		-- tenth that stood here was fitted to the pit beside vp1's stone
		-- block and left the open shadow on the cliff top 1.75 times too
		-- dark ([PBR_FIT], contrast_dirt against contrast_dirt_pit).
		-- simplified: one albedo for every ground.
		local sun = PHYS.sun(height) * math.max(height, 0) * 1.0 / math.pi
		local sc = sky_lights.sun.color
		voxel_shading.set_ground_light(
				PHYS.ground.r * (sun * sc.r + c.r * k),
				PHYS.ground.g * (sun * sc.g + c.g * k),
				PHYS.ground.b * (sun * sc.b + c.b * k))
		local abl = buildat.get_env("BUILDAT_LUANTI_ABLATE") or ""
		if abl:find("amb") then zone.ambientColor = magic.Color(0, 0, 0) end
		if abl:find("bounce") then voxel_shading.set_bounce_light(0, 0, 0) end
		if abl:find("ground") then voxel_shading.set_ground_light(0, 0, 0) end
		if abl:find("lamp") then voxel_shading.set_lamp_light(0, 0, 0) end
	end
	-- And the fog with it. This is the one thing the cave sky needs that is
	-- not per direction, so it takes the mean of the same cube: underground
	-- the haze is the indoors colour rather than a sky the player cannot
	-- see. See [CAVE_SKY].
	local seen = voxel_shading.sky_visibility_above()
	-- And whether the sky is drawn at all, which is a late and conservative
	-- gate rather than a fade: anything less than fully enclosed draws the
	-- sky as it is, and only a cave with essentially no sky over it dims it.
	-- The short ramp is so that walking into one is not a step. See
	-- [CAVE_SKY]'s correction in doc/plan/rendering_plan.md.
	local outside = math.max(0, math.min(1, (seen - 0.02) / 0.08))
	world_sky:set_outside(outside)
	-- Logged when it moves, so a reference run's log carries the gate at
	-- each viewpoint -- the reading [CAVE_SKY] was owed from inside a cave
	if math.abs(seen - (sky_now.seen_said or -1)) >= 0.01 then
		sky_now.seen_said = seen
		log:info(string.format("cave gate: sky seen %.3f, outside %.2f",
				seen, outside))
	end
	-- A game's own fog colour is art direction and wins outright; without one
	-- the fog is the horizon, dimmed by the hour the way the sky it meets is.
	-- **One colour scaled, not two blended**: a hardcoded night fog is a
	-- second thing to keep in step with the gradient, and it was not in step
	-- -- the sky went dark and the fog stayed at 0.05, 0.07, 0.12, which is
	-- what the night sky then measured.
	-- Into the same space as the gradient it meets at the horizon: a fog that
	-- is still sRGB where the sky behind it has been converted is a bright
	-- band along the horizon of a dark sky. See dim() in apply_sky_of_hour().
	local base = game_sky.fog_color or
			blend(magic.Color(0, 0, 0), DAY_FOG, sky_now.lit)
	base = magic.Color(base.r > 0 and base.r ^ 2.2 or 0,
			base.g > 0 and base.g ^ 2.2 or 0,
			base.b > 0 and base.b ^ 2.2 or 0)
	-- On the pbr path the fog is the drawn horizon's radiance of the hour
	-- (apply_sky_of_hour(), a frame behind): a display colour dimmed by
	-- the hour sat at 0.004 under a night sky of 0.00005, and the meter
	-- lifted everything at the far edge of the range -- the snow-topped
	-- trees on vp5's ridge at 02:00 -- to white ([LOD_LIGHT]'s finding:
	-- it was the fog, not the far chunks' mesh path).
	-- And the indoors half of the blend in radiance too: Luanti's indoors
	-- colour (0.39 grey, dimmed by the hour) is display units, and under
	-- a forest's canopy `seen` is well under one, so at 02:00 the fog was
	-- 0.016 against a sky of 0.00005 -- and everything at the far edge of
	-- the range, where the fog is all there is, came out white after the
	-- meter: the snow-topped tree tops on vp5's ridge, at last. What a
	-- cave's haze is on the pbr path is the ambient of the hour, which is
	-- the light a cave gets.
	local indoors = indoors_of(0.10 + 0.90 * day)
	if sky_now.horizon_radiance then
		local h = sky_now.horizon_radiance
		base = magic.Color(h.r, h.g, h.b)
		indoors = zone.ambientColor
	end
	zone.fogColor = blend(base, indoors, 1 - seen)
	sky_now.height = height
	sky_now.day = day
	sky_now.daylight = daylight
	apply_sky_of_hour()
	-- What is in the player's hand is drawn unlit, so the daylight is put
	-- on it by hand; without this it glows at midnight. What the two bodies
	-- are worth to something with no normal to take a share of them by is
	-- the extension's object_sun: the moon counted at what it is worth
	-- against the sun.
	--
	-- simplified: kept as the same floor-and-ramp this always had rather
	-- than the extension's colour with the amount in its alpha, because the
	-- one thing here that is drawn unlit is the held item and a night at
	-- the extension's amount would leave it invisible.
	local k = 0.28 + 0.72 *
			math.min(1, up + moon_up * MOON_BRIGHTNESS / SUN_BRIGHTNESS)
	-- The objects take the same day's amount, by where each stands
	-- ([OBJECT_LIGHT])
	luanti.set_daylight(math.min(1, up + moon_up * MOON_BRIGHTNESS / SUN_BRIGHTNESS))
	-- By the light where the player stands ([WIELD_MESH] 3, Luanti's
	-- light_color): the eye voxel's skylight nibble takes the day's
	-- amount, the lamp nibble stands on its own, and the brighter wins --
	-- so a cave darkens the hand and a torch lights it. The nibbles are
	-- the flood's, 0..15; the floor is the same as before so the item is
	-- never gone.
	local cp = camera_node.worldPosition
	local eye = voxelworld.get_static_voxel(buildat.Vector3(
			math.floor(cp.x + 0.5), math.floor(cp.y + 0.5), math.floor(cp.z + 0.5)))
	if eye ~= nil then
		local reg = voxelworld.get_voxel_registry()
		local sky = reg:light_sky_of(eye) / 15
		local lamp = reg:light_lamp_of(eye) / 15
		k = 0.28 + 0.72 * math.max(sky * (k - 0.28) / 0.72, lamp)
	end
	wield_material:SetShaderParameter("MatDiffColor",
			magic.Color(k, k, k, 1.0))
end

-- What the game says its sky is: the two ends of the gradient and how much
-- of it is cloud. A game that says nothing keeps the sky voxel_shading
-- draws, which is what create_skybox() set.
luanti.sub_sky(function(sky)
	game_sky = sky
	local cover = nil
	if sky.clouds == false then
		cover = 0
	elseif sky.density then
		cover = math.max(0, math.min(1, sky.density))
	end
	if cover then
		world_sky:set_look(nil, nil, cover)
	end
	-- Kept as well as sent, because cloud dims the sun and the moon; see
	-- through_cloud in update_sky()
	game_sky.cloud_cover = cover
	-- The fog is the horizon seen through the world's air, so it follows
	-- the horizon the game asked for
	if sky.horizon then
		DAY_FOG = magic.Color(sky.horizon.r, sky.horizon.g, sky.horizon.b)
	end
	-- Luanti's fog_distance is not a fog knob but an upper bound on the
	-- client's viewing range, and the settled rule is that a game may lower
	-- it and never raise it -- see [SKY_KNOBS]. Negative gives it back.
	local far = FAR_CLIP
	if sky.fog_distance and sky.fog_distance >= 0 then
		far = math.min(FAR_CLIP, sky.fog_distance)
	end
	sky_now.far_clip = far
	if camera then
		camera.farClip = far
	end
	-- fog_start is a fraction of that range and not a distance; without one
	-- it is where extensions/luanti_client's starts
	if zone then
		zone.fogStart = far * (sky.fog_start or 0.7)
		zone.fogEnd = far
	end
	-- A skybox sky has no gradient to take a fog colour from, so Luanti fogs
	-- it with base_color; a plain sky's base_color is already the sky itself
	if sky.type == "skybox" and sky.base_color and not sky.fog_color then
		DAY_FOG = magic.Color(sky.base_color.r, sky.base_color.g,
				sky.base_color.b)
	end

	-- Six pictures rather than a gradient, if that is what the game asked
	-- for and all six of them arrived
	if sky.type == "skybox" and sky.textures and sky.textures[6] then
		local cube = game_skybox:set(sky.textures)
		-- What the world reflects follows the sky it is under; the zone's
		-- own is the baked gradient, which is what a game with no skybox
		-- keeps
		if cube and zone then
			zone.zoneTexture = cube
			log:info("the world reflects the game's own sky now")
		end
	elseif game_skybox:clear() and zone then
		zone.zoneTexture = sky_cube.cube.texture
	end
	apply_sky_of_hour()
end)

luanti.sub_time(function(tod, speed)
	time_of_day = tod
	time_speed = speed
	update_sky(0)
end)

--
-- Under water
--
-- Luanti paints the node's own post_effect_color over the screen while the
-- camera is in it -- renderPostFx() in clientmap.cpp: the colour the game
-- gave the node, any node and not only a liquid, and black in a solid one
-- unless noclip is on; the fog is left alone. That is what
-- extensions/luanti_client does too, and what this did before
-- ([RENDER_SURVEY], the underwater tint) was a fixed blue over any liquid
-- with the fog closed to forty nodes, which was neither.
-- simplified: post_effect_color_shaded, which dims the tint by the light
-- where the camera is, is read as the colour given.
local water_tint = magic.ui.root:CreateChild("BorderImage")
water_tint.visible = false
water_tint.priority = -500

-- The registry's definition of the voxel at p, or nil for nothing there
local function voxel_def_at(p)
	local v = voxelworld.get_static_voxel(p)
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	return reg:get_by_id(id)
end

-- The liquid at p, or nil: the registry's own is_liquid, so a game's lava
-- counts as much as its water. What the player swims in.
local function voxel_liquid_at(p)
	local def = voxel_def_at(p)
	if def == nil or not def.is_liquid then
		return nil
	end
	return def
end

local function update_underwater(eye)
	-- The tint of the node the eye is in: the game's colour for it, or
	-- black for a solid node in first person, or nothing
	local color = nil
	local def = voxel_def_at(eye)
	if def then
		local pe = luanti.post_effect_of(def.name.block_name)
		if pe and pe.a > 0 then
			color = magic.Color(pe.r / 255, pe.g / 255, pe.b / 255, pe.a / 255)
		elseif def.physically_solid and not player.noclip then
			color = magic.Color(0, 0, 0, 1)
		end
	end
	local now = color ~= nil
	underwater = now
	water_tint.visible = now
	if now then
		water_tint.texture = game_texture(WHITE)
		water_tint.color = color
		water_tint.size = magic.IntVector2(magic.ui.root.width,
				magic.ui.root.height)
	end
end

--
-- The player
--
-- What stops the player is the registry's own physically_solid, so glass
-- stops them and a plant does not. A voxel that has not arrived stops them
-- as well: standing still in a world that is still loading is better than
-- falling through it.
--
-- simplified: a whole cube per solid voxel, so a slab or a stair is a full
-- one to walk into. player.lua takes the boxes a voxel is made of instead,
-- and the registry has them (VoxelDefinition::shape); what is missing is
-- the physical boxes, which the mesher's shapes are not.
local function node_stops(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return true
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return true
	end
	local def = reg:get_by_id(id)
	return def == nil or def.physically_solid
end

-- And what the player is standing in, which is the same registry flag the
-- screen tint above reads. It was not passed, so in_liquid was false forever
-- -- no sinking, no swimming, no way out by jumping -- twenty lines from the
-- code that paints the water over the screen: the camera knew it was
-- underwater and the body did not.
local function node_is_liquid(x, y, z)
	return voxel_liquid_at(buildat.Vector3(x, y, z)) ~= nil
end

-- And what holds the player up instead of letting them fall: a ladder, a
-- vine, a rope. Luanti's own climbable, which the registry carries now.
local function node_is_climbable(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return false
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	local def = reg:get_by_id(id)
	return def ~= nil and def.climbable
end

-- And how much it holds them back: Luanti's move_resistance, which water
-- and lava have without a game saying anything and which a game can put on
-- anything else
local function node_resistance(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return 0
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return 0
	end
	local def = reg:get_by_id(id)
	return (def and def.move_resistance) or 0
end

-- And what standing on it does: the bouncy, slippery, disable_jump and
-- disable_descend groups, which the registry carries as fields. Inline:
-- this file is at Lua's 200-local limit.
local player = player_physics.new(node_stops, node_is_liquid,
		node_is_climbable, node_resistance, function(x, y, z)
	local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	return reg:get_by_id(id)
end)

-- What a mod has done to how this player moves: set_physics_override() on
-- the server. It multiplies the constants above rather than replacing them,
-- so speed boots, low gravity and a jump curse are these numbers arriving.
luanti.sub_physics(function(p)
	player.override = p
	-- Old move is not supported (decided 2026-09-19, [PLAYER_PHYSICS]):
	-- a game that asks for it gets new move and this line
	if p.new_move == 0 then
		log:warning("physics_override new_move = false asked; " ..
				"this client only has new move")
	end
end)

-- And what it has done to the view: set_fov() and set_eye_offset(). The
-- field of view is degrees, or a multiplier of this client's own when the
-- game says so, and 0 hands it back; the eye offset is in tenths of a node,
-- which is what BS is on Luanti's wire.
--
-- simplified: the transition time arrives and is not used -- the change is
-- at once. Luanti eases it over that many seconds, and the number is here
-- when somebody wants that.
local eye_offset = {x = 0, y = 0, z = 0}

luanti.sub_camera(function(c)
	if camera then
		if c.fov and c.fov > 0 then
			camera.fov = c.is_multiplier and (CAMERA_FOV * c.fov) or c.fov
		else
			camera.fov = CAMERA_FOV
		end
	end
	-- Luanti's own unit here is BS, which is ten units to the node
	eye_offset = {x = (c.eye.x or 0) / 10, y = (c.eye.y or 0) / 10,
			z = (c.eye.z or 0) / 10}
end)
-- Nothing moves until the server says where the player is: what it answers
-- with is the spawn, or where the last run left them, and a client that
-- started walking from somewhere of its own would tell the server that
-- instead. See M.sub_player_pos in the module's client half.
local player_placed = false

luanti.sub_player_pos(function(p)
	player:set_position(p.x, p.y, p.z)
	player.vx, player.vy, player.vz = 0, 0, 0
	-- And which way they were facing, which is send_where() below in
	-- reverse: the horizontal angle turns the other way round from Urho's
	-- yaw, and the vertical one is positive downwards as Urho's pitch is.
	if p.look_h then
		-- Wrapped, because a client that has been turning for a while sends
		-- a yaw of several hundred degrees and gets it back
		yaw = (-math.deg(p.look_h) + 180) % 360 - 180
		pitch = math.deg(p.look_v)
	end
	if not player_placed then
		player_placed = true
		set_mouse_in_world(true)
	end
	log:info("the server put the player at " ..
			string.format("%.1f, %.1f, %.1f", p.x, p.y, p.z) ..
			string.format(" looking %.0f, %.0f", yaw, pitch))
end)

-- What F5 shows: the two lines official Luanti's own status row shows, in
-- its units and its order, and buildat's own facts under them. The shape is
-- not a preference: every reference shot's numbers are read off Luanti's
-- row and typed back in here, and a line that prints the same facts
-- differently makes each of those a conversion done by hand. The keys are
-- not here -- they are in the pause menu, which lists the same BINDINGS.
--
-- The top left corner, at the very top, which is where official Luanti and
-- extensions/luanti_client both put it.
local detail_text = hud_text(13)
detail_text:SetText("")
detail_text.horizontalAlignment = magic.HA_LEFT
detail_text.verticalAlignment = magic.VA_TOP
detail_text:SetPosition(8, 8)
-- 0 nothing, 1 the two blocks official Luanti's own first debug level shows,
-- 2 everything. F5 cycles it; see [STATUS_LEVELS]. Starts at 1, so the row
-- is up without a key press -- [STATUS_DEFAULT].
local detail_level = 1
detail_text.visible = detail_level > 0

-- Luanti's yaw, from the launcher's. The launcher measures from +Z towards
-- +X, the way Urho does; Luanti measures from +Z towards -X, so the number
-- turns the other way round. The cardinal label is Luanti's own, in its own
-- quadrants -- and it is not decoration: it is what says the sign came out
-- right, because a picture labelled "South -Z" cannot be a picture of north.
local function luanti_yaw(internal)
	local y = (360 - internal) % 360
	local label
	if y >= 45 and y < 135 then
		label = "West -X"
	elseif y >= 135 and y < 225 then
		label = "South -Z"
	elseif y >= 225 and y < 315 then
		label = "East +X"
	else
		label = "North +Z"
	end
	return y, label
end

do
	-- The four directions, in the launcher's angles: 0 looks towards +Z and
	-- 90 towards +X, which Luanti calls 0 North and 270 East.
	local cases = {[0] = {0, "North +Z"}, [90] = {270, "East +X"},
			[180] = {180, "South -Z"}, [-90] = {90, "West -X"}}
	for internal, want in pairs(cases) do
		local y, label = luanti_yaw(internal)
		assert(y == want[1] and label == want[2],
				"luanti_yaw(" .. internal .. ") = " .. y .. " " .. label)
	end
end

-- The frame's wall time, held and decayed the way the server's step is
-- ([STEP_PEAK]): halved per minute, with the phase that set it. The
-- phases are what the client's frame does on the main thread that a
-- profiler block would sit around -- the mesh commit and the horizon
-- map (voxelworld's), the sky cube's render, the sky-visibility sweep,
-- this script's own update and the packets' Lua (client/packet.lua) --
-- and "rest" is the frame's time none of them account for: the
-- renderer, the network, the UI. The wall time is
-- the clock between this update and the last -- not Urho's TimeStep,
-- which its minFps clamps to 0.1 s -- so it is the previous frame's and
-- the phases are read one frame late to match it. See [FRAME_PEAK] in
-- doc/plan/performance_plan.md.
-- One table, this file being near Lua's 200 locals. A frame over
-- CEILING_S is a line at debug (trace is voxelworld's per-voxel spam), and the worst since the last info line
-- is said at info every LINE_S; the fuzz run reads the info lines.
local frame_peak = {DECAY = 0.99425, DECAY_EVERY_S = 0.5,
		CEILING_S = 0.05, LINE_S = 5,
		s = 0, phase = "", decay_due = 0,
		worst = 0, worst_phase = "", line_due = 5,
		-- this frame's own phases, in microseconds, set by the handler
		skyvis_us = 0, script_us = 0, last_us = nil}
function frame_peak.note(dt)
	local now = buildat.get_time_us()
	local wall = frame_peak.last_us and (now - frame_peak.last_us) / 1000000
			or dt
	frame_peak.last_us = now
	local vw = voxelworld.frame_us
	local pk = buildat.packet_us
	local phases = {
		{"mesh", vw.mesh}, {"horizon", vw.horizon}, {"physics", vw.physics},
		{"sky cube", sky_cube.us}, {"sky vis", frame_peak.skyvis_us},
		{"script", frame_peak.script_us},
		-- The packets' Lua, named by the packet that took longest
		{"packets " .. pk.worst_name, pk.total},
		-- The module's own frame: the HUD's redraw
		{"hud", luanti.frame_us or 0},
	}
	vw.mesh, vw.horizon, vw.physics, sky_cube.us = 0, 0, 0, 0
	luanti.frame_us = 0
	pk.total, pk.worst, pk.worst_name = 0, 0, ""
	local accounted = 0
	local longest, longest_phase = 0, "rest"
	for _, ph in ipairs(phases) do
		accounted = accounted + ph[2]
		if ph[2] > longest then
			longest, longest_phase = ph[2], ph[1]
		end
	end
	local rest = wall * 1000000 - accounted
	if rest > longest then
		longest_phase = "rest"
	end
	frame_peak.decay_due = frame_peak.decay_due - dt
	if frame_peak.decay_due <= 0 then
		frame_peak.s = frame_peak.s * frame_peak.DECAY
		frame_peak.decay_due = frame_peak.DECAY_EVERY_S
	end
	if wall > frame_peak.s then
		frame_peak.s, frame_peak.phase = wall, longest_phase
	end
	if wall > frame_peak.worst then
		frame_peak.worst, frame_peak.worst_phase = wall, longest_phase
	end
	if wall >= frame_peak.CEILING_S then
		local said = {}
		for _, ph in ipairs(phases) do
			if ph[2] >= 5000 then
				said[#said + 1] = string.format("%s %.0f ms", ph[1],
						ph[2] / 1000)
			end
		end
		log:debug(string.format("frame %.0f ms: %s", wall * 1000,
				#said > 0 and table.concat(said, ", ") or "rest"))
		-- And Urho's own table at once for a frame mostly outside the
		-- marks: its interval is reset every second by the debug HUD,
		-- so a table five seconds later has lost the frame. Its Max
		-- column is the slow frame's.
		if wall >= 0.2 and accounted < wall * 1000000 * 0.5 and
				buildat.profiler_data and
				(frame_peak.table_at or 0) + 5 < buildat.get_time_us() / 1e6 then
			frame_peak.table_at = buildat.get_time_us() / 1e6
			log:debug("profiler at that frame:\n" ..
					(buildat.profiler_data(4) or ""))
		end
	end
	frame_peak.line_due = frame_peak.line_due - dt
	if frame_peak.line_due <= 0 then
		frame_peak.line_due = frame_peak.LINE_S
		-- Only once there is a player: the world loading around the
		-- overview camera is not a frame anyone waits on, and the fuzz
		-- run reads these lines as the walk's
		if player_placed and frame_peak.worst > 0 then
			log:info(string.format("frame peak %.3f s in %s, held %.3f s",
					frame_peak.worst, frame_peak.worst_phase,
					frame_peak.s))
			-- Urho's own table of the same five seconds when the worst
			-- was over the ceiling: what "rest" was made of
			if frame_peak.worst >= frame_peak.CEILING_S and
					buildat.profiler_data then
				log:debug("profiler over those seconds:\n" ..
						(buildat.profiler_data(4) or ""))
			end
		end
		frame_peak.worst, frame_peak.worst_phase = 0, ""
	end
end

-- How fast frames are coming, over the same quarter second the block is
-- rebuilt in. Luanti's row prints the jitter beside the rate because an
-- average hides a stutter: it is how far the worst frame of the window ran
-- over the average one, which is what a hitch looks like as a number.
local frames, frame_sum, frame_max = 0, 0, 0
local function frame_sample(dt)
	frames = frames + 1
	frame_sum = frame_sum + dt
	if dt > frame_max then
		frame_max = dt
	end
end
local function frame_stats()
	local avg = frames > 0 and frame_sum / frames or 0
	local fps = avg > 0 and 1 / avg or 0
	local jitter = avg > 0 and (frame_max / avg - 1) * 100 or 0
	frames, frame_sum, frame_max = 0, 0, 0
	return fps, jitter
end

-- The counted facts, in the words extensions/luanti_client's debug line uses
-- them in: the two clients reach the same world by entirely different routes,
-- and a count that differs between them names the fault where a picture that
-- differs only asks a question. See doc/plan/luanti_module_plan.md, "The
-- numbers before the pixels".
local function counted_line()
	local c = luanti.counts()
	local w = voxelworld.counts()
	return string.format(
			"%d node definitions | %d item images | %d composed\n" ..
			"%d meshes | %d objects | %d hud | " ..
			"blocks: %d in scene, %d to mesh",
			w.voxel_types, c.items, c.composed,
			c.meshes, c.objects, c.hud, w.chunks, w.to_mesh)
end

-- Put under the lines of detail, which is where a Luanti client's chat goes;
-- assigned with the chat itself further down, because that is where the
-- block it moves is made.
local place_chat

-- The whole block, as one string, and the only place its shape is decided:
-- what is logged and what is drawn have to be the same text or the two
-- disagree eventually, and the disagreement turns up in the middle of a
-- comparison.
--
-- The first two lines are official Luanti's, field for field, so a number
-- here and a number in a reference shot are compared down the column
-- without arithmetic. Two of its fields are not here: drawtime, which needs
-- the renderer's own frame timing, and RTT, which needs the buildat link to
-- measure one. Everything buildat has and Luanti has not is on the lines
-- under them, out of the way of that comparison.
local function status_lines(level)
	local info = luanti.world_info()
	local fps, jitter = frame_stats()
	local mode = player.noclip and "noclip" or (player.fly and "flying" or
			(player.on_ground and "on the ground" or "falling"))
	local chunk_p = voxelworld.get_chunk_position(buildat.Vector3(
			player.x, player.y, player.z))
	local lyaw, cardinal = luanti_yaw(yaw)
	-- **One composer, and the short level is a subset of it.** Nothing else
	-- may know how to print a status field: the keybind banner this replaced
	-- was a second string written by hand somewhere else, and it ended up
	-- contradicting the row. See [STATUS_LEVELS] in
	-- doc/plan/luanti_module_plan.md.
	local game = info.game ~= "" and info.game or "?"
	-- Which of the three the picture was drawn in. **Three of the six
	-- reference sets differ from each other only by this**, so a shot that
	-- does not name it is the failure the position and the seed are there to
	-- prevent: one that cannot be told from a shot of something else.
	local rmode = info.mode or "pbr"
	local place = string.format(
			"pos: (%.1f, %.1f, %.1f) | yaw: %.1f\194\176 %s" ..
			" | pitch: %.1f\194\176 | seed: %s",
			player.x, player.y, player.z,
			lyaw, cardinal,
			-- Luanti's pitch is positive looking up, where the launcher's
			-- own is positive looking down as Urho's euler angle is
			-pitch,
			info.seed ~= "" and info.seed or "?")
	-- **Level 1 is one line and stays one line.** It exists so a reference
	-- run can carry a row without burying the thing being photographed, and
	-- that is a standing constraint rather than a detail: it carries what
	-- makes a picture a picture of what it claims to be, and nothing else.
	-- The frame rate is level 2's -- somebody watching frame times is
	-- debugging, which is what that level is for.
	-- The server's longest step, held and decayed: what a click has been
	-- waiting on lately. See [STEP_PEAK] in doc/plan/performance_plan.md.
	local step = string.format("step: %.2f s", info.step_peak or 0)
	-- And the client's longest frame beside it ([FRAME_PEAK])
	local frame = string.format("frame: %.2f s", frame_peak.s)
	if level == 1 then
		return "buildat | " .. game .. " | " .. rmode .. " | " .. step ..
				" | " .. frame .. " | " .. place
	end
	local blocks = {
		string.format(
			"buildat | game: %s | %s | %s | FPS: %.0f" ..
			" | dtime jitter: %.1f%% | view range: %d | %s%s | %s%s",
			game, rmode,
			info.version ~= "" and info.version or "Luanti ?",
			-- what the camera is actually drawing to, which a game may have
			-- lowered through its sky's fog_distance, and not the ceiling
			fps, jitter, sky_now.far_clip or FAR_CLIP, step,
			(info.step_peak_phase or "") ~= "" and
					(" (" .. info.step_peak_phase .. ")") or "",
			frame, frame_peak.phase ~= "" and
					(" (" .. frame_peak.phase .. ")") or ""),
		place,
		string.format(
			"%s | fov %.0f | speed %.1f, %.1f, %.1f | chunk %d, %d, %d%s",
			-- What the camera is actually at, not what this game asked
			-- for: a game's set_fov() changes it, and an FOV that does
			-- not match the shot it is compared against is one of the
			-- three most expensive findings this programme has had
			mode, (camera and camera.fov) or CAMERA_FOV,
			player.vx, player.vy, player.vz,
			chunk_p.x, chunk_p.y, chunk_p.z,
			voxelworld.chunk_has_physics(chunk_p) and "" or " (no physics)"),
		string.format("%02d:%02d | sun %.2f up, %.0f%% day",
			math.floor((time_of_day or 0) * 24),
			math.floor(((time_of_day or 0) * 24 % 1) * 60),
			sky_now.height, sky_now.day * 100),
		counted_line(),
	}
	return table.concat(blocks, "\n")
end

local detail_timer = 0
local function update_detail(dt)
	-- Every frame, whether the block is up or not: the rate and the jitter
	-- are of the frames, and a window that only counts while somebody is
	-- looking starts empty every time F5 is pressed
	frame_sample(dt)
	if not detail_text.visible then
		-- Rolled anyway, or the first line after F5 reports the jitter of
		-- every frame since the world came up, which is a loading hitch
		if frame_sum >= 0.25 then
			frame_stats()
		end
		return
	end
	detail_timer = detail_timer + dt
	if detail_timer < 0.25 then
		return
	end
	detail_timer = 0
	detail_text:SetText(status_lines(detail_level))
	if place_chat then
		place_chat()
	end
end


--
-- Chat
--
-- What has been said is at the bottom left, above what the player is
-- carrying; T opens a line to say something of one's own, and a line that
-- starts with "/" is a command the game answers. Both ends of it are the
-- server's: the module runs the callbacks, the vendored builtin runs the
-- commands, and what comes back arrives as luanti:chat.
local CHAT_LINES = 8
local CHAT_STYLE = magic.cache:GetResource("XMLFile",
		"__menu/res/main_style.xml")

-- A block of lines rather than one Text with newlines in it, because a line
-- is drawn in as many pieces as it has colours in it
local CHAT_SIZE = 14
local CHAT_LINE_H = 17
local CHAT_COLOR = magic.Color(1.0, 1.0, 0.9)
local chat_block = magic.ui.root:CreateChild("UIElement")
chat_block.horizontalAlignment = magic.HA_LEFT
-- The top left corner, under the lines of detail, which is where
-- extensions/luanti_client already decided a Luanti client's chat goes and
-- why: what a game puts on the screen of its own is along the bottom, and
-- chat down there lands on top of it. This was at the bottom, above the
-- hotbar, and that is exactly the collision.
chat_block.verticalAlignment = magic.VA_TOP
chat_block.size = magic.IntVector2(600, CHAT_LINES * CHAT_LINE_H)

-- And it moves: down as the lines of detail grow, back up when F5 takes them
-- away. Copying the position without copying this gives a block that is
-- right at one size and wrong at every other.
local chat_at_y = nil
place_chat = function()
	local y = 8
	if detail_text.visible then
		y = 8 + detail_text.height + 8
	end
	if y ~= chat_at_y then
		chat_at_y = y
		chat_block:SetPosition(8, y)
	end
end
place_chat()

local chat_input = nil
-- The key that opens the line arrives as text as well, and the line edit
-- would get it: the field goes up on the next frame instead, when that text
-- has gone nowhere. Copied from the extension, which found this out.
local chat_wanted = false

luanti.sub_chat(function(line, lines)
	-- The markup is still in these, which is what makes a coloured line
	-- coloured; luanti.chat_lines has the same lines without it
	local raw = luanti.chat_raw
	local first = math.max(1, #raw - CHAT_LINES + 1)
	chat_block:RemoveAllChildren()
	local y = 0
	for i = first, #raw do
		draw_text_line(chat_block, raw[i], 0, y, CHAT_COLOR, CHAT_SIZE)
		y = y + CHAT_LINE_H
	end
end)

local function close_chat()
	if chat_input then
		chat_input:Remove()
		chat_input = nil
		magic.ui:SetFocusElement(nil)
	end
end

local function open_chat()
	if chat_input then
		return
	end
	chat_input = magic.ui.root:CreateChild("LineEdit")
	chat_input.defaultStyle = CHAT_STYLE
	chat_input:SetStyleAuto()
	chat_input.horizontalAlignment = magic.HA_LEFT
	chat_input.verticalAlignment = magic.VA_BOTTOM
	chat_input.size = magic.IntVector2(
			math.min(560, magic.ui.root.width - 16), 26)
	chat_input:SetPosition(8, -8)
	chat_input.enabled = true
	chat_input:SetText("")
	chat_input:SetFocus(true)
end

local function send_chat()
	if not chat_input then
		return
	end
	local text = chat_input:GetText()
	close_chat()
	if text == nil or text == "" then
		return
	end
	buildat.send_packet("main:chat",
			cereal.binary_output({text}, {"array", "string"}))
end

--
-- The HUD a game draws itself
--
-- Luanti's own elements: an image, a line of text, a bar of icons. Where
-- they go is `pos` as a fraction of the screen plus `offset` in pixels,
-- with `align` saying which corner of the element lands there -- which is
-- Luanti's drawLuaElements, and what a game's hearts and bars are made of.
--
-- A waypoint and an image_waypoint are the two that are not over a corner of
-- the screen but over a place in the world; the camera says where that is.
--
-- simplified: the styles inside a line of text -- bold, italic, monospace
-- -- are not drawn; each missing kind is named once in the log so that a
-- game asking for one says so rather than silently missing it.
local hud_root = magic.ui.root:CreateChild("UIElement")
hud_root:SetPosition(0, 0)
local hud_missing = {}
-- The elements that are over a place in the world rather than over a corner
-- of the screen: where they go changes as the player moves, so they are
-- placed every frame and not only when the game changes one.
local hud_waypoints = {}
-- And the compasses, which turn with the player for the same reason
local hud_compasses = {}

-- How wide a picture is for its height, which is what a compass strip is
-- scaled by
local function tex_aspect(tex)
	if tex == nil or tex.height == nil or tex.height <= 0 then
		return 1
	end
	return tex.width / tex.height
end

local function parse_v2(str, dx, dy)
	if type(str) ~= "string" then
		return dx, dy
	end
	local x, y = string.match(str, "^([^,]*),(.*)$")
	return tonumber(x) or dx, tonumber(y) or dy
end

local function parse_v3(str)
	if type(str) ~= "string" then
		return nil
	end
	local x, y, z = string.match(str, "^([^,]*),([^,]*),(.*)$")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x == nil or y == nil or z == nil then
		return nil
	end
	return x, y, z
end

-- Where a place in the world is on the screen, in pixels, or nil for one
-- behind the camera -- which Luanti does not draw a waypoint for either.
-- The scene's coordinates are the game's node coordinates, so a world_pos
-- goes in as it came.
local function screen_of(x, y, z)
	if camera == nil then
		return nil
	end
	local eye = camera_node.position
	local dir = camera_node:GetWorldDirection()
	local ahead = (x - eye.x) * dir.x + (y - eye.y) * dir.y +
			(z - eye.z) * dir.z
	if ahead <= 0 then
		return nil
	end
	local p = camera:WorldToScreenPoint(magic.Vector3(x, y, z))
	return p.x * magic.ui.root.width, p.y * magic.ui.root.height
end

-- Where an element sits: the anchor is position times the screen plus the
-- offset, and align slides it by its own size from there. Luanti's hud.cpp
-- does that as `(align - 1) * size / 2` everywhere it places anything -- so
-- align -1 puts the element's right edge on the anchor, 0 centres it and +1
-- puts its left edge there. **The sign was the other way round here**, which
-- is invisible at align 0, the default and what every element that was
-- looked at used; a status line asking for the top right corner was drawn
-- eight pixels off the right edge of the screen instead.
local function hud_place(element, e, w, h)
	-- Which UI element it was placed as, for the scan's rectangles
	-- ([SCAN_EVENT]); on the game's own table, this file being at Lua's
	-- 200 locals
	e.__placed = element
	local px, py = parse_v2(e.pos, 0, 0)
	local ox, oy = parse_v2(e.offset, 0, 0)
	local ax, ay = parse_v2(e.align, 0, 0)
	-- The offset a game gives is in Luanti's screen pixels and is scaled
	-- the way every other number it gives is; the size it slides by is
	-- already in this UI's units, having been scaled where it was read
	local scale = hud_scale()
	element:SetPosition(
			math.floor(px * magic.ui.root.width + ox * scale +
					(ax - 1) * 0.5 * w),
			math.floor(py * magic.ui.root.height + oy * scale +
					(ay - 1) * 0.5 * h))
end

local function hud_colour(number)
	local n = tonumber(number)
	if n == nil or n == 0 then
		return magic.Color(1, 1, 1)
	end
	return magic.Color(
			math.floor(n / 65536) % 256 / 255,
			math.floor(n / 256) % 256 / 255,
			n % 256 / 255)
end

-- A line of text, in as many pieces as it has colours in it: a game writes
-- core.colorize() into a HUD line and Luanti draws each piece in its own
-- colour. One piece is the common case and is one Text like any other.
--
-- simplified: the style field -- bold, italic, monospace -- is not read.
-- Everything here is drawn in the one monospace font the client has, and
-- bold and italic want font files it does not ship.
local function draw_hud_text(e)
	local base = hud_colour(e.number)
	local block = hud_root:CreateChild("UIElement")
	local w, h = 0, 0
	for line in (tostring(e.text or "") .. "\n"):gmatch("([^\n]*)\n") do
		local lw, lh = draw_text_line(block, line, 0, h, base, 15)
		w = math.max(w, lw)
		h = h + (lh > 0 and lh or 15)
	end
	block.size = magic.IntVector2(math.floor(w), math.floor(h))
	hud_place(block, e, w, h)
end

local function draw_hud_image(e)
	local resource = luanti.texture(e.text or "")
	local tex = resource and game_texture(resource)
	if not tex then
		if not hud_missing[e.text or ""] then
			hud_missing[e.text or ""] = true
			log:info("the game's HUD wants an image called \"" ..
					tostring(e.text) .. "\", which is not there")
		end
		return
	end
	local sx, sy = parse_v2(e.scale, 1, 1)
	local scale = hud_scale()
	-- A negative scale is a fraction of the screen rather than of the image,
	-- which is how Luanti's own scale works; a positive one is the picture
	-- at so many of Luanti's screen pixels per pixel of its own
	local w = sx < 0 and (-sx * 0.01 * magic.ui.root.width) or
			(tex.width * sx * scale)
	local h = sy < 0 and (-sy * 0.01 * magic.ui.root.height) or
			(tex.height * sy * scale)
	local img = hud_root:CreateChild("BorderImage")
	img.texture = tex
	img.size = magic.IntVector2(math.floor(w), math.floor(h))
	hud_place(img, e, w, h)
end

-- A row of the player's own inventory, which is what a game that draws its
-- own hotbar puts on the HUD: the list is the player's, number is how many
-- of its slots to draw and item is the one to mark. The slots look like the
-- client's own hotbar, because they are the same thing.
local function draw_hud_inventory(e)
	local list_name = e.text or ""
	local stacks = luanti.inventory and luanti.inventory[list_name]
	if stacks == nil then
		if not hud_missing["inv:" .. list_name] then
			hud_missing["inv:" .. list_name] = true
			log:info("the game's HUD wants the inventory list \"" ..
					list_name .. "\", which this player has not got")
		end
		return
	end
	local n = math.floor(tonumber(e.number) or #stacks)
	if n > #stacks then
		n = #stacks
	end
	if n <= 0 then
		return
	end
	-- Luanti's drawItems() draws this with the hotbar's own numbers and
	-- does not read the element's size, so the slots are the same squares
	-- the client's own hotbar is made of
	local imagesize, padding, slot = hotbar_metrics()
	local selected = math.floor(tonumber(e.item) or 0)
	-- Luanti's dir: 0 right, 1 left, 2 down, 3 up
	local dir = math.floor(tonumber(e.dir) or 0)
	local white = game_texture(WHITE)
	local row = hud_root:CreateChild("UIElement")
	for i = 1, n do
		local name, count = parse_stack(stacks[i])
		local frame = row:CreateChild("BorderImage")
		if white then
			frame.texture = white
		end
		frame.color = (i == selected) and
				magic.Color(0.9, 0.9, 0.7, 0.75) or
				magic.Color(0.1, 0.1, 0.12, 0.55)
		frame.size = magic.IntVector2(slot, slot)
		-- A row that runs the other way is the same row of squares with
		-- the slots in the other order, which is what drawItems() does:
		-- the element is where it is and the direction is inside it
		local at = ((dir == 1 or dir == 3) and (n - i) or (i - 1)) * slot
		if dir == 2 or dir == 3 then
			frame:SetPosition(0, at)
		else
			frame:SetPosition(at, 0)
		end
		local tex = name and game_texture(luanti.item_texture(name))
		if tex then
			local image = frame:CreateChild("BorderImage")
			image.texture = tex
			image:SetPosition(padding, padding)
			image.size = magic.IntVector2(imagesize, imagesize)
		end
		if count and count > 1 then
			local t = frame:CreateChild("Text")
			t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 12)
			t:SetTextEffect(magic.TE_SHADOW)
			t.effectColor = magic.Color(0, 0, 0, 0.9)
			t.horizontalAlignment = magic.HA_RIGHT
			t.verticalAlignment = magic.VA_BOTTOM
			t:SetPosition(-3, -2)
			t:SetText(tostring(count))
		end
	end
	local w = (dir <= 1) and (n * slot) or slot
	local h = (dir <= 1) and slot or (n * slot)
	row.size = magic.IntVector2(w, h)
	hud_place(row, e, w, h)
end

-- Where a waypoint's own element goes: the place on the screen its world
-- position is at, plus the offset, with the alignment saying which corner of
-- it lands there. The same as hud_place() but for pos, which a waypoint does
-- not have.
-- The same placement over a point in the world rather than a point on the
-- screen; see hud_place() for what align does.
local function hud_place_at(element, e, w, h, sx, sy)
	local ox, oy = parse_v2(e.offset, 0, 0)
	local ax, ay = parse_v2(e.align, 0, 0)
	element:SetPosition(
			math.floor(sx + ox + (ax - 1) * 0.5 * w),
			math.floor(sy + oy + (ay - 1) * 0.5 * h))
end

-- A label over a place in the world, with how far away it is. Luanti keeps
-- the precision in the item field -- item is precision + 1, and zero means
-- ten -- and text is the unit the distance is written in.
local function waypoint_text(e)
	local text = luanti.strip_escapes(e.name or "")
	local item = math.floor(tonumber(e.item) or 0)
	local precision = (item == 0) and 10 or (item - 1)
	if precision <= 0 then
		return text
	end
	local wx, wy, wz = parse_v3(e.world_pos)
	local eye = camera_node.position
	local dx, dy, dz = wx - eye.x, wy - eye.y, wz - eye.z
	local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
	local decimals = math.max(0,
			math.ceil(math.log(precision) / math.log(10)))
	return text .. string.format("%." .. decimals .. "f",
			math.floor(distance * precision) / precision) .. (e.text or "")
end

local function draw_hud_waypoint(e)
	if parse_v3(e.world_pos) == nil then
		return
	end
	local t = hud_root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	t:SetTextEffect(magic.TE_SHADOW)
	t.effectColor = magic.Color(0, 0, 0, 0.85)
	t.color = hud_colour(e.number)
	hud_waypoints[#hud_waypoints + 1] = {element = t, e = e, text = true}
end

-- The same place in the world, with a picture on it instead of a label
local function draw_hud_image_waypoint(e)
	if parse_v3(e.world_pos) == nil then
		return
	end
	local resource = luanti.texture(e.text or "")
	local tex = resource and game_texture(resource)
	if not tex then
		return
	end
	local scx, scy = parse_v2(e.scale, 1, 1)
	local w, h = tex.width * scx, tex.height * scy
	local img = hud_root:CreateChild("BorderImage")
	img.texture = tex
	img.size = magic.IntVector2(math.floor(w), math.floor(h))
	hud_waypoints[#hud_waypoints + 1] = {element = img, e = e, w = w, h = h}
end

-- Luanti's compass: a picture that turns with the player, or a strip that
-- scrolls past. dir says which -- 0 turns, 1 turns the other way, 2 scrolls,
-- 3 scrolls the other way -- and number is an angle added to the camera's.
--
-- The strip is drawn as the copies of itself that fall inside the element,
-- each cut to what shows: Urho3D's UI clips nothing by itself, and a copy
-- that hangs out of the element would be drawn over whatever is beside it.
local function draw_hud_compass(e)
	local resource = luanti.texture(e.text or "")
	local tex = resource and game_texture(resource)
	if not tex then
		return
	end
	local w, h = parse_v2(e.size, 0, 0)
	-- A negative size is a percentage of the screen, as an image's scale is
	if w < 0 then
		w = -w * 0.01 * magic.ui.root.width
	end
	if h < 0 then
		h = -h * 0.01 * magic.ui.root.height
	end
	w, h = math.floor(w), math.floor(h)
	if w <= 0 or h <= 0 then
		return
	end
	local block = hud_root:CreateChild("UIElement")
	block.size = magic.IntVector2(w, h)
	local dir = math.floor(tonumber(e.dir) or 0)
	local turning = (dir == 0 or dir == 1)
	local piece = nil
	if turning then
		-- A Sprite turns about its hot spot and is drawn with that point
		-- where it sits, so it hangs under an element at the middle of this
		-- one with its own middle as the hot spot
		local holder = block:CreateChild("UIElement")
		holder:SetPosition(math.floor(w / 2), math.floor(h / 2))
		piece = holder:CreateChild("Sprite")
		piece:SetTexture(tex)
		piece:SetFixedSize(w, h)
		piece.hotSpot = magic.IntVector2(math.floor(w / 2), math.floor(h / 2))
	end
	hud_place(block, e, w, h)
	hud_compasses[#hud_compasses + 1] = {block = block, sprite = piece,
			e = e, tex = tex, w = w, h = h, dir = dir}
end

-- Luanti's minimap element: the world around the player, from above.
-- Urho3D's View3D is what makes one possible at all -- a UI element that
-- renders a scene into a texture of its own size -- and what it renders is
-- the world itself rather than a picture built out of what the client
-- knows: an orthographic camera over the player, looking down, on the scene
-- that is already there.
--
-- simplified: north is up and the zoom is fixed, which is Luanti's surface
-- mode without its rotation. Its radar mode is a slice at the player's own
-- height, which is this camera's near and far clip and nothing else, and
-- nothing has asked for it.
local MINIMAP_HZ = 4
-- How much of the world is in it, top to bottom
local MINIMAP_NODES = 64
-- How far over the player the camera sits, which is what it can see down
-- through: a player under a mountain sees the mountain
local MINIMAP_HEIGHT = 120
local minimaps = {}
local minimap_timer = 0

local function draw_hud_minimap(e)
	-- A game that has turned the minimap off does not get one from its own
	-- element either, which is Luanti's rule for this kind
	if not luanti.hud_flag("minimap") then
		return
	end
	local w, h = parse_v2(e.size, 128, 128)
	-- A negative size is a percentage of the screen, as a compass's is;
	-- a positive one is in Luanti's screen pixels
	if w < 0 then
		w = -w * 0.01 * magic.ui.root.width
	else
		w = w * hud_scale()
	end
	if h < 0 then
		h = -h * 0.01 * magic.ui.root.height
	else
		h = h * hud_scale()
	end
	w, h = math.floor(w), math.floor(h)
	if w <= 0 or h <= 0 then
		return
	end
	local view = hud_root:CreateChild("View3D")
	view.size = magic.IntVector2(w, h)
	-- A picture of the world costs a second pass over the world, so it is
	-- drawn a few times a second rather than every frame
	view.autoUpdate = false
	local node = scene:CreateChild("minimap_camera")
	local cam = node:CreateComponent("Camera")
	cam.orthographic = true
	cam.orthoSize = MINIMAP_NODES
	cam.nearClip = 0.5
	cam.farClip = MINIMAP_HEIGHT * 4
	node.direction = magic.Vector3(0, -1, 0)
	-- Not the element's own scene: this one is the world's and has to
	-- outlive every form and HUD there is
	view:SetView(scene, cam, false)
	-- And drawn the way the world is drawn: the window's own render path
	-- carries the tonemap, and an HDR scene without it is white
	if world_render_path then
		view:GetViewport().renderPath = world_render_path:Clone()
	end
	hud_place(view, e, w, h)
	minimaps[#minimaps + 1] = {view = view, camera = node}
end

-- Over the player, and drawn again a few times a second
local function follow_minimaps(dt)
	if #minimaps == 0 then
		return
	end
	local p = camera_node.worldPosition
	for _, m in ipairs(minimaps) do
		m.camera.position = magic.Vector3(p.x, p.y + MINIMAP_HEIGHT, p.z)
	end
	minimap_timer = minimap_timer + dt
	if minimap_timer < 1 / MINIMAP_HZ then
		return
	end
	minimap_timer = 0
	for _, m in ipairs(minimaps) do
		m.view:QueueUpdate()
	end
end

-- Where every compass is pointing now. Once a frame, like a waypoint: what
-- moves is the player.
local function turn_compasses()
	for _, c in ipairs(hud_compasses) do
		-- Luanti's own: the camera's horizontal angle, the other way round,
		-- plus what the game asked for
		local angle = (-yaw + (tonumber(c.e.number) or 0)) % 360
		if c.dir == 1 or c.dir == 3 then
			angle = (360 - angle) % 360
		end
		if c.sprite then
			c.sprite.rotation = angle
		else
			-- The strip: as wide as the picture is at this height, scrolled
			-- by the angle and repeated until the element is covered
			local sw = math.floor(c.h * tex_aspect(c.tex))
			c.block:RemoveAllChildren()
			local x = -math.floor(angle * sw / 360)
			while x > 0 do
				x = x - sw
			end
			while x < c.w do
				local left = math.max(0, -x)
				local right = math.min(sw, c.w - x)
				if right > left then
					local img = c.block:CreateChild("BorderImage")
					img.texture = c.tex
					img.size = magic.IntVector2(right - left, c.h)
					img:SetPosition(x + left, 0)
					-- The part of the picture that shows, in its own pixels
					img.imageRect = magic.IntRect(
							math.floor(left * c.tex.width / sw), 0,
							math.floor(right * c.tex.width / sw),
							c.tex.height)
				end
				x = x + sw
			end
		end
	end
end

-- Where every waypoint is now. Once a frame, because what moves is the
-- player: the game changes the element only when it has something new to
-- say, and the distance in a waypoint's label changes with every step.
local function place_waypoints()
	for _, w in ipairs(hud_waypoints) do
		local wx, wy, wz = parse_v3(w.e.world_pos)
		local sx, sy = nil, nil
		if wx ~= nil then
			sx, sy = screen_of(wx, wy, wz)
		end
		if sx == nil then
			w.element.visible = false
		else
			w.element.visible = true
			if w.text then
				w.element:SetText(waypoint_text(w.e))
				hud_place_at(w.element, w.e, w.element.width,
						w.element.height, sx, sy)
			else
				hud_place_at(w.element, w.e, w.w, w.h, sx, sy)
			end
		end
	end
end

-- A row of icons, each one either whole or half: hearts, bubbles, a bar of
-- armour. number is the value in halves and item is how many halves the bar
-- holds; text2 is the icon a game draws for what is missing.
local function draw_hud_statbar(e)
	local resource = luanti.texture(e.text or "")
	local tex = resource and game_texture(resource)
	if not tex then
		return
	end
	local value = math.floor(tonumber(e.number) or 0)
	local total = math.floor(tonumber(e.item) or value)
	local sw, sh = parse_v2(e.size, 0, 0)
	local scale = hud_scale()
	local w = (sw > 0 and sw or tex.width) * scale
	local h = (sh > 0 and sh or tex.height) * scale
	-- Luanti's dir: 0 right, 1 left, 2 down, 3 up
	local dir = math.floor(tonumber(e.dir) or 0)
	-- What a square that has been lost wears, if the game gave one
	local bg = nil
	if e.text2 ~= nil and e.text2 ~= "" then
		bg = game_texture(luanti.texture(e.text2))
		if bg == nil and not hud_missing[e.text2] then
			hud_missing[e.text2] = true
			log:info("the game's HUD wants a picture called \"" ..
					tostring(e.text2) .. "\" for what a bar has lost, " ..
					"which is not there")
		end
	end
	local whole = math.floor(total / 2)
	local row = hud_root:CreateChild("UIElement")
	-- Where the i'th square of the row sits, which is where drawStatbar()
	-- has stepped to by then
	local function square(i)
		local step = i - 1
		if dir == 1 then return -step * w, 0 end
		if dir == 2 then return 0, step * h end
		if dir == 3 then return 0, -step * h end
		return step * w, 0
	end
	-- A square of the row: the whole picture, or the half of it the bar
	-- runs out of (near) or into (far). Luanti cuts both the picture and
	-- the square across the way the bar runs, so the half that is left
	-- keeps its own side and what is gone is drawn in the other half.
	local function piece(tex_i, i, near)
		if tex_i == nil then
			return
		end
		local x, y = square(i)
		local iw, ih = w, h
		local rx, ry = 0, 0
		local rw, rh = tex_i.width, tex_i.height
		if near ~= nil then
			-- Whether this half is the one at the lower coordinate: the
			-- near half of a row running right is its left half, and of
			-- one running left its right half
			local low = (near == (dir == 0 or dir == 2))
			if dir <= 1 then
				iw, rw = w / 2, math.floor(tex_i.width / 2)
				if not low then
					x, rx = x + w / 2, math.floor(tex_i.width / 2)
				end
			else
				ih, rh = h / 2, math.floor(tex_i.height / 2)
				if not low then
					y, ry = y + h / 2, math.floor(tex_i.height / 2)
				end
			end
		end
		local icon = row:CreateChild("BorderImage")
		icon.texture = tex_i
		icon.size = magic.IntVector2(math.floor(iw), math.floor(ih))
		if near ~= nil then
			icon.imageRect = magic.IntRect(rx, ry, rx + rw, ry + rh)
		end
		icon:SetPosition(math.floor(x), math.floor(y))
	end
	-- simplified: a bar whose whole length is an odd number of halves ends
	-- in a half square, which is not drawn here. Luanti draws it; every bar
	-- there is asks for an even length.
	for i = 1, whole do
		if value >= i * 2 then
			piece(tex, i, nil)
		elseif value == i * 2 - 1 then
			piece(tex, i, true)
			piece(bg, i, false)
		else
			piece(bg, i, nil)
		end
	end
	local total_w = (dir <= 1) and whole * w or w
	local total_h = (dir <= 1) and h or whole * h
	row.size = magic.IntVector2(math.floor(total_w), math.floor(total_h))
	-- **A statbar is the one kind align is not read for**: Luanti's
	-- drawStatbar() is given the element's pos and offset and nothing else,
	-- and a game that asks for one alignment or another gets the row in the
	-- same place either way. A size of zero here is what takes align out of
	-- hud_place()'s arithmetic. VoxeLibre asks for -1 on the row left of
	-- the middle, which slid its hearts a whole row further left.
	hud_place(row, e, 0, 0)
end

-- What the game last sent, so that the HUD can be drawn again when
-- something it is about -- the player's own inventory -- has changed
local hud_elements = {}
local hud_has_inventory = false

local function draw_hud(elements, flags)
	hud_elements = elements
	hud_has_inventory = false
	hud_root:RemoveAllChildren()
	hud_waypoints = {}
	hud_compasses = {}
	-- The elements go with the HUD; the cameras they put in the world are
	-- this one's to take away
	for _, m in ipairs(minimaps) do
		m.camera:Remove()
	end
	minimaps = {}
	-- As big as the screen, because an element aligned to the centre or the
	-- bottom is aligned inside this and an element of no size puts every
	-- one of them in the top left corner
	hud_root.size = magic.IntVector2(magic.ui.root.width,
			magic.ui.root.height)
	-- The health and the breath are the game's to draw and not the client's:
	-- Luanti's own builtin puts hearts and bubbles on the screen as statbar
	-- elements out of the engine's textures, which are served now, and a
	-- game that wants something else of its own replaces them. A bar drawn
	-- here as well was a second one under the hearts.
	--
	-- The game can take the client's own away, and what it draws instead is
	-- these elements; see luanti.hud_flag()
	hud_root.visible = hud_shown
	crosshair.visible = hud_shown and luanti.hud_flag("crosshair")
	chat_block.visible = chat_shown and luanti.hud_flag("chat")
	hotbar_shown = hud_shown and luanti.hud_flag("hotbar")
	draw_hotbar()
	wielded_text.visible = hotbar_shown
	for id, e in pairs(elements) do
		local kind = e.type or "text"
		if kind == "text" then
			draw_hud_text(e)
		elseif kind == "image" then
			draw_hud_image(e)
		elseif kind == "statbar" then
			draw_hud_statbar(e)
		elseif kind == "compass" then
			draw_hud_compass(e)
		elseif kind == "minimap" then
			draw_hud_minimap(e)
		elseif kind == "inventory" then
			hud_has_inventory = true
			draw_hud_inventory(e)
		elseif kind == "waypoint" then
			draw_hud_waypoint(e)
		elseif kind == "image_waypoint" then
			draw_hud_image_waypoint(e)
		elseif not hud_missing[kind] then
			hud_missing[kind] = true
			log:info("the game asked for a \"" .. kind ..
					"\" HUD element, which is not drawn")
		end
	end
end

luanti.sub_hud(draw_hud)

-- The game's set_lighting(): shadows.intensity is how dark a shadow is,
-- 1 being black, and Urho's shadowIntensity is the other way round -- how
-- much light a shadow keeps. Luanti's own default is 0 and VoxeLibre asks
-- for 0.33. The saturation is carried and not drawn: it wants a colour
-- grade on the render path, which is [PBR_LEVEL]'s tonemap to settle.
luanti.sub_hud(function()
	local l = luanti.lighting
	if not l or not sky_lights.sun then
		return
	end
	-- On the parity modes only. On pbr a shadow is what the sun does not
	-- reach, lit by the sky alone, which is what the path trace draws;
	-- VoxeLibre's 0.33 kept two thirds of the sun in every shadow and
	-- was the whole of the snow contrast's shortfall (1.2 against the
	-- render's 5.2) -- a Luanti-ism, [PBR_FIT] and [PBR_TARGET].
	local keep = 1 - math.max(0, math.min(1, l.shadow_intensity))
	if not sky_now.unlit then
		keep = 0
	end
	if sky_lights.shadow_keep ~= keep then
		sky_lights.shadow_keep = keep
		sky_lights.sun.shadowIntensity = keep
		if sky_lights.moon then
			sky_lights.moon.shadowIntensity = keep
		end
		log:info(string.format("set_lighting: shadows keep %.2f, " ..
				"saturation %.2f (not drawn)", keep, l.saturation))
	end
end)

hud_follows_inventory = function()
	if hud_has_inventory then
		draw_hud(hud_elements)
	end
end

--
-- The pause menu, and the keys that hide things
--
-- Escape used to disconnect, which is a key nobody was told about doing the
-- one thing that cannot be undone. What it opens is a form of the client's
-- own -- the game is told nothing about it -- drawn by the same renderer a
-- server's forms go through.

local function pause_spec()
	-- Continuing is the first thing on it and the first thing a player
	-- wants: escape does the same, but a menu whose only way back is a key
	-- nobody was told about is a menu that traps people. button_exit closes
	-- the form by itself, which is what continuing is.
	--
	-- simplified: no sound here. The extension's menu mutes the sound, and
	-- what that would be is the user's own sound preference, which a game's
	-- client Lua is deliberately not allowed to write -- see "Client
	-- preferences" in doc/client_api.txt. Nothing here makes a noise yet
	-- either.
	return "size[6,4.7]" ..
			"label[0.2,0.2;Paused]" ..
			"button_exit[0.4,1.0;5.2,0.8;continue;Continue playing]" ..
			"button[0.4,2.1;5.2,0.8;keys;Key bindings]" ..
			"button[0.4,3.2;5.2,0.8;leave;Leave the game]"
end

-- Every binding, in two columns, out of the same table the code reads, so a
-- key cannot be in the code and missing from the list. A label's text is
-- split on commas and semicolons by the formspec grammar, so BINDINGS keeps
-- them out.
local function keys_spec()
	local half = math.ceil(#BINDINGS / 2)
	local out = {"size[12," .. tostring(1.5 + half * 0.6) .. "]",
			"label[0.2,0.2;Key bindings]"}
	for i, b in ipairs(BINDINGS) do
		local first = i <= half
		local x = first and 0.3 or 6.2
		local row = first and (i - 1) or (i - half - 1)
		local y = 0.9 + row * 0.6
		out[#out + 1] = "label[" .. x .. "," .. y .. ";" .. b.name .. "]"
		out[#out + 1] = "label[" .. (x + 1.8) .. "," .. y .. ";" ..
				b.what .. "]"
	end
	out[#out + 1] = "button[4.8," .. tostring(0.7 + half * 0.6) ..
			";2.4,0.8;back;Back]"
	return table.concat(out)
end

local menu_fields

menu_fields = function(fields)
	if fields.keys then
		luanti.show_local_form(keys_spec(), menu_fields)
	elseif fields.back then
		luanti.show_local_form(pause_spec(), menu_fields)
	elseif fields.leave then
		buildat.disconnect()
	end
end

local function open_pause_menu()
	luanti.show_local_form(pause_spec(), menu_fields)
end

--
-- Pointing at a node, and digging it
--
-- The ray is marched here because the camera is here; what the node it hits
-- means is the server's, and core.dig_node() is what it comes to. A voxel
-- is something to point at when it is not the void (id 0) and something
-- stands in it, which is what fully_empty says.

local POINT_RANGE = 12
local POINT_STEP = 0.1

local pointed_p = nil
local pointed_above = nil
local pointed_node = scene:CreateChild("pointed")
do
	-- Four thin strips around the top face, drawn on every face of the
	-- voxel by the six turns below: a wireframe box, the way games/digger
	-- draws one
	local geometry = pointed_node:CreateComponent("CustomGeometry")
	geometry:BeginGeometry(0, magic.TRIANGLE_LIST)
	geometry:SetNumGeometries(1)
	local c = magic.Color(0.10, 0.10, 0.10)
	local function quad(a, b, cc, d)
		for _, v in ipairs({a, b, cc, cc, d, a}) do
			geometry:DefineVertex(v)
			geometry:DefineColor(c)
		end
	end
	local o = 0.504    -- Just outside the voxel, so it does not z-fight
	local t = 1.0 / 16 -- How thick a strip is
	-- One face's four strips, turned onto each of the six faces
	local function face(turn)
		local function v(x, y, z)
			return magic.Vector3(turn(x, y, z))
		end
		quad(v(-o, o, o - t), v(o, o, o - t), v(o, o, o), v(-o, o, o))
		quad(v(-o, o, -o), v(o, o, -o), v(o, o, -o + t), v(-o, o, -o + t))
		quad(v(o - t, o, -o + t), v(o, o, -o + t), v(o, o, o - t),
				v(o - t, o, o - t))
		quad(v(-o, o, -o + t), v(-o + t, o, -o + t), v(-o + t, o, o - t),
				v(-o, o, o - t))
	end
	face(function(x, y, z) return x, y, z end)
	face(function(x, y, z) return x, -y, -z end)
	face(function(x, y, z) return y, x, z end)
	face(function(x, y, z) return -y, -x, z end)
	face(function(x, y, z) return x, z, y end)
	face(function(x, y, z) return x, -z, -y end)
	geometry:Commit()
	local material = magic.Material.new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVColMultiply.xml"))
	geometry:SetMaterial(0, material)
	pointed_node.enabled = false
end

-- A voxel is something to point at when it is not the void and something
-- stands in it. Which type it is has to be asked of the registry: a
-- VoxelInstance's own id is the legacy layout of the word, and this world
-- says otherwise -- Luanti's id is sixteen bits with the light above it.
local function voxel_is_solid(v)
	if v == nil then
		return false
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return false
	end
	local def = reg:get_by_id(id)
	return def ~= nil and not def.fully_empty
end

-- The voxel the ray hit, and the last empty one before it -- which is where
-- a node is placed and what Luanti calls the "above" of a pointed thing.
-- How far it reaches is what the player is holding reaches: Luanti's
-- getToolRange(), which luanti.dig_range() answers, bounded by what this
-- march can afford.
local function find_pointed_voxel()
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last = nil
	local range = math.min(POINT_RANGE, luanti.dig_range(wield_index))
	for i = 1, math.floor(range / POINT_STEP) do
		local p = (p0 + dir * (i * POINT_STEP)):round()
		if p ~= last then
			if voxel_is_solid(voxelworld.get_static_voxel(p)) then
				return p, last or p
			end
			last = p
		end
	end
	return nil, nil
end

-- What the node at a voxel is called, which is what luanti.dig_time() wants:
-- the voxel definition's own name is the node's name, because that is what
-- built the registry
local function node_name_at(p)
	local v = voxelworld.get_static_voxel(p)
	if v == nil then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(v)
	if id == 0 then
		return nil
	end
	local def = reg:get_by_id(id)
	return def and def.name.block_name or nil
end

-- `event scan <resolution> <label>` ([SCAN_EVENT]) lives in scan.lua and
-- is handed what it reads of this file's state as functions, this file
-- being at Lua's 200 locals
(function(ok, err, install)
	if not ok or type(install) ~= "function" then
		error("luanti_launcher: could not load scan.lua: " .. tostring(err))
	end
	return install
end)(buildat.run_script_file("main/scan.lua"))({
	camera_node = function() return camera_node end,
	view = function() return yaw, pitch, (camera and camera.fov) or CAMERA_FOV end,
	pointed = find_pointed_voxel,
	node_name_at = node_name_at,
	voxel_is_solid = voxel_is_solid,
	dig_range = function() return math.min(POINT_RANGE, luanti.dig_range(wield_index)) end,
	chat_text = function() return chat_input and chat_input:GetText() end,
	hud_rect = function(e)
		local el = e.__placed
		if not el then
			return nil
		end
		local at = el.screenPosition
		return at.x, at.y, el.width, el.height
	end,
	player_pos = function() return player.x, player.y, player.z end,
	wield = function() return hotbar_stacks[wield_index] end,
	hotbar = function() return hotbar_stacks end,
	log = log,
})

local function voxel_packet_value(p)
	return {
		x = math.floor(p.x + 0.5),
		y = math.floor(p.y + 0.5),
		z = math.floor(p.z + 0.5),
	}
end

local VOXEL_PACKET_TYPE = {"object",
	{"x", "int32_t"},
	{"y", "int32_t"},
	{"z", "int32_t"},
}

--
-- The dig, which is held rather than clicked
--
-- Luanti times a dig on the client: how long the node takes is worked out
-- from its groups and what is in hand -- luanti.dig_time(), out of the dig
-- props -- and the server hears the punch on the way in and the dig when
-- the time is up. The server digs the node itself and checks again, so a
-- client that says a dig took no time gets nothing for it.

-- A frame of the crack strip, as a resource name: Luanti's own
-- crack_anylength.png, cut into frames by the same [verticalframe an
-- animated tile uses. "anylength" is the promise that how many frames it
-- holds is the picture's own shape rather than a number written down.
local CRACK_FRAMES_DEFAULT = 5
local crack_frames = nil
local crack_resource = {}

local function crack_frame_count()
	if crack_frames then
		return crack_frames
	end
	crack_frames = CRACK_FRAMES_DEFAULT
	local resource = luanti.texture("crack_anylength.png")
	local tex = resource and
			magic.cache:GetResource("Texture2D", resource) or nil
	-- A strip of square frames, so how many there are is its shape
	if tex and tex.width > 0 and tex.height > tex.width then
		crack_frames = math.floor(tex.height / tex.width)
	end
	return crack_frames
end

local function crack_texture(index)
	local resource = crack_resource[index]
	if resource == nil then
		resource = luanti.texture("crack_anylength.png^[verticalframe:" ..
				crack_frame_count() .. ":" .. index) or false
		crack_resource[index] = resource
	end
	return resource or nil
end

-- The crack itself: a cube just outside the voxel wearing one frame.
--
-- One node per frame, enabled one at a time, rather than one node whose
-- material is swapped: a Material lives only as long as something in the
-- engine holds it, and a StaticModel that has been handed one is such a
-- thing -- keeping materials in a Lua table and putting them back later
-- reads the freed one.
--
-- simplified: the crack on a stair or a torch is a cube around it, because
-- it is a cube and not the node's own shape wearing a second layer. The
-- faithful way is a voxel type per (definition, frame), which is five more
-- per definition on top of VoxeLibre's several thousand.
local crack_nodes = {}
local crack_worn = nil

local function crack_node_for(resource)
	local node = crack_nodes[resource]
	if node then
		return node
	end
	node = scene:CreateChild("crack")
	local model = node:CreateComponent("StaticModel")
	model.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	local material = magic.Material.new()
	material:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/DiffUnlitAlpha.xml"))
	local texture = magic.cache:GetResource("Texture2D", resource)
	if texture then
		texture.filterMode = magic.FILTER_NEAREST
		material:SetTexture(0, texture)
	end
	model.material = material
	-- Just outside the voxel, so the crack does not fight the face it
	-- covers for the depth buffer
	node.scale = magic.Vector3(1.004, 1.004, 1.004)
	node.enabled = false
	crack_nodes[resource] = node
	return node
end

local function set_crack(p, resource)
	if crack_worn and crack_worn ~= resource then
		crack_nodes[crack_worn].enabled = false
		crack_worn = nil
	end
	if p == nil or resource == nil then
		return
	end
	local node = crack_node_for(resource)
	node.position = magic.Vector3.from_buildat(p)
	node.enabled = true
	crack_worn = resource
end

-- What is being dug: {p =, name =, time =, elapsed =, done =}. time is nil
-- when what is held cannot dig this at all, and then nothing is ever sent.
local dig = nil

local function update_crack()
	if dig == nil or dig.time == nil or dig.time <= 0 or dig.done then
		set_crack(nil, nil)
		return
	end
	local frames = crack_frame_count()
	local index = math.floor(dig.elapsed / dig.time * frames)
	if index < 0 then
		index = 0
	elseif index > frames - 1 then
		index = frames - 1
	end
	set_crack(dig.p, crack_texture(index))
end

local function dig_packet(name, p)
	buildat.send_packet(name, cereal.binary_output({
		p = voxel_packet_value(p),
	}, {"object", {"p", VOXEL_PACKET_TYPE}}))
	-- Which chunk the dug voxel is in, and which node draws it. The client
	-- says when a chunk that changed waits to be drawn again and names it by
	-- node id (see builtin/voxelworld's client half), and this is the line
	-- that matches a dig against those: a dug voxel whose chunk is among
	-- them waited its turn, and one that is not is a chunk nobody asked to
	-- redraw. See section 3 of doc/plan/master_plan.md.
	if name == "main:dig" then
		local chunk_p = voxelworld.get_chunk_position(
				buildat.Vector3(p.x, p.y, p.z))
		local node = voxelworld.get_static_node(chunk_p)
		log:info(string.format(
				"dug (%d, %d, %d) in chunk (%d, %d, %d), chunk node %s",
				p.x, p.y, p.z, chunk_p.x, chunk_p.y, chunk_p.z,
				node and tostring(node:GetID()) or "none"))
	end
end

-- An object is hit rather than dug: one hit per press, and no faster than
-- this while the button is held, which is Luanti's own object_hit_delay
local OBJECT_HIT_DELAY = 0.2
local hit_wait = 0

local function update_dig(dt, playing)
	local holding = playing and
			magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT)
	hit_wait = math.max(0, hit_wait - dt)
	if not holding then
		hit_wait = 0
	end
	-- What the ray runs into first: an object in front of the node is what
	-- is hit, and the reach is the same one a dig has
	if holding then
		local eye = camera_node.worldPosition
		local dir = camera_node.worldDirection
		local reach = math.min(POINT_RANGE, luanti.dig_range(wield_index))
		local id, distance = luanti.pointed_object(eye.x, eye.y, eye.z,
				dir.x, dir.y, dir.z, reach)
		if id and (pointed_p == nil or distance <
				(buildat.Vector3(eye.x, eye.y, eye.z) - pointed_p):length()) then
			dig = nil
			update_crack()
			if hit_wait <= 0 then
				hit_wait = OBJECT_HIT_DELAY
				buildat.send_packet("main:punch_object", cereal.binary_output(
						{tostring(id)}, {"array", "string"}))
			end
			return
		end
	end
	if not holding or pointed_p == nil then
		dig = nil
		update_crack()
		return
	end
	if dig == nil or dig.p ~= pointed_p then
		local name = node_name_at(pointed_p)
		dig = {
			p = pointed_p,
			name = name,
			time = name and luanti.dig_time(name, wield_index) or nil,
			elapsed = 0,
		}
		-- A mod's on_punch runs on the way in, whether or not the node can
		-- be dug at all
		log:debug("dig: " .. tostring(dig.name) .. " takes " ..
				tostring(dig.time) .. " s")
		dig_packet("main:dig_start", dig.p)
		update_crack()
		return
	end
	if dig.done then
		return
	end
	dig.elapsed = dig.elapsed + dt
	if dig.time and dig.elapsed >= dig.time then
		dig_packet("main:dig", dig.p)
		dig.done = true
	end
	update_crack()
end

magic.SubscribeToEvent("MouseButtonDown", function(event_type, event_data)
	local button = event_data:GetInt("Button")
	if button ~= magic.MOUSEB_LEFT and button ~= magic.MOUSEB_RIGHT then
		return
	end
	-- A form on the screen is clicked through UIMouseClick below, which is
	-- what says where the click landed; what is behind it is not what was
	-- clicked on
	if luanti.form_open() then
		return
	end
	if pointed_p == nil then
		return
	end
	-- The left button is the dig, and it is held rather than clicked:
	-- update_dig() above has it, because how long it takes is a timer
	if button == magic.MOUSEB_LEFT then
		return
	end
	-- The right button is Luanti's place-or-use: what it comes to is the
	-- node's on_rightclick if it has one and the wielded item's on_place
	-- otherwise, which is the server's to decide
	-- Shift is Luanti's sneak: held, it means build against the node rather
	-- than use it, which is the only way to put something on top of a chest
	buildat.send_packet("main:place", cereal.binary_output({
		under = voxel_packet_value(pointed_p),
		above = voxel_packet_value(pointed_above or pointed_p),
		sneak = (magic.input:GetKeyDown(magic.KEY_LSHIFT) or
				magic.input:GetKeyDown(magic.KEY_RSHIFT)) and 1 or 0,
	}, {"object",
		{"under", VOXEL_PACKET_TYPE},
		{"above", VOXEL_PACKET_TYPE},
		{"sneak", "byte"},
	}))
end)

-- The wheel picks a hotbar slot, which is what it does in Luanti
magic.SubscribeToEvent("MouseWheel", function(event_type, event_data)
	if luanti.form_open() or chat_input then
		return
	end
	set_wield(wield_index - event_data:GetInt("Wheel"))
end)

-- Where the mouse is, which a tooltip needs and GetMouseMove does not say:
-- that is the movement since the last frame. Input reports window pixels and
-- a form is laid out in the UI's own coordinates, which are those divided by
-- the UI scale -- the same ones a click arrives in.
magic.SubscribeToEvent("MouseMove", function(event_type, event_data)
	local scale = magic.ui:GetScale()
	if not scale or scale <= 0 then
		scale = 1
	end
	luanti.hover(math.floor(event_data:GetInt("X") / scale),
			math.floor(event_data:GetInt("Y") / scale))
end)

-- Where a click landed, which MouseButtonDown does not say. A form is the
-- only thing here that cares.
magic.SubscribeToEvent("UIMouseClick", function(event_type, event_data)
	if not luanti.form_open() then
		return
	end
	local button = event_data:GetInt("Button")
	luanti.click(event_data:GetInt("X"), event_data:GetInt("Y"),
			button == magic.MOUSEB_RIGHT and "right" or
			button == magic.MOUSEB_MIDDLE and "middle" or "left")
end)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	-- A form takes escape to close itself; what is left is this game's own
	-- While a line is being typed the keys are that line's, which is why
	-- this is before everything else
	if chat_input then
		if key == magic.KEY_RETURN or key == magic.KEY_KP_ENTER then
			send_chat()
		elseif key == BIND.menu.key then
			close_chat()
		end
		return
	end
	if luanti.key(key) then
		return
	end
	if key >= magic.KEY_1 and key <= magic.KEY_9 then
		-- A game with fewer slots than that has no slot for the key
		local i = key - magic.KEY_1 + 1
		if i <= ((luanti.hotbar and luanti.hotbar.count) or 8) then
			set_wield(i)
		end
	elseif key == BIND.chat.key then
		chat_wanted = true
	elseif key == BIND.mouse.key then
		set_mouse_in_world(not mouse_in_world)
	elseif key == BIND.drop.key then
		-- Luanti's own drop key: the whole stack, and one of it with the
		-- key that means "one" everywhere else here. The server takes it
		-- out of the inventory, so nothing is drawn until it says so.
		local one = magic.input:GetKeyDown(magic.KEY_LCTRL) or
				magic.input:GetKeyDown(magic.KEY_RCTRL)
		buildat.send_packet("main:drop", cereal.binary_output(
				{one and "1" or "0"}, {"array", "string"}))
		elseif key == BIND.inventory.key then
		-- Luanti's own inventory key, and what a game's inventory formspec
		-- is for. The same key closes it again. A game that sets no
		-- inventory formspec opens nothing, and the mouse stays in the
		-- world: nothing opened for it to point at.
		luanti.open_player_inventory()
	elseif key == BIND.fly.key then
		player.fly = not player.fly
		log:info(player.fly and "flying" or "walking")
	elseif key == BIND.noclip.key then
		player.noclip = not player.noclip
		log:info(player.noclip and "through walls" or "solid walls")
	elseif key == BIND.hud.key then
		hud_shown = not hud_shown
		draw_hud(hud_elements)
	elseif key == BIND.chatlog.key then
		chat_shown = not chat_shown
		draw_hud(hud_elements)
	elseif key == BIND.detail.key then
		-- Cycled rather than toggled, the way Luanti's own F5 is, and what a
		-- player coming from it expects: nothing, short, everything. See
		-- [STATUS_LEVELS].
		detail_level = (detail_level + 1) % 3
		detail_text.visible = detail_level > 0
		detail_timer = 1
		if detail_text.visible then
			-- In the log as well as on the screen, and the same string: a
			-- scripted comparison then reads text instead of reading a
			-- screenshot, which is the difference between a check that runs
			-- and a check somebody looks at
			-- Whole whatever the level is: this line exists for a scripted
			-- comparison rather than for the screen
			log:info(status_lines(2):gsub("\n", " | "))
		end
		place_chat()
	elseif key == BIND.menu.key then
		open_pause_menu()
	end
end)

-- Where the player is, a few times a second: the server moves its own player
-- there, and a Luanti mod asking where the player is gets this.
local WHERE_INTERVAL = 0.2
local where_timer = 0

-- What the player is holding down, in Luanti's own bit order --
-- PlayerControl::getKeysPressed(), and CONTROL_BITS in
-- builtin/luanti/lua/entity.lua, which reads these back out: up, down, left,
-- right, jump, aux1, sneak, dig, place, zoom.
--
-- Nothing sent this before, so get_player_control() answered twelve falses
-- forever and every sprint mod, aux1 ability and sneak-dependent behaviour
-- saw a player standing perfectly still -- without erroring, which is the
-- worst shape a gap can have.
--
-- aux1 is the fast key: in Luanti that is the same key and the same
-- meaning, and it is what a sprint mod reads. zoom has no binding here and
-- is never set.
local CONTROL_KEYS = {"forward", "back", "left", "right", "jump", "fast",
		"sneak"}
local CONTROL_DIG = 128
local CONTROL_PLACE = 256

local function control_bits()
	-- Nothing is held while the mouse is on the screen: a form is open, a
	-- line is being typed, or Tab put it there, and the keys are that
	-- window's rather than the player's
	if not mouse_in_world or luanti.form_open() or chat_input ~= nil then
		return 0
	end
	local bits = 0
	for i = 1, #CONTROL_KEYS do
		if key_down(CONTROL_KEYS[i]) then
			bits = bits + 2 ^ (i - 1)
		end
	end
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		bits = bits + CONTROL_DIG
	end
	if magic.input:GetMouseButtonDown(magic.MOUSEB_RIGHT) then
		bits = bits + CONTROL_PLACE
	end
	return bits
end

-- What went last, so that a key going down or up is sent on the frame it
-- happens rather than waiting out the heartbeat
local last_controls = -1

local function send_where()
	local p = {x = player.x, y = player.y, z = player.z}
	last_controls = control_bits()
	-- Luanti measures the horizontal angle counter-clockwise from +Z, so it
	-- turns towards -X where Urho's yaw turns towards +X; its vertical one
	-- is positive downwards, which is what Urho's pitch already is. See
	-- lua_api.md, get_look_horizontal and get_look_vertical.
	buildat.send_packet("main:where", cereal.binary_output({
		x = p.x, y = p.y, z = p.z,
		look_h = math.rad(-yaw),
		look_v = math.rad(pitch),
		controls = last_controls,
	}, {"object",
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
		{"look_h", "double"},
		{"look_v", "double"},
		{"controls", "int32_t"},
	}))
end

-- The frame, as a function of its own so the handler under it can time
-- it whichever of the returns it leaves by
function frame_peak.update(dt)
	local t0 = buildat.get_time_us()
	voxel_shading.update(dt)
	frame_peak.skyvis_us = buildat.get_time_us() - t0
	update_sky(dt)
	-- The exposure reset's rate goes back once its frame has rendered
	if AUTO_EXPOSURE.reset_frames > 0 then
		AUTO_EXPOSURE.reset_frames = AUTO_EXPOSURE.reset_frames - 1
		if AUTO_EXPOSURE.reset_frames == 0 then
			local vp = magic.renderer:GetViewport(0)
			if vp and vp.renderPath then
				vp.renderPath:SetShaderParameter("AutoExposureAdaptRate",
						AUTO_EXPOSURE.adapt_rate)
			end
		end
	end

	if player_placed then
		where_timer = where_timer + dt
		-- simplified: the keys are sampled, so a tap that begins and ends
		-- between two of these is not seen. Sending on change narrows that
		-- to the server's own 0.2 s coalescing of where packets, which is
		-- what would have to go next if a tap ever has to count.
		if where_timer >= WHERE_INTERVAL or control_bits() ~= last_controls then
			where_timer = 0
			send_where()
		end
	end

	pointed_p, pointed_above = find_pointed_voxel()
	if pointed_p then
		pointed_node.position = magic.Vector3.from_buildat(pointed_p)
		pointed_node.enabled = true
	else
		pointed_node.enabled = false
	end

	update_detail(dt)
	luanti.update_tooltip(dt)
	luanti.update_sounds(dt)
	luanti.update_particles(dt, magic.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))

	-- Until the server has said where the player is there is no player:
	-- what is on the screen is the overview the camera started at
	if not player_placed then
		return
	end

	if chat_wanted then
		chat_wanted = false
		open_chat()
	end

	-- The mouse turns the head while it is in the world; while it is on the
	-- screen -- a form is open, a line is being typed, or Tab put it there
	-- -- it is the pointer
	local playing = mouse_in_world and not luanti.form_open() and
			chat_input == nil
	if playing then
		local dmouse = magic.input:GetMouseMove()
		yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
		pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
		if pitch > 89 then pitch = 89 end
		if pitch < -89 then pitch = -89 end
	end

	-- What the keys ask for, in world coordinates: a direction of any
	-- length, which player.lua turns into a speed
	local wish = {x = 0, z = 0}
	if playing then
		local yr = math.rad(yaw)
		local fx, fz = math.sin(yr), math.cos(yr)
		local function walk(x, z)
			wish.x = wish.x + x
			wish.z = wish.z + z
		end
		if key_down("forward") then walk(fx, fz) end
		if key_down("back") then walk(-fx, -fz) end
		if key_down("right") then walk(fz, -fx) end
		if key_down("left") then walk(-fz, fx) end
		wish.jump = key_down("jump")
		wish.sneak = key_down("sneak")
		wish.fast = key_down("fast")
	end

	update_dig(dt, playing)

	player:update(dt, wish)

	-- A landing hard enough to hurt, told to the server, which is the end
	-- that decides what it costs. Luanti's own client does the same -- it
	-- computes the damage and sends that -- and this sends the speed
	-- instead, so that the arithmetic and the bounds are the server's.
	if player.landed_at then
		local speed = player.landed_at
		player.landed_at = nil
		if speed > FALL_TOLERANCE then
			buildat.send_packet("main:fell", cereal.binary_output(
					{speed = speed}, {"object", {"speed", "double"}}))
		end
	end

	camera_node.position = magic.Vector3(player.x + eye_offset.x,
			player.y + player_physics.EYE_HEIGHT + eye_offset.y,
			player.z + eye_offset.z)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	place_waypoints()
	turn_compasses()
	follow_minimaps(dt)
	update_underwater(buildat.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))
end
magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	frame_peak.note(dt)
	local t0 = buildat.get_time_us()
	frame_peak.update(dt)
	-- The script's own share: the handler less the two phases timed inside
	frame_peak.script_us = buildat.get_time_us() - t0 -
			frame_peak.skyvis_us - sky_cube.us
end)

log:info("luanti_launcher client ready")
-- vim: set noet ts=4 sw=4:
