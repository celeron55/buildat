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

magic.sub_sync_node_added({}, function(node)
	local name = node:GetName()
	if name == "Box" then
		-- Models and materials can be created dynamically on the client side
		-- like this
		local object = node:CreateComponent("StaticModel", magic.LOCAL)
		object.model = magic.cache:GetResource("Model", "Models/Box.mdl")
		object.material = magic.Material:new()
		object.material:SetTechnique(0,
				magic.cache:GetResource("Technique", "Techniques/Diff.xml"))
		object.material:SetTexture(magic.TU_DIFFUSE,
				magic.cache:GetResource("Texture2D", "main/pink_texture.png"))
		object.castShadows = true
	end
end)

-- vim: set noet ts=4 sw=4:
