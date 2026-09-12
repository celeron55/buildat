-- Buildat: luanti_launcher/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A window onto a Luanti world running inside buildat_server. There is no
-- player and no digging: this is what M2 has to show, which is that the nodes
-- a mod placed are in voxelworld and on the screen. The Luanti client's own
-- look -- drawtypes, the real tiles, the media -- is M3.
local log = buildat.Logger("luanti_launcher")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

local scene = replicate.main_scene

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

local MOVE_SPEED = 20
local MOUSE_SENSITIVITY = 0.15

-- The same PBR setup the lighting games use; games/voxel_lighting's README
-- says why these numbers are what they are
local SKY_AMBIENT = magic.Color(0.26, 0.33, 0.46)
local SUN_BRIGHTNESS = 50.0
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
local free_look = false

do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
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

do
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(SUN_DIR.x, SUN_DIR.y, SUN_DIR.z)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = SUN_BRIGHTNESS
	light.color = magic.Color(1.0, 0.96, 0.88)
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

local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("luanti_launcher: Tab = free move")
title_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_TOP
title_text:SetPosition(0, 10)
magic.ui:SetFocusElement(nil)

-- Mods load for several seconds before there is anything to draw, and what is
-- on the screen until then is sky
local wait_text = magic.ui.root:CreateChild("Text")
wait_text:SetText("Loading the world...")
wait_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 24)
wait_text.horizontalAlignment = magic.HA_CENTER
wait_text.verticalAlignment = magic.VA_CENTER
wait_text:SetPosition(0, 0)
voxelworld.sub_geometry_update(function(node)
	wait_text:SetText("")
end)

local function set_free_look(enable)
	free_look = enable
	magic.input:SetMouseVisible(not free_look)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_TAB then
		set_free_look(not free_look)
	elseif key == magic.KEY_ESCAPE then
		if free_look then
			set_free_look(false)
		else
			buildat.disconnect()
		end
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	voxel_shading.update(dt)
	if not free_look then
		return
	end

	local dmouse = magic.input:GetMouseMove()
	yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
	pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
	if pitch > 89 then pitch = 89 end
	if pitch < -89 then pitch = -89 end

	local yr = math.rad(yaw)
	local forward = magic.Vector3(math.sin(yr), 0, math.cos(yr))
	local right = magic.Vector3(math.cos(yr), 0, -math.sin(yr))

	local speed = MOVE_SPEED * dt
	local p = camera_node.position
	local function move(v, s)
		p = magic.Vector3(p.x + v.x*s, p.y + v.y*s, p.z + v.z*s)
	end
	if magic.input:GetKeyDown(magic.KEY_W) then move(forward, speed) end
	if magic.input:GetKeyDown(magic.KEY_S) then move(forward, -speed) end
	if magic.input:GetKeyDown(magic.KEY_D) then move(right, speed) end
	if magic.input:GetKeyDown(magic.KEY_A) then move(right, -speed) end
	if magic.input:GetKeyDown(magic.KEY_SPACE) then
		p = magic.Vector3(p.x, p.y + speed, p.z)
	end
	if magic.input:GetKeyDown(magic.KEY_SHIFT) then
		p = magic.Vector3(p.x, p.y - speed, p.z)
	end

	camera_node.position = p
	camera_node.rotation = magic.Quaternion(pitch, yaw, 0)
end)

log:info("luanti_launcher client ready")
-- vim: set noet ts=4 sw=4:
