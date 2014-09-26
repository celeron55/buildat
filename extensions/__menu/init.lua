-- Buildat: extension/__menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/__menu")
local magic = require("buildat/extension/urho3d")
local dump = buildat.dump
local M = {safe = nil}
log:info("extension/__menu/init.lua: Loading")

local ui_stack_name_i = 1  -- For generating a unique name for each stack
local function UIStack(root)
	local self = {}
	self.root = root
	self.stack_name = "ui_stack_"..ui_stack_name_i
	ui_stack_name_i = ui_stack_name_i + 1
	self.element_name_i = 1
	self.stack = {}
	function self:push()
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			top:SetVisible(false)
		end
		local element_name = self.stack_name.."_"..self.element_name_i
		local element = self.root:CreateChild("UIElement")
		element:SetName(element_name)
		element:SetStyleAuto()
    	element:SetLayout(LM_HORIZONTAL, 0, IntRect(0, 0, 0, 0))
    	element:SetAlignment(HA_CENTER, VA_CENTER)
		self.element_name_i = self.element_name_i + 1
		table.insert(self.stack, element)
		return element
	end
	function self:pop()
		local top = table.remove(self.stack)
		self.root:RemoveChild(top)
		if #self.stack >= 1 then
			local top = self.stack[#self.stack]
			top:SetVisible(true)
		end
	end
	return self
end

local ui_stack = UIStack(ui.root)

local function launch_connect_to_server()
end

function M.boot()
	local style = cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	ui.root.defaultStyle = style

	local root = ui_stack:push()

    local test_element = root:CreateChild("Sprite")
	test_element:SetTexture(
			cache:GetResource("Texture2D", "__menu/res/icon_network.png"))
	test_element.color = Color(.2, .2, .2)
	test_element:SetFixedSize(400, 400)

	local root = ui_stack:push()

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
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("KEY_ESC pressed; quitting")
			engine:Exit()
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
