-- Buildat: test1/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("test1")
local dump = buildat.dump
log:info("test1/init.lua loaded")

-- 3D things

-- NOTE: Create global variable so that it doesn't get automatically deleted
scene_ = Scene()
scene_:CreateComponent("Octree")

-- Note that naming the scene nodes is optional
local plane_node = scene_:CreateChild("Plane")
plane_node.scale = Vector3(10.0, 1.0, 10.0)
local plane_object = plane_node:CreateComponent("StaticModel")
plane_object.model = cache:GetResource("Model", "Models/Plane.mdl")
plane_object.material = cache:GetResource("Material", "Materials/StoneTiled.xml")

local light_node = scene_:CreateChild("DirectionalLight")
light_node.direction = Vector3(0.6, -1.0, 0.8) -- The direction vector does not need to be normalized
local light = light_node:CreateComponent("Light")
light.lightType = LIGHT_DIRECTIONAL

-- Add a camera so we can look at the scene
camera_node = scene_:CreateChild("Camera")
camera_node:CreateComponent("Camera")
camera_node.position = Vector3(7.0, 7.0, 7.0)
--camera_node.rotation = Quaternion(0, 0, 0.0)
camera_node:LookAt(Vector3(0, 1, 0))
-- And this thing so the camera is shown on the screen
local viewport = Viewport:new(scene_, camera_node:GetComponent("Camera"))
renderer:SetViewport(0, viewport)

-- Add some text
local title_text = ui.root:CreateChild("Text")
title_text:SetText("test1/init.lua")
title_text:SetFont(cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
title_text.horizontalAlignment = HA_CENTER
title_text.verticalAlignment = VA_CENTER
title_text:SetPosition(0, ui.root.height*(-0.33))

local cereal = require("buildat/extension/cereal")

local the_box = nil

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
	local node = scene_:CreateChild("THE GLORIOUS BOX")
	the_box = node
	node.scale = Vector3(w, h, d)
	node.position = Vector3(x, y, z)

	-- 2) Create a StaticModel which kind of is what we need
	local object = node:CreateComponent("StaticModel")

	-- 3) First it needs a model. We could just load this binaray blob:
	object.model = cache:GetResource("Model", "Models/Box.mdl")
	-- TODO: let's not. Let's generate some geometry!
	--[[local cc = CustomGeometry()
	cc.SetNumGeometries(1)
	cc.BeginGeometry(0, TRIANGLE_STRIP)
	cc.DefineVertex(]]

	-- 4) Create a material. Again we could just load it from a file:
	--object.material = cache:GetResource("Material", "Materials/Stone.xml"):Clone()
	-- ...but let's create a material ourselves:
	g_m = Material() -- It has to be global because deletion causes a crash
	object.material = g_m
	-- We use this Diff.xml file to define that we want diffuse rendering. It
	-- doesn't make much sense to define it ourselves as it consists of quite many
	-- parameters:
	object.material:SetTechnique(0, cache:GetResource("Technique", "Techniques/Diff.xml"))
	-- And load the texture from a file:
	object.material:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", "Textures/LogoLarge.png"))

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
    if ui.focusElement ~= nil then
        return
    end

    local MOVE_SPEED = 6.0
    local MOUSE_SENSITIVITY = 0.01

	if the_box then
		local p = the_box.position
		p.y = Clamp(p.y - input.mouseMove.y * MOUSE_SENSITIVITY, 0, 5)
		the_box.position = p -- Needed?
	end

    if input:GetKeyDown(KEY_W) then
        the_box:Translate(Vector3(-1.0, 0.0, 0.0) * MOVE_SPEED * dt)
    end
    if input:GetKeyDown(KEY_S) then
        the_box:Translate(Vector3(1.0, 0.0, 0.0) * MOVE_SPEED * dt)
    end
    if input:GetKeyDown(KEY_A) then
        the_box:Translate(Vector3(0.0, 0.0, -1.0) * MOVE_SPEED * dt)
    end
    if input:GetKeyDown(KEY_D) then
        the_box:Translate(Vector3(0.0, 0.0, 1.0) * MOVE_SPEED * dt)
    end
end

function handle_update(eventType, eventData)
	--log:info("handle_update() in test1/init.lua")
	local dt = eventData:GetFloat("TimeStep")
	--node:Rotate(Quaternion(50, 80*dt, 0, 0))
	move_box_by_user_input(dt)
end
SubscribeToEvent("Update", "handle_update")

