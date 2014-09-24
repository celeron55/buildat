-- Buildat: test1/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("test1")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local u3d = require("buildat/extension/urho3d")
log:info("test1/init.lua loaded")

-- 3D things

-- NOTE: Create global variable so that it doesn't get automatically deleted
local scene = u3d.Scene()
scene:CreateComponent("Octree")

-- Note that naming the scene nodes is optional
local plane_node = scene:CreateChild("Plane")
plane_node.scale = u3d.Vector3(10.0, 1.0, 10.0)
local plane_object = plane_node:CreateComponent("StaticModel")
plane_object.model = u3d.cache:GetResource("Model", "Models/Plane.mdl")
plane_object.material = u3d.cache:GetResource("Material", "Materials/Stone.xml")
plane_object.material:SetTexture(u3d.TU_DIFFUSE,
		u3d.cache:GetResource("Texture2D", "test1/green_texture.png"))

local light_node = scene:CreateChild("DirectionalLight")
light_node.direction = u3d.Vector3(-0.6, -1.0, 0.8) -- The direction vector does not need to be normalized
local light = light_node:CreateComponent("Light")
light.lightType = u3d.LIGHT_DIRECTIONAL

-- Add a camera so we can look at the scene
camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
camera_node.position = u3d.Vector3(7.0, 7.0, 7.0)
--camera_node.rotation = Quaternion(0, 0, 0.0)
camera_node:LookAt(u3d.Vector3(0, 1, 0))
-- And this thing so the camera is shown on the screen
local viewport = u3d.Viewport:new(scene, camera_node:GetComponent("Camera"))
u3d.renderer:SetViewport(0, viewport)

-- Add some text
local title_text = u3d.ui.root:CreateChild("Text")
title_text:SetText("test1/init.lua")
title_text:SetFont(u3d.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
title_text.horizontalAlignment = u3d.HA_CENTER
title_text.verticalAlignment = u3d.VA_CENTER
title_text:SetPosition(0, u3d.ui.root.height*(-0.33))

the_box = nil

buildat.sub_packet("test1:add_box", function(data)
	local values = cereal.binary_input(data, {"object",
		{"w", "double"},
		{"h", "double"},
		{"d", "double"},
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
	})
	local w = values.w
	local h = values.h
	local d = values.d
	local x = values.x
	local y = values.y
	local z = values.z
	log:info("values="..dump(values))

	--
	-- Mission: Make a box
	--

	-- 1) Make the entity in the scene
	local node = scene:CreateChild("THE GLORIOUS BOX")
	the_box = node
	node.scale = u3d.Vector3(w, h, d)
	node.position = u3d.Vector3(x, y, z)

	-- 2) Create a StaticModel which kind of is what we need
	local object = node:CreateComponent("StaticModel")

	-- 3) First it needs a model. We could just load this binaray blob:
	object.model = u3d.cache:GetResource("Model", "Models/Box.mdl")
	assert(object.model)
	-- TODO: let's not. Let's generate some geometry!
	--[[local cc = CustomGeometry()
	cc.SetNumGeometries(1)
	cc.BeginGeometry(0, TRIANGLE_STRIP)
	cc.DefineVertex(]]

	-- 4) Create a material. Again we could just load it from a file:
	--object.material = u3d.cache:GetResource("Material", "Materials/Stone.xml")
	-- ...but let's create a material ourselves:
	-- Call buildat.store_inifnitely() because deletion of it causes a crash
	object.material = u3d.Material:new()
	-- We use this Diff.xml file to define that we want diffuse rendering. It
	-- doesn't make much sense to define it ourselves as it consists of quite many
	-- parameters:
	object.material:SetTechnique(0,
			u3d.cache:GetResource("Technique", "Techniques/Diff.xml"))
	-- And load the texture from a file:
	object.material:SetTexture(u3d.TU_DIFFUSE,
			u3d.cache:GetResource("Texture2D", "test1/pink_texture.png"))

	--
	-- Make a non-useful but nice reply packet and send it to the server
	--

	values = {
		a = 128,
		b = 1000,
		c = 3.14,
		d = "Foo",
		e = {"Bar1", "Bar2"},
		f = {x=1, y=2},
	}
	data = cereal.binary_output(values, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	buildat.send_packet("test1:box_added", data)

	-- Try deserializing it too and see if all is working
	values = cereal.binary_input(data, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	assert(values.a == 128)
	assert(values.b == 1000)
	assert(values.c == 3.14)
	assert(values.d == "Foo")
	assert(values.e[2] == "Bar2")
	assert(values.f.y == 2)
end)

function move_box_by_user_input(dt)
    -- Do not move if the UI has a focused element (the console)
    if u3d.ui.focusElement ~= nil then
        return
    end

    local MOVE_SPEED = 6.0
    local MOUSE_SENSITIVITY = 0.005

	if the_box then
		--local p = the_box.position
		--p.y = u3d.Clamp(p.y - u3d.input.mouseMove.y * MOUSE_SENSITIVITY, 0.5, 6)
		--the_box.position = p -- Needed?

		if u3d.input:GetKeyDown(u3d.KEY_UP) then
			the_box:Translate(u3d.Vector3(-1.0, 0.0, 0.0) * MOVE_SPEED * dt)
		end
		if u3d.input:GetKeyDown(u3d.KEY_DOWN) then
			the_box:Translate(u3d.Vector3(1.0, 0.0, 0.0) * MOVE_SPEED * dt)
		end
		if u3d.input:GetKeyDown(u3d.KEY_LEFT) then
			the_box:Translate(u3d.Vector3(0.0, 0.0, -1.0) * MOVE_SPEED * dt)
		end
		if u3d.input:GetKeyDown(u3d.KEY_RIGHT) then
			the_box:Translate(u3d.Vector3(0.0, 0.0, 1.0) * MOVE_SPEED * dt)
		end
	end
end

function handle_update(eventType, eventData)
	--log:info("handle_update() in test1/init.lua")
	local dt = eventData:GetFloat("TimeStep")
	--node:Rotate(Quaternion(50, 80*dt, 0, 0))
	move_box_by_user_input(dt)
end
u3d.SubscribeToEvent("Update", "handle_update")

-- vim: set noet ts=4 sw=4:
