-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("ui_utils")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local M = {safe = {}}

-- API naming:
-- show_*_notification()
-- show_*_dialog()
-- show_*_window() (?)

local message_handle = nil

function M.safe.show_message_dialog(message)
	-- Don't stack multiple dialogs
	if message_handle then
		message_handle.append(message)
		return
	end

	local root = uistack.main:push({desc="show_message_dialog"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetName("show_message_dialog window")
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetName("message_text")
	message_text:SetStyleAuto()
	message_text.text = message
	message_text:SetTextAlignment(HA_LEFT)

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

	message_handle = {
		append = function(text)
			if #message_text.text < 1000 then
				message_text.text = message_text.text.."\n"..text
			end
		end,
	}

	magic.SubscribeToEvent(ok_button, "Released",
	function(self, event_type, event_data)
		log:info("show_message_dialog: ok_button clicked")
		uistack.main:pop(root)
		message_handle = nil
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESC then
			log:info("show_message_dialog: KEY_ESC pressed")
			uistack.main:pop(root)
			message_handle = nil
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
