-- Buildat: uitest/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("uitest")
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
log:info("uitest/init.lua loaded")

local ui_stack = uistack.main

function show_stuff()
	local root = ui_stack:push({desc="uitest root"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("window")
	window:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetName("message_text")
	message_text:SetStyleAuto()
	message_text.text = "Stuff"
	message_text:SetTextAlignment(magic.HA_CENTER)
end

show_stuff()

function handle_keydown(event_type, event_data)
	local key = event_data:GetInt("Key")
	if key == magic.KEY_ESC then
		log:info("KEY_ESC pressed")
		buildat.disconnect()
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

-- vim: set noet ts=4 sw=4:
