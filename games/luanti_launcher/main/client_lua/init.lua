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
voxelworld.physics_distance = 1
voxelworld.use_skylight = true

-- A Luanti world's light value says how much sky reaches a voxel, so that is
-- what says whether the sun reaches a surface: without this the sun lights
-- the walls of a cave it cannot see into, because a shadow map cannot tell
-- a cave from a canopy. See use_sun_gate() in builtin/voxel_shading.
voxel_shading.use_sun_gate(true)

-- Luanti's origin is where its mods build, so that is what the camera frames
local LOOK_AT = {x = 0, y = 2, z = 0}
local CAMERA_DISTANCE = 34
local CAMERA_FOV = 45
local FAR_CLIP = 400
local VIEW_DIR = {x = -0.7, y = -0.55, z = -0.7}

local MOUSE_SENSITIVITY = 0.15

-- The player's own physics, which knows neither the protocol nor Urho3D:
-- see the header of player.lua
local ok_player, err_player, player_physics =
		buildat.run_script_file("main/player.lua")
if not ok_player or type(player_physics) ~= "table" then
	error("luanti_launcher: could not load player.lua: " .. tostring(err_player))
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
	{action = "hotbar", first = magic.KEY_1, last = magic.KEY_8,
			name = "1 - 8", what = "Pick a hotbar slot"},
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
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
local NIGHT_AMBIENT = magic.Color(0.05, 0.06, 0.10)
local SUN_BRIGHTNESS = 50.0
local MOON_BRIGHTNESS = 4.0
local SUN_COLOR = magic.Color(1.0, 0.96, 0.88)
local MOON_COLOR = magic.Color(0.55, 0.65, 1.0)
-- Reassigned when a game says what its horizon is; see sub_sky below
local DAY_FOG = magic.Color(0.60, 0.72, 0.88)
local NIGHT_FOG = magic.Color(0.05, 0.07, 0.12)
local SUN_DIR = {x = -0.6, y = -1.0, z = 0.8}
local EXPOSURE_BIAS = 1.6

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

local yaw, pitch = angles_from_dir(VIEW_DIR)
-- Whether the mouse turns the player's head or points at the screen. In the
-- world while playing, on the screen while a form is open or Tab says so.
local mouse_in_world = false

local function set_mouse_in_world(enable)
	mouse_in_world = enable
	magic.input:SetMouseVisible(not enable)
end

local zone = nil
local sun_light = nil

do
	local zone_node = scene:CreateChild("Zone")
	zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = SKY_AMBIENT
	zone.fogColor = magic.Color(0.60, 0.72, 0.88)
	zone.fogStart = FAR_CLIP * 0.6
	zone.fogEnd = FAR_CLIP
	zone.priority = -1
	zone.override = true
	-- What the voxel shader reflects; without it its IBL term samples
	-- nothing and every reflection is black
	zone.zoneTexture = magic.cache:GetResource("TextureCube",
			voxel_shading.sky_cubemap)
end

local sun_node = scene:CreateChild("DirectionalLight")
do
	sun_node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
	sun_light = sun_node:CreateComponent("Light")
	sun_light.lightType = magic.LIGHT_DIRECTIONAL
	sun_light.castShadows = true
	sun_light.brightness = SUN_BRIGHTNESS
	sun_light.color = SUN_COLOR
end

voxel_shading.create_skybox(scene, SUN_DIR)

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
	camera.nearClip = 1.0
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
	local rp = viewport.renderPath:Clone()
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/BloomHDR.xml"))
	rp:Append(magic.cache:GetResource("XMLFile", "PostProcess/Tonemap.xml"))
	rp:Append(magic.cache:GetResource("XMLFile",
			"PostProcess/GammaCorrection.xml"))
	rp:SetEnabled("TonemapReinhardEq3", false)
	rp:SetEnabled("TonemapUncharted2", true)
	rp:SetShaderParameter("TonemapExposureBias", EXPOSURE_BIAS)
	viewport.renderPath = rp
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

local title_text = hud_text(15)
-- Escape is on it because the whole list is behind Escape now
title_text:SetText("luanti_launcher: WASD = walk, Space = jump, " ..
		"Tab = mouse, Escape = menu, left = dig, right = place")
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_TOP
title_text:SetPosition(0, 10)
local crosshair = hud_text(20)
crosshair:SetText("+")
crosshair.horizontalAlignment = magic.HA_CENTER
crosshair.verticalAlignment = magic.VA_CENTER
crosshair:SetPosition(0, 0)

--
-- The hotbar
--
-- The first eight slots of the player's own inventory, along the bottom
-- where Luanti puts them: what is in each, how many, and which one is in
-- hand. The keys 1-8 and the wheel pick one, and the server is told --
-- what is in hand is what a dig or a place asks it about.
local HOTBAR_SLOTS = 8
local SLOT = 44
local SLOT_GAP = 4
local WHITE = luanti.texture("[fill:1x1:#ffffffff")

local hotbar = {}
local hotbar_stacks = {}
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

do
	local width = HOTBAR_SLOTS * SLOT + (HOTBAR_SLOTS - 1) * SLOT_GAP
	local white = game_texture(WHITE)
	for i = 1, HOTBAR_SLOTS do
		local frame = magic.ui.root:CreateChild("BorderImage")
		if white then
			frame.texture = white
		end
		frame.color = magic.Color(0.1, 0.1, 0.12, 0.55)
		frame.size = magic.IntVector2(SLOT, SLOT)
		frame.horizontalAlignment = magic.HA_CENTER
		frame.verticalAlignment = magic.VA_BOTTOM
		frame:SetPosition(math.floor(-width / 2 + (i - 1) *
				(SLOT + SLOT_GAP)), -8)
		local image = frame:CreateChild("BorderImage")
		image:SetPosition(4, 4)
		image.size = magic.IntVector2(SLOT - 8, SLOT - 8)
		image.visible = false
		local count = frame:CreateChild("Text")
		count:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 12)
		count:SetTextEffect(magic.TE_SHADOW)
		count.effectColor = magic.Color(0, 0, 0, 0.9)
		count.horizontalAlignment = magic.HA_RIGHT
		count.verticalAlignment = magic.VA_BOTTOM
		count:SetPosition(-3, -2)
		hotbar[i] = {frame = frame, image = image, count = count}
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
wield_material:SetTechnique(0, magic.cache:GetResource("Technique",
		"Techniques/DiffUnlit.xml"))
wield_model:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
wield_model.material = wield_material
-- Out past the near clip, which is a whole node away: a cube closer than
-- that is not drawn at all
wield_node.position = magic.Vector3(0.62, -0.46, 1.5)
wield_node.rotation = magic.Quaternion(-18, 35, 8)
wield_node.scale = magic.Vector3(0.20, 0.20, 0.20)
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

local function draw_hotbar()
	for i = 1, HOTBAR_SLOTS do
		local slot = hotbar[i]
		local name, count = parse_stack(hotbar_stacks[i])
		local tex = name and game_texture(luanti.item_texture(name))
		-- Assigned only when there is one: the sandbox takes a Texture and
		-- not a nil, and an empty slot is an image that is not drawn
		if tex then
			slot.image.texture = tex
		end
		slot.image.visible = tex ~= nil
		-- Something with no image of its own is still something: a box
		-- says the slot is not empty
		slot.frame.color = (name and tex == nil) and
				magic.Color(0.5, 0.3, 0.5, 0.75) or
				magic.Color(0.1, 0.1, 0.12, 0.55)
		if i == wield_index then
			slot.frame.color = magic.Color(0.9, 0.9, 0.7, 0.75)
		end
		slot.count:SetText((count and count > 1) and tostring(count) or "")
	end
	local name = parse_stack(hotbar_stacks[wield_index])
	wielded_text:SetText(name or "")
	draw_wielded(name)
