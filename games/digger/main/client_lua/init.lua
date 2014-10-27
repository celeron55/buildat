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

--local RENDER_DISTANCE = 640
local RENDER_DISTANCE = 480
--local RENDER_DISTANCE = 320
--local RENDER_DISTANCE = 240
--local RENDER_DISTANCE = 160

local FOG_END = RENDER_DISTANCE * 1.2

local PLAYER_HEIGHT = 1.7
local PLAYER_WIDTH = 0.9
local PLAYER_MASS = 70
local MOVE_SPEED = 10
local JUMP_SPEED = 7 -- Barely 2 voxels
local PLAYER_ACCELERATION = 40
local PLAYER_DECELERATION = 40

local scene = replicate.main_scene

local player_touches_ground = false
local player_crouched = false

local pointed_voxel_p = nil
local pointed_voxel_p_above = nil
local pointed_voxel_visual_node = scene:CreateChild("node")
local pointed_voxel_visual_geometry =
		pointed_voxel_visual_node:CreateComponent("CustomGeometry")
do
	pointed_voxel_visual_geometry:BeginGeometry(0, magic.TRIANGLE_LIST)
	pointed_voxel_visual_geometry:SetNumGeometries(1)
	local function define_face(lc, uc, color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(uc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, lc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
		pointed_voxel_visual_geometry:DefineVertex(
				magic.Vector3(lc.x, uc.y, uc.z))
		pointed_voxel_visual_geometry:DefineColor(color)
	end

	-- Full face
	--local d = 0.502
	--local c = magic.Color(0.04, 0.12, 0.04)
	--define_face(magic.Vector3(-d, d, -d), magic.Vector3(d, d, d), c)
	--pointed_voxel_visual_geometry:Commit()
	--local m = magic.Material.new()
	--m:SetTechnique(0, magic.cache:GetResource("Technique",
	--		"Techniques/NoTextureVColAdd.xml"))

	-- Face edges
	local d = 0.502
	local d2 = 1.0 / 16
	local c = magic.Color(0.12, 0.36, 0.12)
	define_face(magic.Vector3(-d, d, d-d2), magic.Vector3(d, d, d), c)
	define_face(magic.Vector3(-d, d, -d), magic.Vector3(d, d, -d+d2), c)
	define_face(magic.Vector3(d-d2, d, -d+d2), magic.Vector3(d, d, d-d2), c)
	define_face(magic.Vector3(-d, d, -d+d2), magic.Vector3(-d+d2, d, d-d2), c)
	pointed_voxel_visual_geometry:Commit()
	local m = magic.Material.new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureVColMultiply.xml"))

	pointed_voxel_visual_geometry:SetMaterial(0, m)
	pointed_voxel_visual_node.enabled = false
end

magic.input:SetMouseVisible(false)

-- Set up zone (global visual parameters)
---[[
do
	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(-1000, 1000)
	zone.ambientColor = magic.Color(0.1, 0.1, 0.1)
	--zone.ambientColor = magic.Color(0, 0, 0)
	zone.fogColor = magic.Color(0.6, 0.7, 0.8)
	--zone.fogColor = magic.Color(0, 0, 0)
	zone.fogStart = 10
	zone.fogEnd = FOG_END
	zone.priority = -1
	zone.override = true
end
--]]

-- Add lights
do
	--[[
	local dirs = {
		magic.Vector3( 1.0, -1.0,  1.0),
		magic.Vector3( 1.0, -1.0, -1.0),
		magic.Vector3(-1.0, -1.0, -1.0),
		magic.Vector3(-1.0, -1.0,  1.0),
	}
	for _, dir in ipairs(dirs) do
		local node = scene:CreateChild("DirectionalLight")
		node.direction = dir
		local light = node:CreateComponent("Light")
		light.lightType = magic.LIGHT_DIRECTIONAL
		light.castShadows = true
		light.brightness = 0.2
		light.color = magic.Color(0.7, 0.7, 1.0)
	end
	--]]

	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(-0.6, -1.0, 0.8)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = 0.8
	light.color = magic.Color(1.0, 1.0, 0.95)

	---[[
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(0.3, -1.0, -0.4)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = true
	light.brightness = 0.2
	light.color = magic.Color(0.7, 0.7, 1.0)
	--]]

	--[[
	local node = scene:CreateChild("DirectionalLight")
	node.direction = magic.Vector3(0.0, -1.0, 0.0)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_DIRECTIONAL
	light.castShadows = false
	light.brightness = 0.05
	light.color = magic.Color(1.0, 1.0, 1.0)
	--]]
end

-- Add a node that the player can use to walk around with
local player_node = scene:CreateChild("Player")
local player_shape = player_node:CreateComponent("CollisionShape")
do
	--player_node.position = magic.Vector3(0, 30, 0)
	--player_node.position = magic.Vector3(55, 30, 40)
	player_node.position = magic.Vector3(-5, 1, 257)
	player_node.direction = magic.Vector3(-1, 0, 0.4)
	---[[
	local body = player_node:CreateComponent("RigidBody")
	--body.mass = 70.0
	body.friction = 0
	--body.linearVelocity = magic.Vector3(0, -10, 0)
	body.angularFactor = magic.Vector3(0, 0, 0)
	body.gravityOverride = magic.Vector3(0, -15.0, 0) -- A bit more than normally
	--player_shape:SetBox(magic.Vector3(1, 1.7*PLAYER_SCALE, 1))
	player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
	--]]
end

-- Add a camera so we can look at the scene
local camera_node = player_node:CreateChild("Camera")
do
	camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT, 0)
	--camera_node:Pitch(13.60000)
	local camera = camera_node:CreateComponent("Camera")
	camera.nearClip = 0.5 * math.min(
			PLAYER_WIDTH * 0.15,
			PLAYER_HEIGHT * (0.5 - 0.411)
	)
	camera.farClip = RENDER_DISTANCE
	camera.fov = 75

	-- And this thing so the camera is shown on the screen
	local viewport = magic.Viewport:new(scene, camera_node:GetComponent("Camera"))
	magic.renderer:SetViewport(0, viewport)
end

-- Tell about the camera to the voxel world so it can do stuff based on the
-- camera's position and other properties
voxelworld.set_camera(camera_node)

---[[
-- Add a light to the camera
do
	local node = camera_node:CreateChild("Light")
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.castShadows = false
	light.brightness = 0.15
	light.color = magic.Color(1.0, 1.0, 1.0)
	light.range = 15.0
	light.fadeDistance = 15.0
end
--]]

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
local misc_text = magic.ui.root:CreateChild("Text")
local worldgen_text = magic.ui.root:CreateChild("Text")
do
	title_text:SetText("digger/init.lua")
	title_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
	title_text.horizontalAlignment = magic.HA_CENTER
	title_text.verticalAlignment = magic.VA_CENTER
	title_text:SetPosition(0, -magic.ui.root.height/2 + 20)

	misc_text:SetText("")
	misc_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
	misc_text.horizontalAlignment = magic.HA_CENTER
	misc_text.verticalAlignment = magic.VA_CENTER
	misc_text:SetPosition(0, -magic.ui.root.height/2 + 40)

	worldgen_text:SetText("")
	worldgen_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
	--[[worldgen_text.horizontalAlignment = magic.HA_LEFT
	worldgen_text.verticalAlignment = magic.VA_TOP
	worldgen_text:SetPosition(0, 0)--]]
	worldgen_text.horizontalAlignment = magic.HA_CENTER
	worldgen_text.verticalAlignment = magic.VA_CENTER
	worldgen_text:SetPosition(0, -magic.ui.root.height/2 + 60)
end

-- Unfocus UI
magic.ui:SetFocusElement(nil)

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESC then
		log:info("KEY_ESC pressed")
		buildat.disconnect()
	end
end)

-- Returns: nil or p_under, p_above: buildat.Vector3
-- TODO: This algorithm is quite wasteful
local function find_pointed_voxel(camera_node)
	local max_d = 6
	local d_per_step = 0.1
	local p0 = buildat.Vector3(camera_node.worldPosition)
	local dir = buildat.Vector3(camera_node.worldDirection)
	local last_p = nil
	--log:verbose("p0="..p0:dump()..", dir="..dir:dump())
	for i = 1, math.floor(max_d / d_per_step) do
		local p = (p0 + dir * i * d_per_step):round()
		if p ~= last_p then
			local v = voxelworld.get_static_voxel(p)
			--log:verbose("i="..i..": p="..p:dump()..", v.id="..v.id)
			if v.id ~= 1 and v.id ~= 0 then
				return p, last_p
			end
			last_p = p
		end
	end
	return nil
end

magic.SubscribeToEvent("MouseButtonDown", function(event_type, event_data)
	local button = event_data:GetInt("Button")
	log:info("MouseButtonDown: "..button)
	if button == magic.MOUSEB_RIGHT then
		local p = pointed_voxel_p_above
		if p then
			local data = cereal.binary_output({
				p = {
					x = math.floor(p.x+0.5),
					y = math.floor(p.y+0.5),
					z = math.floor(p.z+0.5),
				},
			}, {"object",
				{"p", {"object",
					{"x", "int32_t"},
					{"y", "int32_t"},
					{"z", "int32_t"},
				}},
			})
			buildat.send_packet("main:place_voxel", data)
		end
	end
	if button == magic.MOUSEB_LEFT then
		local p = pointed_voxel_p
		if p then
			local data = cereal.binary_output({
				p = {
					x = math.floor(p.x+0.5),
					y = math.floor(p.y+0.5 + 0.2),
					z = math.floor(p.z+0.5),
				},
			}, {"object",
				{"p", {"object",
					{"x", "int32_t"},
					{"y", "int32_t"},
					{"z", "int32_t"},
				}},
			})
			buildat.send_packet("main:dig_voxel", data)
		end
	end
	if button == magic.MOUSEB_MIDDLE then
		local p = player_node.position
		local v = voxelworld.get_static_voxel(p)
		log:info("get_static_voxel("..buildat.Vector3(p):dump()..")"..
				" returned v.id="..dump(v.id))
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	--log:info("Update")
	local dt = event_data:GetFloat("TimeStep")

	if camera_node then
		local p, p_above = find_pointed_voxel(camera_node)
		pointed_voxel_p = p
		pointed_voxel_p_above = p_above
		if p and p_above then
			local v = voxelworld.get_static_voxel(p)
			--log:info("pointed voxel: "..p:dump()..": "..v.id)
			pointed_voxel_visual_node.position = magic.Vector3.from_buildat(p)
			local d = p_above - p
			if d.x > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, -90)
			elseif d.x < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, 90)
			elseif d.y > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(0, 0, 0)
			elseif d.y < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(0, 0, -180)
			elseif d.z > 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(90, 0, 0)
			elseif d.z < 0 then
				pointed_voxel_visual_node.rotation =
						magic.Quaternion(-90, 0, 0)
			end
			pointed_voxel_visual_node.enabled = true
		else
			pointed_voxel_visual_node.enabled = false
		end
	end

	if player_node then
		-- If falling out of world, restore onto world
		if player_node.position.y < -500 then
			player_node.position = magic.Vector3(0, 500, 0)
		end

		local dmouse = magic.input:GetMouseMove()
		--log:info("dmouse: ("..dmouse.x..", "..dmouse.y..")")
		camera_node:Pitch(dmouse.y * 0.1)
		player_node:Yaw(dmouse.x * 0.1)
		--[[log:info("y="..player_node:GetRotation():YawAngle())
		log:info("p="..camera_node:GetRotation():PitchAngle())]]

		local body = player_node:GetComponent("RigidBody")

		do 
			local wanted_v = magic.Vector3(0, 0, 0) -- re. world
			do
				local wanted_v_re_body = magic.Vector3(0, 0, 0)
				if magic.input:GetKeyDown(magic.KEY_W) then
					wanted_v_re_body.x = wanted_v_re_body.x + 1
				end
				if magic.input:GetKeyDown(magic.KEY_S) then
					wanted_v_re_body.x = wanted_v_re_body.x - 1
				end
				if magic.input:GetKeyDown(magic.KEY_D) then
					wanted_v_re_body.z = wanted_v_re_body.z - 1
				end
				if magic.input:GetKeyDown(magic.KEY_A) then
					wanted_v_re_body.z = wanted_v_re_body.z + 1
				end
				wanted_v_re_body = wanted_v_re_body:Normalized() * MOVE_SPEED
				local u = player_node.direction
				local v = u:CrossProduct(magic.Vector3(0, 1, 0))
				wanted_v = wanted_v + u * wanted_v_re_body.x
				wanted_v = wanted_v + v * wanted_v_re_body.z
			end

			local current_v = body.linearVelocity
			current_v.y = 0

			local v_diff = (wanted_v - current_v) / MOVE_SPEED

			if v_diff:Length() > 0.1 then
				v_diff = v_diff:Normalized()
				local f = v_diff * dt * PLAYER_ACCELERATION * PLAYER_MASS
				body:ApplyImpulse(f)
			else
				local bv = body.linearVelocity
				bv.x = wanted_v.x
				bv.z = wanted_v.z
				body.linearVelocity = bv
			end
		end

		if magic.input:GetKeyDown(magic.KEY_SPACE) or
				magic.input:GetKeyPress(magic.KEY_SPACE) then
			if player_touches_ground and
					math.abs(body.linearVelocity.y) < JUMP_SPEED then
				local bv = body.linearVelocity
				bv.y = JUMP_SPEED
				body.linearVelocity = bv
			end
		end
		if magic.input:GetKeyDown(magic.KEY_SHIFT) then
			--local bv = body.linearVelocity
			--bv.y = -MOVE_SPEED
			--body.linearVelocity = bv

			-- Delay setting this to here so that it's possible to wait for the
			-- world to load first
			if body.mass == 0 then
				body.mass = PLAYER_MASS
			end

			if not player_crouched then
				player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT/2)
				camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT/2, 0)
				player_crouched = true
			end
		else
			if player_crouched then
				player_shape:SetCapsule(PLAYER_WIDTH, PLAYER_HEIGHT)
				player_node:Translate(magic.Vector3(0, PLAYER_HEIGHT/4, 0))
				camera_node.position = magic.Vector3(0, 0.411*PLAYER_HEIGHT, 0)
				player_crouched = false
			end
		end

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
	local voxel_reg = voxelworld.get_voxel_registry()
	local atlas_reg = voxelworld.get_atlas_registry()

	local data = node:GetVar("simple_voxel_data"):GetBuffer()
	local w = node:GetVar("simple_voxel_w"):GetInt()
	local h = node:GetVar("simple_voxel_h"):GetInt()
	local d = node:GetVar("simple_voxel_d"):GetInt()
	log:info(dump(node:GetName()).." voxel data size: "..data:GetSize())
	buildat.set_8bit_voxel_geometry(node, w, h, d, data, voxel_reg, atlas_reg)
end

voxelworld.sub_ready(function()
	-- Subscribe to this only after the voxelworld is ready because we are using
	-- voxelworld's registries
	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("simple_voxel_data"):IsEmpty() then
			setup_simple_voxel_data(node)
		end
		local name = node:GetName()
	end)
end)

buildat.sub_packet("main:worldgen_queue_size", function(data)
	local queue_size = tonumber(data)
	if queue_size > 0 then
		worldgen_text:SetText("Worldgen queue size: "..queue_size)
	else
		worldgen_text:SetText("")
	end
end)

-- vim: set noet ts=4 sw=4:
