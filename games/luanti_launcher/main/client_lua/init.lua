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
	{action = "mouse", key = magic.KEY_TAB, name = "Tab",
			what = "The mouse in the world or on the screen"},
	{action = "detail", key = magic.KEY_F5, name = "F5",
			what = "The line of detail on and off"},
	{action = "menu", key = magic.KEY_ESCAPE, name = "Escape",
			what = "Close what is open - or leave"},
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
do
	local d = normalized(VIEW_DIR)
	camera_node.position = magic.Vector3(
			LOOK_AT.x - d.x * CAMERA_DISTANCE,
			LOOK_AT.y - d.y * CAMERA_DISTANCE,
			LOOK_AT.z - d.z * CAMERA_DISTANCE)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 1.0
	camera.farClip = FAR_CLIP
	camera.fov = CAMERA_FOV

	local viewport = magic.Viewport:new(scene, camera)
	magic.set_preferred_viewports({viewport})

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
local function hud_text(size)
	local t = magic.ui.root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), size or 15)
	t:SetTextEffect(magic.TE_SHADOW)
	t.effectColor = magic.Color(0, 0, 0, 0.85)
	return t
end

local title_text = hud_text(15)
title_text:SetText("luanti_launcher: WASD = walk, Space = jump, K = fly, " ..
		"Tab = mouse, F5 = detail, left = dig, right = place")
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
end

luanti.sub_inventory(function(lists)
	hotbar_stacks = lists.main or {}
	draw_hotbar()
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
	-- than a switch
	local day = math.max(0, math.min(1, (height + 0.15) / 0.3))
	sun_light.brightness = MOON_BRIGHTNESS +
			(SUN_BRIGHTNESS - MOON_BRIGHTNESS) * day
	sun_light.color = blend(MOON_COLOR, SUN_COLOR, day)
	zone.ambientColor = blend(NIGHT_AMBIENT, SKY_AMBIENT, day)
	zone.fogColor = blend(NIGHT_FOG, DAY_FOG, day)
	sky_now.height = height
	sky_now.day = day
end

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

local chat_text = hud_text(14)
chat_text:SetText("")
chat_text.horizontalAlignment = magic.HA_LEFT
chat_text.verticalAlignment = magic.VA_BOTTOM
-- Above the hotbar, the bars and the name of what is in hand, which are
-- what is at the bottom of the screen
chat_text:SetPosition(8, -(8 + SLOT + 52))
chat_text.color = magic.Color(1.0, 1.0, 0.9)

local chat_input = nil
-- The key that opens the line arrives as text as well, and the line edit
-- would get it: the field goes up on the next frame instead, when that text
-- has gone nowhere. Copied from the extension, which found this out.
local chat_wanted = false

luanti.sub_chat(function(line, lines)
	local first = math.max(1, #lines - CHAT_LINES + 1)
	local shown = {}
	for i = first, #lines do
		shown[#shown + 1] = lines[i]
	end
	chat_text:SetText(table.concat(shown, "\n"))
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
-- simplified: text, image and statbar. A waypoint, a compass, a minimap and
-- an inventory element are not drawn; each is named once in the log so that
-- a game asking for one says so rather than silently missing it.
local hud_root = magic.ui.root:CreateChild("UIElement")
hud_root:SetPosition(0, 0)
local hud_missing = {}

local function parse_v2(str, dx, dy)
	if type(str) ~= "string" then
		return dx, dy
	end
	local x, y = string.match(str, "^([^,]*),(.*)$")
	return tonumber(x) or dx, tonumber(y) or dy
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

local function draw_hud_text(e)
	local t = hud_root:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
	t:SetTextEffect(magic.TE_SHADOW)
	t.effectColor = magic.Color(0, 0, 0, 0.85)
	t:SetText(luanti.strip_escapes(e.text or ""))
	t.color = hud_colour(e.number)
	hud_place(t, e, t.width, t.height)
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

-- The client's own bars, which a game turns off with the healthbar and
-- breathbar flags when it draws its own.
--
-- simplified: a bar rather than Luanti's hearts and bubbles, because those
-- are the engine's own textures and a game does not ship them; what a game
-- ships is drawn by the statbar elements above.
local function draw_own_bars()
	local stats = luanti.stats
	-- Just above the hotbar, which is where Luanti puts them: what the
	-- player has on the left, how much breath is left on the right
	local function bar(left, value, max, colour)
		if max <= 0 then
			return
		end
		local w, h = 120, 8
		local back = hud_root:CreateChild("BorderImage")
		back.texture = game_texture(WHITE)
		back.color = magic.Color(0, 0, 0, 0.5)
		back.size = magic.IntVector2(w, h)
		back.horizontalAlignment = magic.HA_CENTER
		back.verticalAlignment = magic.VA_BOTTOM
		back:SetPosition(left and (-w - 6) or 6, -(8 + SLOT + 4))
		local fill = back:CreateChild("BorderImage")
		fill.texture = game_texture(WHITE)
		fill.color = colour
		fill.size = magic.IntVector2(
				math.max(0, math.floor(w * value / max)), h)
	end
	if luanti.hud_flag("healthbar") then
		bar(true, stats.hp, stats.hp_max, magic.Color(0.85, 0.15, 0.15))
	end
	-- Luanti shows the breath only while the player is short of it
	if luanti.hud_flag("breathbar") and stats.breath < stats.breath_max then
		bar(false, stats.breath, stats.breath_max,
				magic.Color(0.3, 0.6, 1.0))
	end
end

local function draw_hud(elements, flags)
	hud_root:RemoveAllChildren()
	-- As big as the screen, because an element aligned to the centre or the
	-- bottom is aligned inside this and an element of no size puts every
	-- one of them in the top left corner
	hud_root.size = magic.IntVector2(magic.ui.root.width,
			magic.ui.root.height)
	draw_own_bars()
	-- The game can take the client's own away, and what it draws instead is
	-- these elements; see luanti.hud_flag()
	crosshair.visible = luanti.hud_flag("crosshair")
	chat_text.visible = luanti.hud_flag("chat")
	for _, slot in ipairs(hotbar) do
		slot.frame.visible = luanti.hud_flag("hotbar")
	end
	wielded_text.visible = luanti.hud_flag("hotbar")
	for id, e in pairs(elements) do
		local kind = e.type or "text"
		if kind == "text" then
			draw_hud_text(e)
		elseif kind == "image" then
			draw_hud_image(e)
		elseif kind == "statbar" then
			draw_hud_statbar(e)
		elseif not hud_missing[kind] then
			hud_missing[kind] = true
			log:info("the game asked for a \"" .. kind ..
					"\" HUD element, which is not drawn")
		end
	end
end

luanti.sub_hud(draw_hud)

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
-- a node is placed and what Luanti calls the "above" of a pointed thing
local function find_pointed_voxel()
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last = nil
	for i = 1, math.floor(POINT_RANGE / POINT_STEP) do
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
	if button == magic.MOUSEB_LEFT then
		buildat.send_packet("main:dig", cereal.binary_output({
			p = voxel_packet_value(pointed_p),
		}, {"object", {"p", VOXEL_PACKET_TYPE}}))
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

-- Where a click landed, which MouseButtonDown does not say. A form is the
-- only thing here that cares.
magic.SubscribeToEvent("UIMouseClick", function(event_type, event_data)
	if not luanti.form_open() then
		return
	end
	luanti.click(event_data:GetInt("X"), event_data:GetInt("Y"),
			event_data:GetInt("Button") == magic.MOUSEB_RIGHT and "right" or
			"left")
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
		set_mouse_in_world(false)
		return
	end
	if key >= magic.KEY_1 and key <= magic.KEY_8 then
		set_wield(key - magic.KEY_1 + 1)
	elseif key == BIND.chat.key then
		chat_wanted = true
	elseif key == BIND.mouse.key then
		set_mouse_in_world(not mouse_in_world)
	elseif key == BIND.inventory.key then
		-- Luanti's own inventory key, and what a game's inventory formspec
		-- is for. The mouse has to be on the screen to click it.
		luanti.open_player_inventory()
		set_mouse_in_world(false)
	elseif key == BIND.fly.key then
		player.fly = not player.fly
		log:info(player.fly and "flying" or "walking")
	elseif key == BIND.noclip.key then
		player.noclip = not player.noclip
		log:info(player.noclip and "through walls" or "solid walls")
	elseif key == BIND.detail.key then
		detail_text.visible = not detail_text.visible
		detail_timer = 1
	elseif key == BIND.menu.key then
		if mouse_in_world then
			set_mouse_in_world(false)
		else
			buildat.disconnect()
		end
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

	player:update(dt, wish)

	camera_node.position = magic.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z)
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
	update_underwater(buildat.Vector3(player.x,
			player.y + player_physics.EYE_HEIGHT, player.z))
end)

log:info("luanti_launcher client ready")
-- vim: set noet ts=4 sw=4:
