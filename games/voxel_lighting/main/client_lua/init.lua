-- Buildat: voxel_lighting/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("voxel_lighting")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")

local scene = replicate.main_scene

-- The scene is viewed from outside itself, so nothing may drop to a reduced
-- LOD, and there is no player, so no collision shapes are wanted at all.
voxelworld.lod_distance = 1000
voxelworld.physics_distance = 1

-- Benchmark 1: outside the high +X +Y +Z corner, looking down the diagonal at
-- the opposite one. Pulled far enough back that a 45 degree fov covers the
-- ground plane, rather than widening the fov and distorting the corners.
-- VIEW_DIR is kept in sync with main.cpp by hand; the cave is carved along it
-- (yawed by CAVE_YAW_DEGREES there).
local VIEW_DIR = {x = -1.0, y = -0.7, z = -1.0}
-- Middle of the volume, a little below the mean terrain surface (y=32)
local LOOK_AT = {x = 32, y = 27, z = 32}
local CAMERA_DISTANCE = 90
local CAMERA_FOV = 45
local FAR_CLIP = 400

-- Benchmarks 2 and 3 sit on the cave axis the server reports. Outside is far
-- enough back that the mouth is not the whole frame; inside is deep enough
-- that the opening reads as a bright hole at the end of a dark tunnel.
local CAVE_OUTSIDE_DISTANCE = 22
local CAVE_INSIDE_DISTANCE = 26

local MOVE_SPEED = 20
local MOUSE_SENSITIVITY = 0.15

local function normalized(v)
	local l = math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return {x = v.x/l, y = v.y/l, z = v.z/l}
end

-- Urho is left-handed and Y-up: yaw 0 looks towards +Z, and euler pitch is
-- positive downwards. Angles are in degrees, which is what Quaternion takes.
local function angles_from_dir(d)
	d = normalized(d)
	return math.deg(math.atan2(d.x, d.z)), math.deg(math.asin(-d.y))
end

-- Node.direction goes through SetDirection, which is a shortest-arc rotation
-- from forward and therefore rolls the camera; build the rotation from the
-- angles instead so that the horizon stays level.
local function apply_angles(node, yaw, pitch)
	node.rotation = magic.Quaternion(pitch, yaw, 0)
end

-- Benchmark camera placements. 1 is known up front; 2 and 3 need the cave,
-- which arrives from the server in main:cave.
local benchmarks = {}
do
	local d = normalized(VIEW_DIR)
	local b_yaw, b_pitch = angles_from_dir(VIEW_DIR)
	benchmarks[1] = {
		name = "Overview",
		x = LOOK_AT.x - d.x * CAMERA_DISTANCE,
		y = LOOK_AT.y - d.y * CAMERA_DISTANCE,
		z = LOOK_AT.z - d.z * CAMERA_DISTANCE,
		yaw = b_yaw, pitch = b_pitch,
	}
end

local yaw = benchmarks[1].yaw
local pitch = benchmarks[1].pitch
local free_look = false

-- Global visual parameters. Deliberately plain: this is the baseline the
-- lighting work is measured against.
do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = magic.Color(0.42, 0.48, 0.60)
	zone.fogColor = magic.Color(0.68, 0.76, 0.85)
	zone.fogStart = FAR_CLIP * 0.6
	zone.fogEnd = FAR_CLIP
	zone.priority = -1
	zone.override = true
end

do
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(-0.6, -1.0, 0.8)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = 1.2
	light.color = magic.Color(1.0, 1.0, 0.95)
end

local camera_node = scene:CreateChild("Camera")
do
	camera_node.position = magic.Vector3(
			benchmarks[1].x, benchmarks[1].y, benchmarks[1].z)
	apply_angles(camera_node, yaw, pitch)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 1.0
	camera.farClip = FAR_CLIP
	camera.fov = CAMERA_FOV

	local viewport = magic.Viewport:new(scene, camera)
	magic.renderer:SetViewport(0, viewport)
end

voxelworld.set_camera(camera_node)

magic.input:SetMouseVisible(true)

local function set_free_look(enable)
	free_look = enable
	magic.input:SetMouseVisible(not free_look)
	local p = camera_node.position
	log:info("free move: "..tostring(free_look)..
			string.format("; camera (%.1f, %.1f, %.1f) yaw %.1f pitch %.1f",
			p.x, p.y, p.z, yaw, pitch))
end

local function go_to_benchmark(i)
	local b = benchmarks[i]
	if not b then
		log:warning("benchmark "..i..": no cave data from the server yet")
		return
	end
	if free_look then
		set_free_look(false)
	end
	yaw = b.yaw
	pitch = b.pitch
	camera_node.position = magic.Vector3(b.x, b.y, b.z)
	apply_angles(camera_node, yaw, pitch)
	log:info(string.format("benchmark %d (%s): camera (%.1f, %.1f, %.1f) "..
			"yaw %.1f pitch %.1f", i, b.name, b.x, b.y, b.z, yaw, pitch))
end

-- Where the cave ended up, as "mx my mz dx dy dz". Sent rather than recomputed
-- here, so the benchmark cameras cannot drift out of sync with the carve.
buildat.sub_packet("main:cave", function(data)
	local mx, my, mz, dx, dy, dz = string.match(data,
			"([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+) ([^ ]+)")
	if not dz then
		log:error("main:cave: cannot parse \""..data.."\"")
		return
	end
	mx, my, mz = tonumber(mx), tonumber(my), tonumber(mz)
	dx, dy, dz = tonumber(dx), tonumber(dy), tonumber(dz)

	local out_yaw, out_pitch = angles_from_dir({x = dx, y = dy, z = dz})
	benchmarks[2] = {
		name = "Cave mouth",
		x = mx - dx * CAVE_OUTSIDE_DISTANCE,
		y = my - dy * CAVE_OUTSIDE_DISTANCE,
		z = mz - dz * CAVE_OUTSIDE_DISTANCE,
		yaw = out_yaw, pitch = out_pitch,
	}
	local in_yaw, in_pitch = angles_from_dir({x = -dx, y = -dy, z = -dz})
	benchmarks[3] = {
		name = "Inside cave",
		x = mx + dx * CAVE_INSIDE_DISTANCE,
		y = my + dy * CAVE_INSIDE_DISTANCE,
		z = mz + dz * CAVE_INSIDE_DISTANCE,
		yaw = in_yaw, pitch = in_pitch,
	}
	log:info(string.format("cave mouth (%.1f, %.1f, %.1f) dir (%.2f, %.2f, "..
			"%.2f); benchmarks 2 and 3 ready", mx, my, mz, dx, dy, dz))
end)

-- HUD, so the scene can be inspected without remembering the keys
do
	local ui_root = magic.ui.root
	ui_root.defaultStyle = magic.cache:GetResource("XMLFile",
			"UI/DefaultStyle.xml")

	local panel = ui_root:CreateChild("UIElement")
	panel:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 8, 8, 8))
	panel:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)

	local function add_button(label, action)
		local button = panel:CreateChild("Button")
		button:SetStyleAuto()
		button:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 4, 8, 4))
		button.minHeight = 24
		button.minWidth = 130
		button:SetFocusMode(magic.FM_NOTFOCUSABLE)
		local text = button:CreateChild("Text")
		text:SetStyleAuto()
		text.text = label
		text:SetTextAlignment(magic.HA_CENTER)
		magic.SubscribeToEvent(button, "Released", function()
			action()
			magic.ui:SetFocusElement(nil)
		end)
	end

	add_button("Free move (Tab)", function() set_free_look(not free_look) end)
	add_button("1 Overview", function() go_to_benchmark(1) end)
	add_button("2 Cave mouth", function() go_to_benchmark(2) end)
	add_button("3 Inside cave", function() go_to_benchmark(3) end)

	magic.ui:SetFocusElement(nil)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_TAB then
		set_free_look(not free_look)
	elseif key == magic.KEY_1 or key == magic.KEY_HOME then
		go_to_benchmark(1)
	elseif key == magic.KEY_2 then
		go_to_benchmark(2)
	elseif key == magic.KEY_3 then
		go_to_benchmark(3)
	elseif key == magic.KEY_ESCAPE then
		if free_look then
			set_free_look(false)
		end
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if not free_look then
		return
	end
	local dt = event_data:GetFloat("TimeStep")

	local dmouse = magic.input:GetMouseMove()
	yaw = yaw + dmouse.x * MOUSE_SENSITIVITY
	pitch = pitch + dmouse.y * MOUSE_SENSITIVITY
	if pitch > 89 then pitch = 89 end
	if pitch < -89 then pitch = -89 end

	-- Movement stays on the horizontal plane whatever the camera is looking
	-- at, so that pitching down to inspect the cave does not sink the camera
	-- into the ground. Space and Shift are the only way to change height.
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
	apply_angles(camera_node, yaw, pitch)
end)

log:info("voxel_lighting client ready; Tab = free move, 1/2/3 = benchmarks")
-- vim: set noet ts=4 sw=4:
