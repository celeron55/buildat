-- Buildat: extension/__menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/__menu")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local dump = buildat.dump
local M = {safe = nil}
log:info("extension/__menu/init.lua: Loading")

local ui_stack = uistack.main

local function show_error(message)
	local root = ui_stack:push({desc="show_error"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("show_error window")
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetName("message_text")
	message_text:SetStyleAuto()
	message_text.text = message
	message_text:SetTextAlignment(HA_CENTER)

	local ok_button = window:CreateChild("Button")
	ok_button:SetStyleAuto()
	ok_button:SetName("Button")
	ok_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	ok_button.minHeight = 20
	local ok_button_text = ok_button:CreateChild("Text")
	ok_button_text:SetName("ButtonText")
	ok_button_text:SetStyleAuto()
	ok_button_text.text = "Ok"
	ok_button_text:SetTextAlignment(HA_CENTER)
	ok_button:SetFocus(true)

	magic.SubscribeToEvent(ok_button, "Released",
	function(self, event_type, event_data)
		log:info("ok_button: Released")
		ui_stack:pop(root)
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("KEY_ESC pressed at show_error level")
			ui_stack:pop(root)
		end
	end)
end

local function show_connect_to_server()
	local root = ui_stack:push({desc="connect_to_server"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("connect_to_server window")
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local line_edit = window:CreateChild("LineEdit")
	line_edit:SetStyleAuto()
	line_edit:SetName("connect_to_server line_edit")
	line_edit.minHeight = 24
	line_edit.minWidth = 300
	line_edit:SetText("localhost:20000")
	line_edit:SetFocus(true)

	local connect_button = window:CreateChild("Button")
	connect_button:SetStyleAuto()
	connect_button:SetName("Button")
	connect_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	connect_button.minHeight = 20
	local connect_button_text = connect_button:CreateChild("Text")
	connect_button_text:SetName("ButtonText")
	connect_button_text:SetStyleAuto()
	connect_button_text.text = "Connect"
	connect_button_text:SetTextAlignment(HA_CENTER)

	function connect_or_show_error(address)
		local ok, err = buildat.connect_server(line_edit:GetText())
		if ok then
			log:info("buildat.connect_server() returned true")
			local root = ui_stack:push({desc="empty (game is running)"})
			magic.ui:SetFocusElement(nil)
		else
			log:info("buildat.connect_server() returned false")
			show_error(err)
		end
	end

	magic.SubscribeToEvent(connect_button, "Released",
	function(self, event_type, event_data)
		log:info("connect_button: Released")
		connect_or_show_error(line_edit:GetText())
	end)

	magic.SubscribeToEvent(line_edit, "TextFinished",
	function(self, event_type, event_data)
		log:info("line_edit: TextFinished")
		connect_or_show_error(line_edit:GetText())
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("KEY_ESC pressed at connect_to_server level")
			ui_stack:pop(root)
		end
	end)
end

function M.boot()
	local root = ui_stack:push("boot")

	local style = magic.cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	root.defaultStyle = style

	local layout = root:CreateChild("Window")
	layout:SetStyleAuto()
	layout:SetName("Layout")
	layout:SetLayout(LM_HORIZONTAL, 20, magic.IntRect(0, 0, 0, 0))
	layout:SetAlignment(HA_LEFT, VA_CENTER)

	local button = layout:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	local button_image = button:CreateChild("Sprite")
	button_image:SetName("ButtonImage")
	button_image:SetTexture(
			magic.cache:GetResource("Texture2D", "__menu/res/icon_network.png"))
	button_image.color = magic.Color(.3, .3, .3)
	button_image:SetFixedSize(200, 200)
	local button_text = button:CreateChild("Text")
	button_text:SetName("ButtonText")
	button_text:SetStyleAuto()
	button_text.text = "Connect to server"
	button_text.color = magic.Color(.3, .3, .3)
	button_text:SetAlignment(HA_CENTER, VA_TOP)
	button_text:SetTextAlignment(HA_CENTER)

	magic.SubscribeToEvent(button, "HoverBegin",
	function(self, event_type, event_data)
		self:GetChild("ButtonImage").color = magic.Color(1, 1, 1)
		self:GetChild("ButtonText").color = magic.Color(1, 1, 1)
	end)
	magic.SubscribeToEvent(button, "HoverEnd",
	function(self, event_type, event_data)
		self:GetChild("ButtonImage").color = magic.Color(.3, .3, .3)
		self:GetChild("ButtonText").color = magic.Color(.3, .3, .3)
	end)
	magic.SubscribeToEvent(button, "Released",
	function(self, event_type, event_data)
		log:info("Button clicked: \"Connect to server\"")
		show_connect_to_server()
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("KEY_ESC pressed at top level")
			engine:Exit()
		end
		if key == KEY_RETURN then
			log:info("RETURN pressed at top level")
			show_connect_to_server()
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
