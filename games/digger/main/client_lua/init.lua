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

local scene = replicate.main_scene

-- Add a camera so we can look at the scene
local camera_node = scene:CreateChild("Camera")
local camera = camera_node:CreateComponent("Camera")
camera.nearClip = 1.0
camera.farClip = 500.0
--camera_node.position = magic.Vector3(10.0, 10.0, 10.0)
--camera_node.position = magic.Vector3(60.0, 60.0, 60.0)
camera_node.position = magic.Vector3(70.0, 50.0, 70.0)
camera_node:LookAt(magic.Vector3(0, -5, 0))

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