end

-- Set once the HUD is built: a HUD element that draws a list of the player's
-- own has to follow it, and what the game sends is only the element
local hud_follows_inventory = nil

luanti.sub_inventory(function(lists)
	hotbar_stacks = lists.main or {}
	draw_hotbar()
	if hud_follows_inventory then
		hud_follows_inventory()
	end
end)

local function set_wield(i)
	if i < 1 then
		i = HOTBAR_SLOTS
	elseif i > HOTBAR_SLOTS then
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
-- What the game said its sky is, as luanti.sub_sky() gives it
local game_sky = {}

-- The moon is the sky's own square with the light gone out of it: what is up
-- there at night is not the sun, so it is not the sun's colour either
local MOON_DISC_COLOR = {r = 0.72, g = 0.76, b = 0.92}

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
	voxel_shading.set_sky_look(
			three(night_zenith, dawn_zenith, day_zenith, t),
			three(night_horizon, dawn_horizon, day_horizon, t), nil)

	-- The sun by day and the moon by night are the same square, so which of
	-- the two the game turned off is which half of the clock it is gone in
	local night = sky_now.height < 0
	local visible = night and (game_sky.moon_visible ~= false) or
			(not night and game_sky.sun_visible ~= false)
	local scale = (night and game_sky.moon_scale or game_sky.sun_scale) or 1
	voxel_shading.set_sun_look(
			visible and defaults.sun_half * scale or 0,
			night and MOON_DISC_COLOR or defaults.sun_color)

	-- The stars come out as the light goes: Luanti's day_opacity is zero by
	-- default, which is a sky with none in it until the sun is down
	local count = game_sky.star_count or 1000
	local density = 0
	if game_sky.stars_visible ~= false then
		local out = (1 - t) * (1 - t)
		-- How many cells of the sky's grid have a star in them; the grid is
		-- about ten thousand of them over the half that can be seen
		density = math.min(0.5, count / 10000) * out
	end
	voxel_shading.set_star_look(density, game_sky.star_color,
			0.12 * (game_sky.star_scale or 1))

	-- The clouds are white because the sun is on them, so they go with it
	voxel_shading.set_cloud_light(0.16 + 0.84 * t)
	-- And so does what a pond mirrors: the cube map it comes from is baked
	-- at noon, so without this the water is a bright blue sky at midnight
	voxel_shading.set_sky_light(0.10 + 0.90 * t)
end

local function update_sky(dt)
	if time_of_day == nil then
		return
	end
	-- A day is 24*60*60 game seconds and time_speed is how many of them a
	-- real second is
	time_of_day = (time_of_day + dt * time_speed / (24 * 60 * 60)) % 1.0

	-- Where the sun is: up at noon, on the horizon at sunrise and sunset,
	-- and under the world at night. Tilted out of the vertical plane so
	-- that noon does not light every face of a cube the same way.
	local a = (time_of_day - 0.25) * 2 * math.pi
	local height = math.sin(a)
	local up = {x = math.cos(a) * 0.9, y = height, z = 0.42}
	-- The light travels the other way, which is what a Light's direction is
	local dir = normalized({x = -up.x, y = -up.y, z = -up.z})
	-- At night the moon is where the sun is not
	local night = height < 0
	if night then
		dir = {x = -dir.x, y = -dir.y, z = -dir.z}
	end
	sun_node.direction = magic.Vector3(dir.x, dir.y, dir.z)
	voxel_shading.set_sun_direction(night and
			{x = -dir.x, y = -dir.y, z = -dir.z} or dir)

	-- Dawn and dusk are the half hour either side of the horizon rather
	-- than a switch -- unless the game says what the light is whatever the
	-- hour, which is what a dimension of its own is made of
	local day = math.max(0, math.min(1, (height + 0.15) / 0.3))
	if luanti.day_night_override then
		day = luanti.day_night_override
	end
	sun_light.brightness = MOON_BRIGHTNESS +
			(SUN_BRIGHTNESS - MOON_BRIGHTNESS) * day
	sun_light.color = blend(MOON_COLOR, SUN_COLOR, day)
	zone.ambientColor = blend(NIGHT_AMBIENT, SKY_AMBIENT, day)
	zone.fogColor = blend(NIGHT_FOG, DAY_FOG, day)
	sky_now.height = height
	sky_now.day = day
	apply_sky_of_hour()
	-- What is in the player's hand is drawn unlit, so the daylight is put
	-- on it by hand; without this it glows at midnight
	local k = 0.28 + 0.72 * day
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
		voxel_shading.set_sky_look(nil, nil, cover)
	end
	-- The fog is the horizon seen through the world's air, so it follows
	-- the horizon the game asked for
	if sky.horizon then
		DAY_FOG = magic.Color(sky.horizon.r, sky.horizon.g, sky.horizon.b)
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
-- Luanti tints the screen and closes the fog in when the camera is in a
-- liquid, which is the only thing that says you are swimming rather than
-- walking. What counts as a liquid is the registry's own is_liquid, so a
-- game's lava does this as much as its water does -- in that game's own
-- colour, which is the liquid's own texture averaged out.
local water_tint = magic.ui.root:CreateChild("BorderImage")
water_tint.color = magic.Color(0.15, 0.35, 0.65, 0.35)
water_tint.visible = false
water_tint.priority = -500

local UNDERWATER_FOG = 40

local function voxel_liquid_at(p)
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
	if def == nil or not def.is_liquid then
		return nil
	end
	return def
end

local underwater = false

local function update_underwater(eye)
	local def = voxel_liquid_at(eye)
	local now = def ~= nil
	if now == underwater then
		return
	end
	underwater = now
	water_tint.visible = now
	if now then
		water_tint.texture = game_texture(WHITE)
		water_tint.size = magic.IntVector2(magic.ui.root.width,
				magic.ui.root.height)
		zone.fogStart = 2
		zone.fogEnd = UNDERWATER_FOG
	else
		zone.fogStart = FAR_CLIP * 0.6
		zone.fogEnd = FAR_CLIP
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

local player = player_physics.new(node_stops)
-- Nothing moves until the server says where the player is: what it answers
-- with is the spawn, or where the last run left them, and a client that
-- started walking from somewhere of its own would tell the server that
-- instead. See M.sub_player_pos in the module's client half.
local player_placed = false

luanti.sub_player_pos(function(p)
	player:set_position(p.x, p.y, p.z)
	player.vx, player.vy, player.vz = 0, 0, 0
	if not player_placed then
		player_placed = true
		set_mouse_in_world(true)
	end
	log:info("the server put the player at " ..
			string.format("%.1f, %.1f, %.1f", p.x, p.y, p.z))
end)

-- What F5 shows: where the player is, what they are standing on and what
-- the keys are. A player who wants to know why something is not happening
-- looks here first.
local detail_text = hud_text(13)
detail_text:SetText("")
detail_text.horizontalAlignment = magic.HA_LEFT
detail_text.verticalAlignment = magic.VA_TOP
detail_text:SetPosition(8, 30)
detail_text.visible = false

local function binding_lines()
	local parts = {}
	for _, b in ipairs(BINDINGS) do
		parts[#parts + 1] = b.name .. ": " .. b.what
	end
	return table.concat(parts, "\n")
end

local detail_timer = 0
local function update_detail(dt)
	if not detail_text.visible then
		return
	end
	detail_timer = detail_timer + dt
	if detail_timer < 0.25 then
		return
	end
	detail_timer = 0
	local mode = player.noclip and "noclip" or (player.fly and "flying" or
			(player.on_ground and "on the ground" or "falling"))
	local chunk_p = voxelworld.get_chunk_position(buildat.Vector3(
			player.x, player.y, player.z))
	detail_text:SetText(string.format(
			"%.1f, %.1f, %.1f | %s | looking %.0f round, %.0f down\n" ..
			"speed %.1f, %.1f, %.1f | chunk %d, %d, %d%s\n" ..
			"%02d:%02d | sun %.2f up, %.0f%% day\n%s",
			player.x, player.y, player.z, mode, yaw, pitch,
			player.vx, player.vy, player.vz,
			chunk_p.x, chunk_p.y, chunk_p.z,
			voxelworld.chunk_has_physics(chunk_p) and "" or " (no physics)",
			math.floor((time_of_day or 0) * 24),
			math.floor(((time_of_day or 0) * 24 % 1) * 60),
			sky_now.height, sky_now.day * 100,
			binding_lines()))
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
chat_block.verticalAlignment = magic.VA_BOTTOM
-- Above the hotbar, the bars and the name of what is in hand, which are
-- what is at the bottom of the screen
chat_block:SetPosition(8, -(8 + SLOT + 52))
chat_block.size = magic.IntVector2(600, CHAT_LINES * CHAT_LINE_H)

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
-- simplified: a minimap and the styles inside a line of text -- bold,
-- italic, monospace -- are not drawn; each missing kind is named once in the
-- log so that a game asking for one says so rather than silently missing
-- it.
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

local function hud_place(element, e, w, h)
	local px, py = parse_v2(e.pos, 0, 0)
	local ox, oy = parse_v2(e.offset, 0, 0)
	local ax, ay = parse_v2(e.align, 0, 0)
	element:SetPosition(
			math.floor(px * magic.ui.root.width + ox -
					(ax + 1) * 0.5 * w),
			math.floor(py * magic.ui.root.height + oy -
					(ay + 1) * 0.5 * h))
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
	-- A negative scale is a fraction of the screen rather than of the image,
	-- which is how Luanti's own scale works
	local w = sx < 0 and (-sx * 0.01 * magic.ui.root.width) or
			(tex.width * sx)
	local h = sy < 0 and (-sy * 0.01 * magic.ui.root.height) or
			(tex.height * sy)
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
	local sw, sh = parse_v2(e.size, 0, 0)
	local slot = math.floor(sw > 0 and sw or SLOT)
	local step = slot + SLOT_GAP
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
		local at = (i - 1) * step
		if dir == 1 then
			frame:SetPosition(-at, 0)
		elseif dir == 2 then
			frame:SetPosition(0, at)
		elseif dir == 3 then
			frame:SetPosition(0, -at)
		else
			frame:SetPosition(at, 0)
		end
		local tex = name and game_texture(luanti.item_texture(name))
		if tex then
			local image = frame:CreateChild("BorderImage")
			image.texture = tex
			image:SetPosition(4, 4)
			image.size = magic.IntVector2(slot - 8, slot - 8)
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
	local w = (dir <= 1) and (n * step - SLOT_GAP) or slot
	local h = (dir <= 1) and slot or (n * step - SLOT_GAP)
	row.size = magic.IntVector2(w, h)
	hud_place(row, e, w, h)
end

-- Where a waypoint's own element goes: the place on the screen its world
-- position is at, plus the offset, with the alignment saying which corner of
-- it lands there. The same as hud_place() but for pos, which a waypoint does
-- not have.
local function hud_place_at(element, e, w, h, sx, sy)
	local ox, oy = parse_v2(e.offset, 0, 0)
	local ax, ay = parse_v2(e.align, 0, 0)
	element:SetPosition(
			math.floor(sx + ox - (ax + 1) * 0.5 * w),
			math.floor(sy + oy - (ay + 1) * 0.5 * h))
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
	local w = sw > 0 and sw or tex.width
	local h = sh > 0 and sh or tex.height
	-- Luanti's dir: 0 right, 1 left, 2 down, 3 up
	local dir = math.floor(tonumber(e.dir) or 0)
	local bg = e.text2 and game_texture(luanti.texture(e.text2))
	local whole = math.floor(total / 2)
	local row = hud_root:CreateChild("UIElement")
	local count = 0
	for i = 1, whole do
		local filled = value >= i * 2
		local half = (not filled) and value == i * 2 - 1
		local tex_i = filled and tex or (half and tex or bg)
		if tex_i then
			local icon = row:CreateChild("BorderImage")
			icon.texture = tex_i
			icon.size = magic.IntVector2(math.floor(half and w / 2 or w),
					math.floor(h))
			if half then
				-- The left half of the icon, which is Luanti's own half
				icon.imageRect = magic.IntRect(0, 0,
						math.floor(tex_i.width / 2), tex_i.height)
			end
			local step = (i - 1)
			local x, y = step * w, 0
			if dir == 1 then x = -step * w
			elseif dir == 2 then x, y = 0, step * h
			elseif dir == 3 then x, y = 0, -step * h end
			icon:SetPosition(math.floor(x), math.floor(y))
			count = count + 1
		end
	end
	local total_w = (dir <= 1) and whole * w or w
	local total_h = (dir <= 1) and h or whole * h
	row.size = magic.IntVector2(math.floor(total_w), math.floor(total_h))
	hud_place(row, e, total_w, total_h)
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
	title_text.visible = hud_shown
	crosshair.visible = hud_shown and luanti.hud_flag("crosshair")
	chat_block.visible = chat_shown and luanti.hud_flag("chat")
	for _, slot in ipairs(hotbar) do
		slot.frame.visible = hud_shown and luanti.hud_flag("hotbar")
	end
	wielded_text.visible = hud_shown and luanti.hud_flag("hotbar")
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
	elseif fields.quit then
		-- Continued, or escaped: the mouse goes back to the world
		set_mouse_in_world(true)
	end
end

local function open_pause_menu()
	luanti.show_local_form(pause_spec(), menu_fields)
	set_mouse_in_world(false)
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
end

local function update_dig(dt, playing)
	local holding = playing and
			magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT)
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
		-- A form that closed hands the mouse back to the world, which is
		-- where it came from
		set_mouse_in_world(not luanti.form_open())
		return
	end
	if key >= magic.KEY_1 and key <= magic.KEY_8 then
		set_wield(key - magic.KEY_1 + 1)
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
		-- is for. The mouse has to be on the screen to click a form -- but
		-- only if one opened: a game that sets no inventory formspec draws
		-- nothing, and taking the mouse away then leaves the player unable
		-- to move with nothing to click on. The same key closes it again
		-- and hands the mouse back.
		local was_open = luanti.form_open()
		luanti.open_player_inventory()
		if luanti.form_open() then
			set_mouse_in_world(false)
		elseif was_open then
			set_mouse_in_world(true)
		end
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
		detail_text.visible = not detail_text.visible
		detail_timer = 1
	elseif key == BIND.menu.key then
		open_pause_menu()
	end
end)

-- Where the player is, a few times a second: the server moves its own player
-- there, and a Luanti mod asking where the player is gets this.
local WHERE_INTERVAL = 0.2
local where_timer = 0

local function send_where()
	local p = {x = player.x, y = player.y, z = player.z}
	-- Luanti measures the horizontal angle from +Z towards -X and the
	-- vertical one positive upwards, which is what its get_look_dir()
	-- unpacks; Urho's yaw goes the other way round
	buildat.send_packet("main:where", cereal.binary_output({
		x = p.x, y = p.y, z = p.z,
		look_h = math.rad(-yaw),
		look_v = math.rad(-pitch),
	}, {"object",
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
		{"look_h", "double"},
		{"look_v", "double"},
	}))
end

magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	voxel_shading.update(dt)
	update_sky(dt)

	if player_placed then
		where_timer = where_timer + dt
		if where_timer >= WHERE_INTERVAL then
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

	camera_node.position = magic.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	place_waypoints()
	turn_compasses()
	update_underwater(buildat.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))
end)

log:info("luanti_launcher client ready")
-- vim: set noet ts=4 sw=4:
