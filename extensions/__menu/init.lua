-- Buildat: extension/__menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/__menu")
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
local dump = buildat.dump
local M = {safe = nil}
log:info("extension/__menu/init.lua: Loading")

local ui_stack = uistack.UIStack(ui.root)

local function launch_connect_to_server()
	local root = ui_stack:push()

	local style = cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	root.defaultStyle = style

	local layout = root:CreateChild("Window")
	layout:SetStyleAuto()
    layout:SetName("Layout")
    layout:SetLayout(LM_HORIZONTAL, 20, IntRect(0, 0, 0, 0))
    layout:SetAlignment(HA_CENTER, VA_CENTER)

	magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
		if root:HasRecursiveFocus() then
			local key = event_data:GetInt("Key")
			if key == KEY_ESC then
				log:info("KEY_ESC pressed at connect_to_server level")
				ui_stack:pop(root)
			end
		end
	end)
end

function M.boot()
	local root = ui_stack:push()

	local style = cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	root.defaultStyle = style

	local layout = root:CreateChild("Window")
	layout:SetStyleAuto()
    layout:SetName("Layout")
    layout:SetLayout(LM_HORIZONTAL, 20, IntRect(0, 0, 0, 0))
    layout:SetAlignment(HA_CENTER, VA_CENTER)

	local button = layout:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
    button:SetLayout(LM_VERTICAL, 10, IntRect(0, 0, 0, 0))
    local button_image = button:CreateChild("Sprite")
    button_image:SetName("ButtonImage")
	button_image:SetTexture(
			cache:GetResource("Texture2D", "__menu/res/icon_network.png"))
	button_image.color = Color(.3, .3, .3)
	button_image:SetFixedSize(200, 200)
    local button_text = button:CreateChild("Text")
    button_text:SetName("ButtonText")
	button_text:SetStyleAuto()
    button_text.text = "Connect to server"
	button_text.color = Color(.3, .3, .3)
    button_text:SetAlignment(HA_CENTER, VA_CENTER)
    button_text:SetTextAlignment(HA_CENTER)

	magic.SubscribeToEvent(button, "HoverBegin",
	function(self, event_type, event_data)
		self:GetChild("ButtonImage").color = Color(1, 1, 1)
		self:GetChild("ButtonText").color = Color(1, 1, 1)
	end)
	magic.SubscribeToEvent(button, "HoverEnd",
	function(self, event_type, event_data)
		self:GetChild("ButtonImage").color = Color(.3, .3, .3)
		self:GetChild("ButtonText").color = Color(.3, .3, .3)
	end)
	magic.SubscribeToEvent(button, "Released",
	function(self, event_type, event_data)
		log:info("Button clicked: \"Connect to server\"")
		launch_connect_to_server()
	end)

	magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
		if root:HasRecursiveFocus() then
			local key = event_data:GetInt("Key")
			if key == KEY_ESC then
				log:info("KEY_ESC pressed at top level; quitting")
				engine:Exit()
			end
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
