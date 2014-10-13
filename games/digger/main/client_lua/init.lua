-- Buildat: digger/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("digger")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")

local PLAYER_HEIGHT = 1.7
local PLAYER_WIDTH = 0.9
local MOVE_SPEED = 10
local JUMP_SPEED = 7 -- Barely 2 voxels

local scene = replicate.main_scene

magic.input:SetMouseVisible(false)

local zone_node = scene:CreateChild("Zone")
local zone = zone_node:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(-1000, 1000)
--zone.ambientColor = magic.Color(0.5, 0.7, 0.9)
zone.fogColor = magic.Color(0.6, 0.7, 0.8)
zone.fogStart = 10
zone.fogEnd = 300

-- Add a node that the player can use to walk around with
local player_node = scene:CreateChild("Player")
--player_node.position = magic.Vector3(0, 30, 0)
player_node.position = magic.Vector3(55, 30, 40)
---[[
local body = player_node:CreateComponent("RigidBody")
body.mass = 70.0
body.friction = 0
--body.linearVelocity = magic.Vector3(0, -10, 0)
body.angularFactor = magic.Vector3(0, 0, 0)
body.gravityOverride = magic.Vector3(0, -15.0, 0) -- A bit more than normally
local shape = player_node:CreateComponent("CollisionShape")
--shape:SetBox(magic.Vector3(1, 1.7*PLAYER_SCALE, 1))
shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
--]]

local player_touches_ground = false

--[[local other_node = scene:CreateChild("Other")
other_node.position = magic.Vector3(0, 10, 0)
local body = other_node:CreateComponent("RigidBody")
body.mass = 0
--body.friction = 0.7
local shape = other_node:CreateComponent("CollisionShape")
shape:SetBox(magic.Vector3(50, 1, 50))]]

--[[
-- Add a camera so we can look at the scene
local camera_node = scene:CreateChild("Camera")
camera_node.position = magic.Vector3(70.0, 50.0, 70.0)
camera_node:LookAt(magic.Vector3(0, -5, 0))
local camera = camera_node:CreateComponent("Camera")
camera.nearClip = 1.0
camera.farClip = 500.0
--]]

-- Add a camera so we can look at the scene
local camera_node = player_node:CreateChild("Camera")
camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT, 0)
local camera = camera_node:CreateComponent("Camera")
camera.nearClip = 0.3
camera.farClip = 500.0
camera.fov = 75

-- And this thing so the camera is shown on the screen
local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
magic.renderer:SetViewport(0, viewport)

voxelworld.set_camera(camera_node)

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("digger/init.lua")
title_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_CENTER
title_text:SetPosition(0, -magic.ui.root.height/2 + 20)

local misc_text = magic.ui.root:CreateChild("Text")
misc_text:SetText("")
misc_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
misc_text.horizontalAlignment = magic.HA_CENTER
misc_text.verticalAlignment = magic.VA_CENTER
misc_text:SetPosition(0, -magic.ui.root.height/2 + 40)

magic.ui:SetFocusElement(nil)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESC then
		log:info("KEY_ESC pressed")
		buildat.disconnect()
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	--log:info("Update")
	if player_node then
		local dmouse = magic.input:GetMouseMove()
		--log:info("dmouse: ("..dmouse.x..", "..dmouse.y..")")
		camera_node:Pitch(dmouse.y * 0.1)
		player_node:Yaw(dmouse.x * 0.1)

		local body = player_node:GetComponent("RigidBody")

		local wanted_v = magic.Vector3(0, 0, 0)

		if magic.input:GetKeyDown(magic.KEY_W) then
			wanted_v.x = wanted_v.x + 1
		end
		if magic.input:GetKeyDown(magic.KEY_S) then
			wanted_v.x = wanted_v.x - 1
		end
		if magic.input:GetKeyDown(magic.KEY_D) then
			wanted_v.z = wanted_v.z - 1
		end
		if magic.input:GetKeyDown(magic.KEY_A) then
			wanted_v.z = wanted_v.z + 1
		end

		wanted_v = wanted_v:Normalized() * MOVE_SPEED

		if magic.input:GetKeyDown(magic.KEY_SPACE) or
				magic.input:GetKeyPress(magic.KEY_SPACE) then
			if player_touches_ground and
					math.abs(body.linearVelocity.y) < JUMP_SPEED then
				wanted_v.y = wanted_v.y + JUMP_SPEED
			end
		end
		if magic.input:GetKeyDown(magic.KEY_SHIFT) then
			wanted_v.y = wanted_v.y - MOVE_SPEED
		end

		local u = player_node.direction
		local v = u:CrossProduct(magic.Vector3(0, 1, 0))
		local bv = body.linearVelocity
		bv.x = 0
		bv.z = 0
		if wanted_v.y ~= 0 then
			bv.y = 0
		end
		bv = bv + u * wanted_v.x
		bv = bv + v * wanted_v.z
		bv = bv + magic.Vector3(0, 1, 0) * wanted_v.y
		body.linearVelocity = bv

		local p = player_node:GetWorldPosition()
		misc_text:SetText("("..math.floor(p.x + 0.5)..", "..
				math.floor(p.y + 0.5)..", "..math.floor(p.z + 0.5)..")")
	end

	player_touches_ground = false
end)

magic.SubscribeToEvent("PhysicsCollision", function(event_type, event_data)
	--log:info("PhysicsCollision")
	local node_a = event_data:GetPtr("Node", "NodeA")
	local node_b = event_data:GetPtr("Node", "NodeB")
	local contacts = event_data:GetBuffer("Contacts")
	if node_a:GetID() == player_node:GetID() or
			node_b:GetID() == player_node:GetID() then
		while not contacts.eof do
			local position = contacts:ReadVector3()
			local normal = contacts:ReadVector3()
			local distance = contacts:ReadFloat()
			local impulse = contacts:ReadFloat()
			--log:info("normal: ("..normal.x..", "..normal.y..", "..normal.z..")")
			if normal.y < 0.5 then
				player_touches_ground = true
			end
		end
	end
end)

function setup_simple_voxel_data(node)
	local data = node:GetVar("simple_voxel_data"):GetBuffer()
	local w = node:GetVar("simple_voxel_w"):GetInt()
	local h = node:GetVar("simple_voxel_h"):GetInt()
	local d = node:GetVar("simple_voxel_d"):GetInt()
	log:info(dump(node:GetName()).." voxel data size: "..data:GetSize())
	buildat.set_8bit_voxel_geometry(node, w, h, d, data)
	node:SetScale(magic.Vector3(1, 1, 1))
end

replicate.sub_sync_node_added({}, function(node)
	if not node:GetVar("simple_voxel_data"):IsEmpty() then
		setup_simple_voxel_data(node)
	end
	local name = node:GetName()
end)

-- vim: set noet ts=4 sw=4:
