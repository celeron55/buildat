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
-- vertical_menu() / bind_button_menu()

-- One selected index for mouse hover and arrow keys. Button.selected uses
-- pressedOffset; native hover would still highlight the mouse-over item if
-- arrows move elsewhere, so copy hoverOffset onto pressedOffset and clear it.
local function button_menu_nav(root)
	local items = {}
	local selected = 1
	local on_other_key = nil

	local function apply()
		for i, item in ipairs(items) do
			item.button.selected = (i == selected)
		end
	end

	local function select_i(i)
		local n = #items
		if n == 0 then
			return
		end
		if i < 1 then
			i = n
		elseif i > n then
			i = 1
		end
		selected = i
		apply()
	end

	local nav = {}

	function nav:add(button, action)
		if button == nil or action == nil then
			error("button_menu: add() needs a button and an action")
		end
		local i = #items + 1
		items[i] = {button = button, action = action}
		local hover = button.hoverOffset
		button.pressedOffset = magic.IntVector2(hover.x, hover.y)
		button.hoverOffset = magic.IntVector2(0, 0)
		magic.SubscribeToEvent(button, "Released",
		function(self, event_type, event_data)
			action()
		end)
		magic.SubscribeToEvent(button, "HoverBegin",
		function(self, event_type, event_data)
			select_i(i)
		end)
		apply()
		return button
	end

	function nav:on_key(fn)
		on_other_key = fn
		return self
	end

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_UP then
			select_i(selected - 1)
		elseif key == KEY_DOWN then
			select_i(selected + 1)
		elseif key == KEY_RETURN or key == KEY_RETURN2 or key == KEY_KP_ENTER then
			if magic.input:GetKeyPress(key) and items[selected] then
				items[selected].action()
			end
		elseif on_other_key then
			on_other_key(key)
		end
	end)

	return nav
end

-- Bind up/down/enter and hover selection to existing buttons on a uistack
-- root. Each item is {button, action} or {button=..., action=...}.
-- Subscribes Released on the buttons; don't also subscribe Released.
-- Returns a handle with :add(button, action) and :on_key(fn).
function M.safe.bind_button_menu(root, items, on_other_key)
	local nav = button_menu_nav(root)
	if items then
		for _, item in ipairs(items) do
			nav:add(item.button or item[1], item.action or item[2])
		end
	end
	if on_other_key then
		nav:on_key(on_other_key)
	end
	return nav
end

local function make_menu_button(parent, label, options)
	local button = parent:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = options.min_height or 24
	if options.min_width then
		button.minWidth = options.min_width
	end
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button
end

-- Vertical Window on a uistack root, with the same keyboard/mouse nav.
-- Extra widgets (logo, titles) go on menu.window before :add().
-- :add("Label", action) creates a button; :add(button, action) registers one.
function M.safe.vertical_menu(root, options)
	options = options or {}
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, options.spacing or 10,
			options.padding or magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local nav = button_menu_nav(root)
	if options.on_key then
		nav:on_key(options.on_key)
	end

	local menu = {window = window}

	function menu:add(label_or_button, action)
		local button = label_or_button
		if type(label_or_button) == "string" then
			button = make_menu_button(window, label_or_button, options)
		end
		nav:add(button, action)
		return button
	end

	function menu:on_key(fn)
		nav:on_key(fn)
		return self
	end

	return menu
end

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
		if key == KEY_ESCAPE then
			log:info("show_message_dialog: KEY_ESCAPE pressed")
			uistack.main:pop(root)
			message_handle = nil
		end
	end)
end

function M.safe.show_confirm_dialog(message, on_yes, on_no)
	local root = uistack.main:push({desc="show_confirm_dialog"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local message_text = window:CreateChild("Text")
	message_text:SetStyleAuto()
	message_text.text = message

	local function finish(yes)
		uistack.main:pop(root)
		if yes then
			if on_yes then on_yes() end
		else
			if on_no then on_no() end
		end
	end

	local yes_button = window:CreateChild("Button")
	yes_button:SetStyleAuto()
	yes_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	yes_button.minHeight = 20
	local yes_text = yes_button:CreateChild("Text")
	yes_text:SetStyleAuto()
	yes_text.text = "Force kill"
	yes_text:SetTextAlignment(HA_CENTER)

	local no_button = window:CreateChild("Button")
	no_button:SetStyleAuto()
	no_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	no_button.minHeight = 20
	local no_text = no_button:CreateChild("Text")
	no_text:SetStyleAuto()
	no_text.text = "Cancel"
	no_text:SetTextAlignment(HA_CENTER)
	no_button:SetFocus(true)

	magic.SubscribeToEvent(yes_button, "Released",
	function(self, event_type, event_data)
		finish(true)
	end)
	magic.SubscribeToEvent(no_button, "Released",
	function(self, event_type, event_data)
		finish(false)
	end)
	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			finish(false)
		end
	end)
end

-- A small non-modal notice in the top right corner. It does not take focus and
-- disappears by itself. A second call replaces what is showing.
local notification = nil
local notification_update_subscribed = false

function M.safe.show_notification(text, duration_s)
	duration_s = duration_s or 2.0

	if notification then
		notification.window:Remove()
		notification = nil
	end

	local window = magic.ui.root:CreateChild("Window")
	window.defaultStyle = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")
	window:SetStyleAuto()
	window:SetName("show_notification window")
	window:SetLayout(LM_VERTICAL, 0, magic.IntRect(10, 6, 10, 6))
	window:SetFocusMode(FM_NOTFOCUSABLE)

	local message_text = window:CreateChild("Text")
	message_text:SetStyleAuto()
	message_text.text = text

	-- Align once the text is in; alignment does not follow a later resize
	window:SetAlignment(HA_RIGHT, VA_TOP)

	notification = {
		window = window,
		end_time_us = buildat.get_time_us() + duration_s * 1000000,
	}

	-- One subscription for the lifetime of the process. Unsubscribing from
	-- inside a handler breaks extension/urho3d's global event multiplexer.
	if not notification_update_subscribed then
		notification_update_subscribed = true
		magic.SubscribeToEvent("Update",
		function(event_type, event_data)
			if notification and buildat.get_time_us() >= notification.end_time_us then
				notification.window:Remove()
				notification = nil
			end
		end)
	end
end

return M
-- vim: set noet ts=4 sw=4:
