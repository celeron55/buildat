-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("ui_utils")
local magic = require("buildat/extension/urho3d").safe
local dump = buildat.dump
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
	-- When this menu came up: the Enter that finished a filter field on the
	-- screen before this one arrives here too, in the same frame, and
	-- pressed whichever button was first ([WORLD_LIST]: the world screen's
	-- filter opened "New world..."); a key older than the menu is not its
	local born_us = buildat.get_time_us()
	local on_other_key = nil
	local on_change = nil

	local function apply()
		for i, item in ipairs(items) do
			item.button.selected = (i == selected)
			if on_change then
				on_change(item.button, i == selected, i)
			end
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

	-- The item that is the way back, by its label: "< back", "Back",
	-- "Cancel", "< back to the launcher" and the like -- what Escape
	-- presses. nil for a screen with none.
	function nav:back_item()
		for _, item in ipairs(items) do
			local text = item.button:GetChild("ButtonText")
			local label = text and text.text or ""
			label = label:lower()
			if label:sub(1, 1) == "<" or label == "back" or label == "cancel" or
					label == "ok" or label == "close" then
				return item
			end
		end
		return nil
	end

	-- What being the selected item looks like, for a menu whose buttons draw
	-- more than their own style: an icon menu dims what is not selected. The
	-- callback gets (button, selected, index) for every item whenever the
	-- selection moves.
	function nav:on_change(fn)
		on_change = fn
		apply()
		return self
	end

	-- A grid rather than a row or a column: up and down move by this many
	-- items, left and right by one ([LAUNCH_GRID])
	local columns = 1
	function nav:set_columns(n)
		columns = math.max(1, math.floor(n or 1))
		return self
	end

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		-- A text field on the same screen owns the keys that are text: Enter
		-- finishes the line being typed and left and right move the caret.
		-- Without this a filter box beside a list cannot be used at all --
		-- Enter in it also presses whichever button is selected under it,
		-- which opens something instead of filtering.
		--
		-- **Whether anything has the focus is not the question.** The stack
		-- gives its own root the focus as it pushes it -- see
		-- UIStack:push() -- and a Button takes it when it is clicked, so
		-- something always has it and asking that turned the arrows and
		-- Enter off on every menu in the tree, this client's own first
		-- screen included. What stands the menu down is the focus being in
		-- a field that is being typed into.
		-- Escape is Back on every menu screen, typing or not
		-- ([BOX_PLAYTEST_2] 6, 7; the rule is in doc/conventions.txt):
		-- the item labelled as the way back is pressed, when the screen
		-- has one; a screen's own handler sees the key first and may
		-- take it (a capture's cancel), by returning true
		-- The screen's own handler first, for every key: true means it
		-- took it (a key capture takes the arrows too)
		if on_other_key and on_other_key(key) == true then
			return
		end
		if key == KEY_ESCAPE and magic.input:GetKeyPress(key) then
			local back = nav:back_item()
			if back then
				back.action()
				return
			end
		end
		local focus = magic.ui.focusElement
		if focus ~= nil and focus:GetTypeName() == "LineEdit" then
			return
		end
		-- Left and right as well as up and down, because a menu can be a row
		-- as well as a column and a player should not have to know which
		if key == KEY_LEFT then
			select_i(selected - 1)
		elseif key == KEY_RIGHT then
			select_i(selected + 1)
		elseif key == KEY_UP then
			select_i(selected - columns)
		elseif key == KEY_DOWN then
			select_i(selected + columns)
		elseif key == KEY_RETURN or key == KEY_RETURN2 or key == KEY_KP_ENTER then
			if magic.input:GetKeyPress(key) and items[selected] and
					buildat.get_time_us() - born_us > 200000 then
				items[selected].action()
			end
		end
	end)

	-- The wheel moves the selection a row at a time, and the menu's
	-- on_change scrolls it into view; clamped rather than wrapped, so a
	-- wheel past the end stops on the last item, which is how a partial
	-- last row is reached ([LAUNCH_GRID])
	root:SubscribeToStackEvent("MouseWheel", function(event_type, event_data)
		if #items == 0 then
			return
		end
		local i = selected - event_data:GetInt("Wheel") * columns
		select_i(math.max(1, math.min(#items, i)))
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
	-- SetStyleAuto() below needs a style to find, and a root that has none
	-- gives an unstyled window with invisible text -- which reads as a blank
	-- vertical bar. Every caller in this tree sets this first; do it here so
	-- that a caller which forgets gets a menu rather than a bar, the same way
	-- show_message_dialog() and show_notification() already do. A root that
	-- has its own style keeps it.
	if not root.defaultStyle then
		root.defaultStyle = magic.cache:GetResource("XMLFile",
				options.style or "launch_menu/res/main_style.xml")
	end
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

-- A list too long for the screen, a page at a time.
--
-- The items are the menu's own buttons, so the keyboard walks them like any
-- others, and the page buttons ask the caller to draw the menu again --
-- because what else is on the menu is the caller's business, and rebuilding
-- it is what every menu in this tree already does when its contents change.
--
--   ui_utils.add_paged(menu, items, {
--       page = page, per_page = 12,
--       redraw = function(new_page) ... end,
--   })
--
-- items are {label = , action = } or {label, action}. Returns how many
-- pages there are and which one was drawn.
function M.safe.add_paged(menu, items, options)
	options = options or {}
	local per_page = math.max(1, options.per_page or 12)
	local pages = math.max(1, math.ceil(#items / per_page))
	local page = math.max(1, math.min(options.page or 1, pages))
	local first = (page - 1) * per_page + 1
	local last = math.min(#items, first + per_page - 1)
	for i = first, last do
		local item = items[i]
		menu:add(item.label or item[1], item.action or item[2])
	end
	if pages > 1 and options.redraw then
		-- Which way round: the list is newest first everywhere this is
		-- used, so the next page is older
		if page > 1 then
			menu:add((options.prev_label or "^ newer") ..
					"   (page " .. (page - 1) .. " of " .. pages .. ")",
					function() options.redraw(page - 1) end)
		end
		if page < pages then
			menu:add((options.next_label or "v older") ..
					"   (page " .. (page + 1) .. " of " .. pages .. ")",
					function() options.redraw(page + 1) end)
		end
	end
	return pages, page
end

-- A list of servers (or anything with a name and a line under it) in a
-- ListView, rows as buttons with their text left-aligned ([SERVER_LIST],
-- the shape [CONTENTDB_LIST]'s rows have):
--
--   local list = ui_utils.server_list(parent, {width = 520, height = 480},
--       function(row, second) ... end)
--   list:set_rows({{name = , line = , data = }, ...})
--
-- on_pick(row, second) is called on a click, second true when the same
-- row was picked again within a second -- a double-click, or Enter on it.
-- set_rows() replaces what is shown; the caller filters before it.
function M.safe.server_list(parent, options, on_pick)
	options = options or {}
	local view = parent:CreateChild("ListView")
	view:SetStyleAuto()
	view:SetFixedSize(options.width or 520, options.height or 480)
	local list = {view = view}
	local last_name, last_us = nil, 0
	function list:set_rows(rows)
		view:RemoveAllItems()
		for _, row in ipairs(rows) do
			local b = view.contentElement:CreateChild("Button")
			b:SetStyleAuto()
			b:SetName("Button")
			b:SetLayout(LM_VERTICAL, 2, magic.IntRect(8, 4, 8, 4))
			b:SetFixedWidth((options.width or 520) - 40)
			local name = b:CreateChild("Text")
			name:SetName("ButtonText")
			name:SetStyleAuto()
			name.text = row.name or ""
			name:SetTextAlignment(HA_LEFT)
			if row.line and row.line ~= "" then
				local line = b:CreateChild("Text")
				line:SetStyleAuto()
				line.text = row.line
				line:SetTextAlignment(HA_LEFT)
				line:SetFixedWidth((options.width or 520) - 56)
				line:SetWordwrap(true)
			end
			magic.SubscribeToEvent(b, "Released", function()
				local now = buildat.get_time_us()
				local second = (last_name == row.name and now - last_us < 1000000)
				last_name, last_us = row.name, now
				on_pick(row, second)
			end)
			view:AddItem(b)
		end
	end
	return list
end

local message_handle = nil

-- on_close is optional and is called when the dialog goes away, however it
-- goes: what wants it is a message that is the last thing before something
-- else has to happen, like a client quitting after it says why.
-- A line at the top of the screen for a few seconds, taking nothing --
-- not the mouse, not the focus: what an error in a game's form callback
-- is shown as ([MENU_ERRORS])
local notices = {}
-- Whether a world is up on the screen ([MENU_ERRORS]): a caught error is a
-- dialog before a join and a notice line in a game, and the launcher's own
-- game is not the only kind -- luanti_client's session runs on the menu's
-- screens and a dialog there takes the mouse from the player. A client says
-- so here; client/sandbox.lua reads it.
M.in_app = false

function M.safe.set_in_game(on)
	M.in_app = on and true or false
end

function M.safe.show_notice(text)
	local t = magic.ui.root:CreateChild("Text")
	t.defaultStyle = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")
	t:SetStyleAuto()
	t.text = tostring(text)
	t.color = magic.Color(1, 0.6, 0.5)
	t:SetAlignment(HA_CENTER, VA_TOP)
	t:SetPosition(0, 40 + 24 * #notices)
	t.priority = 1000
	notices[#notices + 1] = {element = t, until_us = buildat.get_time_us() + 6000000}
	if #notices == 1 then
		local sub
		sub = magic.SubscribeToEvent("Update", function()
			local now = buildat.get_time_us()
			local kept = {}
			for _, n in ipairs(notices) do
				if now >= n.until_us then
					n.element:Remove()
				else
					kept[#kept + 1] = n
				end
			end
			notices = kept
			if #notices == 0 then
				magic.UnsubscribeFromEvent("Update", sub)
			end
		end)
	end
end

function M.safe.show_message_dialog(message, on_close)
	-- Don't stack multiple dialogs
	if message_handle then
		-- **A dialog can go without being closed** (2026-09-25): a
		-- sandbox reset, or a stack popped from elsewhere, takes its
		-- elements with it and leaves this handle pointing at a removed
		-- Text -- which raises on the next append, in trusted code,
		-- where it ends the client. Then it is not a dialog to add to,
		-- and a new one is drawn instead.
		if pcall(message_handle.append, message) then
			-- The newest caller is the one whose message is at the
			-- bottom of the dialog, so its on_close is the one that runs
			message_handle.on_close = on_close or message_handle.on_close
			return
		end
		log:warning("show_message_dialog: the last dialog is gone; a new one")
		message_handle = nil
	end

	local root = uistack.main:push({desc="show_message_dialog"})

	local style = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")
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

	-- The window is as wide as the widest line: the style gives it a width of
	-- its own and a message longer than that is otherwise cut off. A Text
	-- knows how wide it turned out once it has text and a font.
	local function fit_window()
		-- The text's own width plus the window's layout border and the frame
		-- its style draws
		local wanted = message_text.width + 40
		if wanted > window.minWidth then
			window.minWidth = wanted
		end
	end
	fit_window()

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
				fit_window()
			end
		end,
		on_close = on_close,
	}

	local function close()
		local closed = message_handle
		uistack.main:pop(root)
		message_handle = nil
		if closed and closed.on_close then
			closed.on_close()
		end
	end

	magic.SubscribeToEvent(ok_button, "Released",
	function(self, event_type, event_data)
		log:info("show_message_dialog: ok_button clicked")
		close()
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			log:info("show_message_dialog: KEY_ESCAPE pressed")
			close()
		end
	end)
end

function M.safe.show_confirm_dialog(message, on_yes, on_no)
	local root = uistack.main:push({desc="show_confirm_dialog"})

	local style = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")
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
			"XMLFile", "launch_menu/res/main_style.xml")
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


-- The half of `event scan` that reads the UI ([SCAN_EVENT], [FIRST_RUN]):
-- every element under one, with its kind, its rectangle in window pixels
-- and its text or image, one line each under the label. A form in the
-- world and a menu screen give the same lines, so a driver reads both
-- the same way.
--
-- Every rectangle is in window pixels, the coordinates mouse_pos takes:
-- Urho's UI is laid out in its own units, the window's pixels over
-- ui:GetScale(), and one conversion here beats every reader knowing
-- which space a line is in. Clipped to the window, so that the centre of
-- what is left is a valid mouse position.
function M.safe.scan_pixels(x, y, w, h)
	-- The frame's pixels over the root's units: the logical frame in
	-- a scripted client, whatever the window is ([SEQ_FIXED_SIZE])
	local ww, wh = buildat.logical_size()
	local k = ww / math.max(1, magic.ui.root.width)
	local x0 = math.max(0, math.floor(x * k))
	local y0 = math.max(0, math.floor(y * k))
	local x1 = math.min(ww, math.floor((x + w) * k))
	local y1 = math.min(wh, math.floor((y + h) * k))
	return x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0)
end

function M.safe.scan_ui(label, element, depth, out)
	local ok, n = pcall(function() return element:GetNumChildren() end)
	if not ok then
		return
	end
	for i = 0, n - 1 do
		local child = element:GetChild(i)
		if child then
			local kind = child:GetTypeName()
			local at = child.screenPosition
			local x, y, w, h = M.safe.scan_pixels(at.x, at.y, child.width, child.height)
			local line = string.format("scan %s: ui %s%s at %d,%d size %dx%d",
					label, string.rep("  ", depth), kind, x, y, w, h)
			if kind == "Text" or kind == "LineEdit" then
				local okt, text = pcall(function()
					return child.GetText and child:GetText() or child.text
				end)
				if okt and text then
					line = line .. " text " .. dump(text)
				end
			end
			if kind == "BorderImage" or kind == "Sprite" or
					kind == "Button" then
				local okt, name = pcall(function()
					local tex = child.texture
					return tex and tex.name or nil
				end)
				if okt and name and name ~= "" then
					line = line .. " image " .. dump(name)
				elseif not okt then
					line = line .. " image ? (" .. tostring(name) .. ")"
				end
			end
			if child.visible == false then
				line = line .. " hidden"
			end
			out[#out + 1] = line
			M.safe.scan_ui(label, child, depth + 1, out)
		end
	end
end

return M
-- vim: set noet ts=4 sw=4:
