-- Buildat: extension/__menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/__menu")
local magic = require("buildat/extension/urho3d")
local dump = buildat.dump
local M = {safe = nil}
log:info("extension/__menu/init.lua: Loading")

function M.boot()
	local style = cache:GetResource("XMLFile", "UI/DefaultStyle.xml")
	ui.root.defaultStyle = style

	window = Window:new()
	window:SetStyleAuto()
	ui.root:AddChild(window)
	window:SetMinSize(384, 192)
	window:SetLayout(LM_HORIZONTAL, 6, IntRect(6, 6, 6, 6))
	window:SetAlignment(HA_CENTER, VA_CENTER)
	window:SetName("Window")
	
	local checkBox = CheckBox:new()
	checkBox:SetName("CheckBox")
	checkBox:SetStyleAuto()
	window:AddChild(checkBox)

	local button = Button:new()
	button:SetStyleAuto()
	button:SetName("Button")
	button.Height = 200
	button.Width = 200
	window:AddChild(button)
	--[[local font = cache:GetResource("Font", "Fonts/Anonymous Pro.ttf")
	local buttonText = button:CreateChild("Text")
	buttonText:SetAlignment(magic.HA_CENTER, magic.HA_CENTER)
	buttonText.text = "Button Text"
	buttonText:SetFont(font)]]
	local buttonImage = button:CreateChild("Sprite")
	--buttonImage:SetTexture(cache:GetResource("Texture2D", "Textures/LogoLarge.png"))
	buttonImage:SetTexture(cache:GetResource("Texture2D", "__menu/res/icon_network.png"))
	buttonImage:SetAlignment(magic.HA_CENTER, magic.HA_CENTER)
	buttonImage:SetSize(200, 200)

	local lineEdit = LineEdit:new()
	lineEdit:SetStyleAuto()
	lineEdit:SetName("LineEdit")
	lineEdit.minHeight = 24
	window:AddChild(lineEdit)

	magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("KEY_ESC pressed; quitting")
			engine:Exit()
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
