-- Buildat: entitytest/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("entitytest")
local dump = buildat.dump
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")

-- 3D things

-- Viewport 0 is created in C++. It is set to view the network-synchronized
-- scene with one camera.
-- NOTE: This won't work this way in the future.
local viewport = magic.renderer:GetViewport(0)
local scene = viewport:GetScene()
local camera = viewport:GetCamera()
scene:CreateComponent("Octree")

--[[
-- Note that naming the scene nodes is optional
local plane_node = scene:CreateChild("Plane")
plane_node.scale = magic.Vector3(10.0, 1.0, 10.0)
local plane_object = plane_node:CreateComponent("StaticModel")
plane_object.model = magic.cache:GetResource("Model", "Models/Plane.mdl")
plane_object.material = magic.cache:GetResource("Material", "Materials/Stone.xml")
plane_object.material:SetTexture(magic.TU_DIFFUSE,
		magic.cache:GetResource("Texture2D", "main/green_texture.png"))

local light_node = scene:CreateChild("DirectionalLight")
light_node.direction = magic.Vector3(-0.6, -1.0, 0.8) -- The direction vector does not need to be normalized
local light = light_node:CreateComponent("Light")
light.lightType = magic.LIGHT_DIRECTIONAL
light.castShadows = true
light.shadowBias = magic.BiasParameters(0.00025, 0.5)
light.shadowCascade = magic.CascadeParameters(10.0, 50.0, 200.0, 0.0, 0.8)
light.brightness = 0.8

light_node = scene:CreateChild("DirectionalLight")
light_node.direction = magic.Vector3(0.6, -1.0, -0.8) -- The direction vector does not need to be normalized
light = light_node:CreateComponent("Light")
light.lightType = magic.LIGHT_DIRECTIONAL
light.brightness = 0.2
--]]

-- Add some text
local title_text = magic.ui.root:CreateChild("Text")
title_text:SetText("entitytest/init.lua")
title_text:SetFont(magic.cache:GetResource("Font", "Fonts/Anonymous Pro.ttf"), 15)
title_text.horizontalAlignment = magic.HA_CENTER
title_text.verticalAlignment = magic.VA_CENTER
title_text:SetPosition(0, magic.ui.root.height*(-0.33))

magic.ui:SetFocusElement(nil)

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESC then
		log:info("KEY_ESC pressed")
		buildat.disconnect()
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

-- vim: set noet ts=4 sw=4:
