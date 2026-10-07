-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("ui_utils")
local magic = require("buildat/extension/urho3d")
-- The engine's constants come from magic in the sandbox
local FM_NOTFOCUSABLE, HA_CENTER, HA_LEFT, HA_RIGHT, KEY_DOWN,
		KEY_ESCAPE, KEY_KP_ENTER, KEY_LEFT, KEY_RETURN, KEY_RETURN2,
		KEY_RIGHT, KEY_UP, LM_VERTICAL, VA_CENTER, VA_TOP =
	magic.FM_NOTFOCUSABLE, magic.HA_CENTER, magic.HA_LEFT, magic.HA_RIGHT,
	magic.KEY_DOWN, magic.KEY_ESCAPE, magic.KEY_KP_ENTER, magic.KEY_LEFT,
	magic.KEY_RETURN, magic.KEY_RETURN2, magic.KEY_RIGHT, magic.KEY_UP,
	magic.LM_VERTICAL, magic.VA_CENTER, magic.VA_TOP
local dump = buildat.dump
local uistack = require("buildat/extension/uistack")
local M = {safe = {}}

-- **The menus' colours** ([MENU_BRAND], c_quiet, src/interface/web_brand.h):
-- what a menu colours by hand rather than through main_style.xml. Numbers,
-- not Colors -- a sandbox's property takes only its own -- and through a
-- function, as the sandbox's view of a table unpacks as empty:
-- magic.Color(ui_utils.rgb("error")). text, dim and focus are the style's.
local colors = {
	text = {0.867, 0.867, 0.867},  -- #ddd
	dim = {0.6, 0.6, 0.6},         -- #999
	warn = {1, 0.8, 0.4},
	error = {1, 0.36, 0.36},       -- #ff5c5c
	focus = {0.149, 0.851, 1},     -- #26d9ff
	main = {1, 0.62, 0.122},       -- #ff9e1f, the main button
}
function M.safe.rgb(name)
	return unpack(colors[name])
end

-- API naming:
-- show_*_notification()
-- show_*_dialog()
-- show_*_window() (?)
-- vertical_menu() / bind_button_menu()

-- **Every page by the keyboard** ([MENU_KEYS], user 2026-10-02). The
-- arrows, Tab and Shift+Tab go through a page's buttons and fields, Enter
-- or Space presses the button with the focus (both Tab and the press are
-- Urho3D's own once a button takes the focus), and every button has a
-- letter, drawn in brackets in its label -- "[C]hange password..." --
-- that focuses it; pressed again, the next with the same letter. A label
-- may name its own with "&" ("Log &out"). Not on a touchscreen
-- (BUILDAT_TOUCH): no keys there, and the brackets would be noise.
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"

-- Whether an element is still there, and whether it is shown: a removed
-- one raises ([UI_UAF]'s guard), which is the answer to the first
local function gone(e)
	return not pcall(function() return e.visible end)
end

-- **A page's window is known by a name of its own**: a window removed and
-- another made in the same frame can sit at the same address, and the old
-- wrapper then reads the new one (the guard's own simplified: note) -- the
-- plan picker's page went on to letter the editor's toolbar. A window with
-- a name keeps it and is known by that.
local page_serial = 0
local function page_name(win)
	local ok, name = pcall(function() return win:GetName() end)
	if not ok then
		return nil
	end
	if name == "" then
		page_serial = page_serial + 1
		name = "keyboard_page_" .. page_serial
		win:SetName(name)
	end
	return name
end
local function shown(e)
	local ok, v = pcall(function() return e.visible end)
	return ok and v == true
end

-- The page's buttons and fields, in the order they are drawn
local function page_items(e, out)
	if not e.visible then
		return out
	end
	local t = e:GetTypeName()
	if (t == "Button" and e.enabled) or t == "LineEdit" then
		out[#out + 1] = e
		if t == "Button" then
			-- A dropdown's or a checkbox's insides are the button's
			return out
		end
	end
	-- A child of the client's own reads nil ([TRUST_CODE]: the code in a
	-- Starport field)
	for i = 0, e:GetNumChildren() - 1 do
		local c = e:GetChild(i)
		if c then
			page_items(c, out)
		end
	end
	return out
end

local function button_text(b)
	for i = 0, b:GetNumChildren() - 1 do
		-- nil for the client's own hidden UI
		local c = b:GetChild(i)
		if c and c:GetTypeName() == "Text" then
			return c
		end
		local d = c and button_text(c)
		if d then
			return d
		end
	end
	return nil
end

-- The label with its letter in brackets, and the letter; the first letter
-- of the label not taken on the page, then the next. What is already in
-- brackets -- a checkbox's "[x]" -- is not a candidate.
local function mark_letter(label, taken)
	local amp = label:find("&%a")
	if amp then
		local ch = label:sub(amp + 1, amp + 1)
		return label:sub(1, amp - 1) .. "[" .. ch .. "]" ..
				label:sub(amp + 2), ch:lower()
	end
	local depth = 0
	for i = 1, #label do
		local c = label:sub(i, i)
		if c == "[" then
			depth = depth + 1
		elseif c == "]" then
			depth = math.max(0, depth - 1)
		elseif depth == 0 and c:match("%a") and not taken[c:lower()] then
			return label:sub(1, i - 1) .. "[" .. c .. "]" .. label:sub(i + 1),
					c:lower()
		end
	end
	return label, nil
end

-- A label without its letter's brackets: "[C]hange" and "Log [o]ut", but
-- not a checkbox's "[x] Damage", whose brackets stand apart from words
local function unmark(text)
	return (text:gsub("()%[(%a)%]()", function(s, c, e)
		local before = s > 1 and text:sub(s - 1, s - 1) or ""
		local after = text:sub(e, e)
		if before:match("%w") or after:match("%w") then
			return c
		end
		return nil
	end))
end
M.safe.unmark = unmark

-- The label with `ch` bracketed where it first stands outside brackets, or
-- nil where the label no longer has it
local function remark(label, ch)
	local depth = 0
	for i = 1, #label do
		local c = label:sub(i, i)
		if c == "[" then
			depth = depth + 1
		elseif c == "]" then
			depth = math.max(0, depth - 1)
		elseif depth == 0 and c:lower() == ch then
			return label:sub(1, i - 1) .. "[" .. c .. "]" .. label:sub(i + 1)
		end
	end
	return nil
end

-- **A page's letters, kept as its labels change**: a menu that writes a
-- label after making the button, or again on every press ("Mute: on"),
-- would otherwise lose its brackets. refresh() runs a frame at a time; a
-- button keeps its letter, and one with no label yet gets one when it has.
-- The button is held and its Text found again each time: a Text held
-- across frames is freed under its wrapper when a page replaces its
-- contents in place, and reading it was a crash (2026-10-02).
local function letterer()
	local L = {taken = {}, by_letter = {}, entries = {}}
	-- A button named "no_letter" gets none: a key binding's button reads
	-- "W" or "F1", and a bracket in it would be a lie
	function L:add(button, key)
		if TOUCH or button:GetName() == "no_letter" then
			return
		end
		self.entries[#self.entries + 1] = {b = button, key = key}
		self:refresh()
	end
	function L:refresh()
		for _, e in ipairs(self.entries) do
			local ok, t = pcall(button_text, e.b)
			local text = ok and t and t.text
			if text and text ~= e.marked then
				local new = nil
				if e.ch then
					new = remark(text, e.ch)
				else
					local ch
					new, ch = mark_letter(unmark(text), self.taken)
					if ch then
						e.ch = ch
						self.taken[ch] = true
						self.by_letter[ch] = self.by_letter[ch] or {}
						table.insert(self.by_letter[ch], e.key)
					else
						new = nil
					end
				end
				if new and new ~= text then
					t.text = new
				end
				e.marked = new or text
			end
		end
	end
	-- The keys with `ch`, or nil
	function L:with(ch)
		return self.by_letter[ch]
	end
	-- "bcm": the letters given, for the log a check reads
	function L:summary()
		local out = {}
		for _, e in ipairs(self.entries) do
			out[#out + 1] = e.ch or "-"
		end
		return table.concat(out)
	end
	return L
end

-- **The selected item is the one with the focus** ([ONE_FOCUS]): one
-- thing on a screen is selected, a field or a button, and Enter is its --
-- a focused button presses itself on Enter or Space (Urho3D's
-- Button::OnKey), a field finishes its line. A selection of the menu's own
-- beside the focus had Enter in a field press a button: on the web a
-- LineEdit drops its focus on Enter before a script hears the key (the
-- screen keyboard, LineEdit.cpp), and the menu then pressed its own.
-- Button.selected draws the focus, with pressedOffset; native hover would
-- draw a second item, so hoverOffset moves onto pressedOffset, and hover
-- moves the focus instead, unless a field is being typed in.
-- options.letters = false: no letters, for a menu whose letters are its
-- own (the launch grid's type-to-filter)
-- PageUp and PageDown move this many items ([MENU_FAST_SCROLL])
local PAGE = 10

-- How many rows one wheel click moves in a menu of n items in rows of
-- columns: a list of any length is crossed in 10 to 20 clicks
local function wheel_step(n, columns)
	return math.max(1, math.ceil(math.ceil(n / columns) / 20))
end
assert(wheel_step(15, 1) == 1 and wheel_step(20, 1) == 1 and
		wheel_step(21, 1) == 2 and wheel_step(60, 1) == 3 and
		wheel_step(300, 1) == 15 and wheel_step(84, 4) == 2,
		"wheel_step")

local function button_menu_nav(root, options)
	local use_letters = not (options and options.letters == false)
	local items = {}
	-- The focused item's index, 0 for none: read from the focus
	local selected = 0
	-- **A selection the mouse made goes when the mouse leaves its button**
	-- (user, 2026-10-06): a highlight is what a click would press, and a
	-- click just beside a button presses nothing. One the keys or the
	-- wheel made stays wherever the mouse goes. anchor is the item the
	-- mouse left, which the next arrow brings back rather than the first.
	local by_mouse = false
	local anchor = 0
	local on_other_key = nil
	local on_change = nil
	-- [MENU_KEYS]: a letter selects its item, as keyboard_page's focuses
	local letters = letterer()

	local function typing()
		local focus = magic.ui.focusElement
		return focus ~= nil and focus:GetTypeName() == "LineEdit"
	end

	local function apply()
		for i, item in ipairs(items) do
			item.button.selected = (i == selected)
			if on_change then
				on_change(item.button, i == selected, i)
			end
		end
	end

	-- The drawing follows the focus, wherever it moved it from: a click,
	-- Tab, a field taking it
	local function sync()
		local at = 0
		for i, item in ipairs(items) do
			if not gone(item.button) and item.button:HasFocus() then
				at = i
			end
		end
		if at ~= selected then
			selected = at
			apply()
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
		items[i].button:SetFocus(true)
		sync()
	end

	local nav = {}

	function nav:add(button, action)
		if button == nil or action == nil then
			error("button_menu: add() needs a button and an action")
		end
		local i = #items + 1
		items[i] = {button = button, action = action}
		if use_letters then
			letters:add(button, i)
		end
		local hover = button.hoverOffset
		button.pressedOffset = magic.IntVector2(hover.x, hover.y)
		button.hoverOffset = magic.IntVector2(0, 0)
		button:SetFocusMode(magic.FM_FOCUSABLE)
		magic.SubscribeToEvent(button, "Released",
		function(self, event_type, event_data)
			action()
		end)
		magic.SubscribeToEvent(button, "HoverBegin",
		function(self, event_type, event_data)
			if not typing() then
				select_i(i)
				by_mouse = true
			end
		end)
		magic.SubscribeToEvent(button, "HoverEnd",
		function(self, event_type, event_data)
			-- Not under a screen pushed over this one: the focus is that
			-- screen's (a click that opened it ends the hover too)
			if not by_mouse or gone(root) or not root.visible then
				return
			end
			sync()
			if selected == i then
				anchor = i
				root:SetFocus(true)
				sync()
			end
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
			-- Without its letter's brackets ([MENU_KEYS])
			label = unmark(label):lower()
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
		if typing() then
			return
		end
		sync()
		-- Left and right as well as up and down, because a menu can be a row
		-- as well as a column and a player should not have to know which.
		-- From none, the one the mouse left, else the first. Enter is the
		-- focused button's own.
		-- Whatever is selected from here on, the keys chose it
		by_mouse = false
		if selected == 0 and (key == KEY_LEFT or key == KEY_RIGHT or
				key == KEY_UP or key == KEY_DOWN) then
			select_i(anchor >= 1 and anchor <= #items and anchor or 1)
		elseif key == KEY_LEFT then
			select_i(selected - 1)
		elseif key == KEY_RIGHT then
			select_i(selected + 1)
		elseif key == KEY_UP then
			select_i(selected - columns)
		elseif key == KEY_DOWN then
			select_i(selected + columns)
		elseif key == magic.KEY_PAGEUP or key == magic.KEY_PAGEDOWN then
			-- [MENU_FAST_SCROLL]: ten items, ten rows in a grid, clamped
			local d = (key == magic.KEY_PAGEUP and -PAGE or PAGE) * columns
			select_i(math.max(1, math.min(#items,
					math.max(selected, 1) + d)))
		elseif key == KEY_RETURN or key == KEY_RETURN2 or key == KEY_KP_ENTER then
			return
		else
			local q = event_data:GetInt("Qualifiers")
			local ch = key >= 0 and key < 256 and string.char(key):lower()
			local list = ch and letters:with(ch)
			if list and math.floor(q / magic.QUAL_CTRL) % 2 == 0 and
					math.floor(q / magic.QUAL_ALT) % 2 == 0 then
				local next_i = list[1]
				for n, i in ipairs(list) do
					if i == selected then
						next_i = list[n % #list + 1]
					end
				end
				select_i(next_i)
			end
		end
	end)

	-- The wheel moves the selection, and the menu's on_change scrolls it
	-- into view; clamped rather than wrapped, so a wheel past the end
	-- stops on the last item, which is how a partial last row is reached
	-- ([LAUNCH_GRID]). **Its step grows with the list**
	-- ([MENU_FAST_SCROLL]): a row a click up to 20 rows, two up to 40,
	-- so any list is crossed in 10 to 20 clicks.
	root:SubscribeToStackEvent("MouseWheel", function(event_type, event_data)
		if #items == 0 then
			return
		end
		by_mouse = false
		sync()
		local i = math.max(selected, 1) - event_data:GetInt("Wheel") *
				wheel_step(#items, columns) * columns
		select_i(math.max(1, math.min(#items, i)))
	end)

	-- **A button the menu does not know of** is one the keyboard cannot
	-- reach: said once, the first frame the menu is up ([MENU_KEYS])
	local checked = false
	root:SubscribeToStackEvent("Update", function()
		if use_letters then
			letters:refresh()
		end
		if checked then
			sync()
			return
		end
		checked = true
		-- The first item has the focus to start with, unless the screen gave
		-- it to something of its own (a field to type in)
		local focus = magic.ui.focusElement
		local kind = focus and focus:GetTypeName()
		if items[1] and kind ~= "LineEdit" and kind ~= "Button" then
			items[1].button:SetFocus(true)
		end
		sync()
		-- simplified: a wrapper is not the same table twice, so a button
		-- is known by its label and where it is
		local function id(b)
			local t = button_text(b)
			local p = b.screenPosition
			return (t and unmark(t.text) or "") .. "@" .. p.x .. "," .. p.y
		end
		local known = {}
		for _, item in ipairs(items) do
			known[id(item.button)] = true
		end
		for _, e in ipairs(page_items(root, {})) do
			if e:GetTypeName() == "Button" and not known[id(e)] then
				local t = button_text(e)
				log:warning("menu: a button outside its menu's keys: " ..
						(t and dump(unmark(t.text)) or "(no label)"))
			end
		end
		log:verbose("menu: " .. #items .. " items, letters " ..
				letters:summary())
	end)

	return nav
end

-- The pages that took the keys, newest last: only the newest one still
-- shown answers, so a page over another does not share its keys
local keyboard_pages = {}

-- The page's own window still there: not removed, and not another one at
-- its address
local function page_gone(page)
	if gone(page.win) then
		return true
	end
	local ok, name = pcall(function() return page.win:GetName() end)
	return not ok or name ~= page.name
end

local function newest_page()
	for i = #keyboard_pages, 1, -1 do
		if not page_gone(keyboard_pages[i]) and shown(keyboard_pages[i].win) then
			return keyboard_pages[i]
		end
	end
	return nil
end

-- The page's items and letters read again from its window: nothing of it
-- is held from one frame to the next but the window
local function rewalk(page)
	page.items = page_items(page.win, {})
	page.letters = letterer()
	for _, e in ipairs(page.items) do
		if e:GetTypeName() == "Button" then
			e:SetFocusMode(magic.FM_FOCUSABLE)
			page.letters:add(e, e)
		end
	end
end

-- An item of the page removed: the page was redrawn after the frame a
-- click re-read it, as Hearth's is when its server answers, and the new
-- buttons have no letters yet.
-- simplified: items added with none removed are not noticed until the
-- next key or click; ElementAdded (not in safe_events) would catch them.
local function stale(page)
	for _, e in ipairs(page.items) do
		if gone(e) then
			return true
		end
	end
	return false
end

local function arrange(page)
	rewalk(page)
	local first, inside = nil, false
	for _, e in ipairs(page.items) do
		if e:HasFocus() then
			inside = true
		end
		if e:GetTypeName() == "Button" then
			first = first or e
		end
	end
	-- The first button has the focus to start with, unless the page gave
	-- it to one of its own (a password page's first field)
	if first and not inside then
		first:SetFocus(true)
	end
end

-- keyboard_page(win): win, a window or a page, by the keyboard. Its
-- buttons and fields are read a frame later, so a page built after the
-- call that made its window gets them all.
function M.safe.keyboard_page(win)
	local page = {win = win, items = {}, letters = letterer(),
			name = page_name(win)}
	keyboard_pages[#keyboard_pages + 1] = page
	local update_sub, key_sub, click_sub
	local arranged, dirty = false, false
	-- A key or a click may have changed the page: read again the frame
	-- after, which is when its labels are what the press made them
	click_sub = magic.SubscribeToEvent("MouseButtonUp", function()
		dirty = true
	end)
	update_sub = magic.SubscribeToEvent("Update", function()
		if page_gone(page) then
			magic.UnsubscribeFromEvent("Update", update_sub)
			magic.UnsubscribeFromEvent("MouseButtonUp", click_sub)
			return
		end
		if not arranged and shown(win) then
			arranged = true
			arrange(page)
			log:verbose("keyboard_page: " .. #page.items ..
					" buttons and fields, letters " .. page.letters:summary())
		elseif shown(win) and (dirty or stale(page)) then
			dirty = false
			rewalk(page)
		end
	end)
	key_sub = magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
		if page_gone(page) or not shown(win) then
			-- Removed, not hidden for a moment
			if page_gone(page) then
				magic.UnsubscribeFromEvent("KeyDown", key_sub)
				for i, p in ipairs(keyboard_pages) do
					if p == page then
						table.remove(keyboard_pages, i)
						break
					end
				end
			end
			return
		end
		if newest_page() ~= page or not arranged then
			return
		end
		dirty = true
		rewalk(page)
		if #page.items == 0 then
			return
		end
		local key = event_data:GetInt("Key")
		local focus = magic.ui.focusElement
		local typing = focus ~= nil and focus:GetTypeName() == "LineEdit"
		-- A multi-line field's rows are its up and down ([HEARTH_MVP])
		local rows = typing and focus:IsMultiLine()
		if not typing and (key == magic.KEY_PAGEUP or
				key == magic.KEY_PAGEDOWN) then
			local at = 0
			for i, e in ipairs(page.items) do
				if shown(e) and e:HasFocus() then
					at = i
				end
			end
			local d = key == magic.KEY_PAGEUP and -PAGE or PAGE
			page.items[math.max(1, math.min(#page.items,
					math.max(at, 1) + d))]:SetFocus(true)
			return
		end
		if (not rows and (key == KEY_UP or key == KEY_DOWN)) or
				(not typing and (key == KEY_LEFT or key == KEY_RIGHT)) then
			local at = 0
			for i, e in ipairs(page.items) do
				if shown(e) and e:HasFocus() then
					at = i
				end
			end
			local d = (key == KEY_DOWN or key == KEY_RIGHT) and 1 or -1
			local n = #page.items
			local i = at == 0 and 1 or (at - 1 + d) % n + 1
			page.items[i]:SetFocus(true)
			return
		end
		-- A letter, with no Ctrl or Alt, outside a text field
		local q = event_data:GetInt("Qualifiers")
		if typing or math.floor(q / magic.QUAL_CTRL) % 2 == 1 or
				math.floor(q / magic.QUAL_ALT) % 2 == 1 then
			return
		end
		local ch = key >= 0 and key < 256 and string.char(key):lower() or nil
		local list = ch and page.letters:with(ch)
		if not list then
			return
		end
		local next_i = 1
		for i, e in ipairs(list) do
			if e:HasFocus() then
				next_i = i % #list + 1
			end
		end
		list[next_i]:SetFocus(true)
		local t = button_text(list[next_i])
		log:verbose("keyboard: " .. ch .. " to " .. (t and unmark(t.text) or "?"))
	end)
	return win
end

-- Bind up/down/enter and hover selection to existing buttons on a uistack
-- root. Each item is {button, action} or {button=..., action=...}.
-- Subscribes Released on the buttons; don't also subscribe Released.
-- Returns a handle with :add(button, action) and :on_key(fn). options as
-- button_menu_nav's.
function M.safe.bind_button_menu(root, items, on_other_key, options)
	local nav = button_menu_nav(root, options)
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

local function make_menu_button(parent, label, options, main)
	local button = parent:CreateChild("Button")
	if main then button:SetStyle("PrimaryButton") else button:SetStyleAuto() end
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
-- :add("Label", action, true): the screen's main button, amber ([MENU_BRAND]).
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

	local nav = button_menu_nav(root, options)
	if options.on_key then
		nav:on_key(options.on_key)
	end

	local menu = {window = window}

	function menu:add(label_or_button, action, main)
		local button = label_or_button
		if type(label_or_button) == "string" then
			button = make_menu_button(window, label_or_button, options, main)
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

-- **A list in a viewport that clips it** and scrolls by moving it
-- (launch_menu_v2's, shared since [HEARTH_UI]). Its rows are anything:
-- view:row() makes the menus' one-line button, and a caller with rows of
-- its own (a forum message: a box of wrapped text, its height its own)
-- creates them on view.list and calls fit().
--
--   local view = ui_utils.list_view(parent, width, height, {
--       row_height = 28, icon_size = 20, label_share = 0.62, spacing = 2,
--       wheel = nil, follow_focus = false})
--   view:header(s, size, color)  a heading row; dim, 13 by default
--   view:row(e, badge)           a Button: e.icon (a texture, or none),
--                                e.label, and badge (or e.badge) dim after
--   view:fit()                   lays the rows out; again after adding more
--   view:show(e)                 scrolls so that e is in view
--   view:scroll(dy)              by dy pixels, clamped; math.huge: the end
--
-- **The layout is set in fit(), once the rows are in**: a vertical layout
-- is redone for every child added, so 300 rows took 1.8 s where 50 took
-- 30 ms ([SEARCH_CAP]). Rows added after fit() are laid out one by one,
-- which is fine for a few (a chat's new line).
-- **What scrolls it**: the caller's show() and scroll() -- a menu's
-- selection (bind_button_menu's on_change -> show), which owns the wheel
-- there. options.wheel: the wheel over the list scrolls it, this many
-- pixels a click, for a list read rather than walked. options.follow_focus:
-- after a key, the row holding the focus is scrolled into view, for a list
-- walked by keyboard_page.
-- simplified: no scroll bar.
function M.safe.list_view(parent, width, height, options)
	options = options or {}
	local row_height = options.row_height or 28
	local icon_size = options.icon_size or 20
	local viewport = parent:CreateChild("UIElement")
	viewport.clipChildren = true
	viewport.enabled = true
	local list = viewport:CreateChild("UIElement")
	list:SetFixedWidth(width)
	list.enabled = true
	local view = {viewport = viewport, list = list}
	local subs = {}
	local function on(event, fn)
		subs[event] = magic.SubscribeToEvent(event, function(t, d)
			if gone(viewport) then
				for e, sub in pairs(subs) do
					magic.UnsubscribeFromEvent(e, sub)
				end
				return
			end
			if shown(viewport) then
				fn(d)
			end
		end)
	end
	local function over(x, y)
		local at = viewport.screenPosition
		return x >= at.x and x < at.x + viewport.width and
				y >= at.y and y < at.y + viewport.height
	end
	-- **A finger drags it** (playtest, 2026-10-07): a touchscreen has no
	-- wheel and no keys to walk it by
	on("TouchMove", function(d)
		if over(d:GetInt("X"), d:GetInt("Y")) then
			view:scroll(-d:GetInt("DY"))
		end
	end)
	if options.wheel or options.follow_focus then
		local pending = false
		if options.wheel then
			on("MouseWheel", function(d)
				local p = magic.input.mousePosition
				if over(p.x, p.y) then
					view:scroll(-d:GetInt("Wheel") * options.wheel)
				end
			end)
		end
		if options.follow_focus then
			on("KeyDown", function() pending = true end)
			-- The frame after the key, when the focus has moved
			on("Update", function()
				if not pending then
					return
				end
				pending = false
				-- Which row holds the focus: the focus named for a moment
				-- and looked for under each row -- a script's element has
				-- no parent to read, and its wrapper is not the same table
				-- twice
				local f = magic.ui.focusElement
				if not f then
					return
				end
				local was = f:GetName()
				f:SetName("__list_view_focus")
				local function has(e)
					if e:GetName() == "__list_view_focus" then
						return true
					end
					for i = 0, e:GetNumChildren() - 1 do
						local c = e:GetChild(i)
						if c and has(c) then
							return true
						end
					end
					return false
				end
				for i = 0, list:GetNumChildren() - 1 do
					local r = list:GetChild(i)
					if r and has(r) then
						view:show(r)
						break
					end
				end
				f:SetName(was)
			end)
		end
	end
	local function text(at, s, size, color)
		local t = at:CreateChild("Text")
		t:SetStyleAuto()
		t.text = s
		if size then t:SetFontSize(size) end
		if color then t.color = magic.Color(M.safe.rgb(color)) end
		return t
	end
	function view:header(s, size, color)
		local t = text(list, s, size or 13, color or "dim")
		t:SetFixedHeight(math.max(t.height, row_height - 4))
		return t
	end
	function view:row(e, badge)
		local b = list:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName("Button")
		b:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(10, 2, 10, 2))
		b:SetFixedHeight(row_height)
		-- The row's own icon, small enough to keep its height; an empty
		-- one where there is none, so that the labels line up
		local tex = e.icon and magic.cache:GetResource("Texture2D", e.icon)
		local icon = b:CreateChild(tex and "BorderImage" or "UIElement")
		icon:SetFixedSize(icon_size, icon_size)
		if tex then
			-- A game's own icon is pixel art
			tex.filterMode = magic.FILTER_NEAREST
			icon.texture = tex
			icon.blendMode = magic.BLEND_ALPHA
		end
		local label = text(b, e.label)
		label:SetName("ButtonText")
		label:SetFixedWidth(math.floor(width * (options.label_share or 0.62)))
		label:SetAlignment(HA_LEFT, VA_CENTER)
		text(b, badge or e.badge or "", 12, "dim"):SetAlignment(HA_LEFT,
				VA_CENTER)
		return b
	end
	function view:fit()
		list:SetLayout(LM_VERTICAL, options.spacing or 2,
				magic.IntRect(0, 0, 0, 0))
		viewport:SetFixedSize(width, math.max(row_height,
				math.min(height, list.height)))
		view:scroll(0)
	end
	function view:scroll(dy)
		local most = math.max(0, list.height - viewport.height)
		local top = math.min(most, math.max(0, -list.position.y + dy))
		list:SetPosition(0, -top)
	end
	function view:show(e)
		local y = e.position.y
		local top = -list.position.y
		if y < top then
			view:scroll(y - top)
		elseif y + e.height > top + viewport.height then
			view:scroll(y + e.height - top - viewport.height)
		end
	end
	return view
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

-- **A list of servers** in a list_view, the rows launch_menu_v2's
-- Servers screen has ([SERVER_LIST]; that look since the playtest of
-- 2026-10-07): one line each, the name and a dim badge, and the row
-- under the mouse or picked last described in options.panel, the column
-- beside the list, at its top.
--
--   local list = ui_utils.server_list(parent, {width = 520, height = 480,
--       panel = column}, function(row, second) ... end)
--   list:set_rows({{name = , badge = , line = , icon = }, {header = }, ...})
--
-- options.hint is what the panel says before a pick.
--
-- on_pick(row, second) is called on a click, second true when the same
-- row was picked again within a second -- a double-click. set_rows()
-- replaces what is shown; the caller filters before it. A {header = s}
-- row is a heading.
function M.safe.server_list(parent, options, on_pick)
	options = options or {}
	local width, height = options.width or 520, options.height or 480
	local view = M.safe.list_view(parent, width, height, {wheel = 40})
	local detail = nil
	if options.panel then
		detail = options.panel:CreateChild("UIElement")
		-- **One height whatever it says**: the fields and Join under it
		-- stay put as the mouse crosses rows on its way to them.
		-- simplified: a description longer than this is cut off
		detail:SetFixedHeight(options.detail_height or 130)
		detail.clipChildren = true
	end
	local list = {view = view}
	local picked, last_us = nil, 0
	local function describe(row)
		if not detail or gone(detail) then
			return
		end
		detail:RemoveAllChildren()
		-- Placed by hand: a layout would share the spare height out
		-- between the lines
		local y = 0
		local function text(s, size, color)
			local t = detail:CreateChild("Text")
			t:SetStyleAuto()
			t.text = s
			t:SetFontSize(size)
			if color then t.color = magic.Color(M.safe.rgb(color)) end
			t:SetWordwrap(true)
			t:SetFixedWidth(options.panel.width)
			t:SetPosition(0, y)
			y = y + t.height + 4
		end
		if row then
			text(row.name or "", 18)
			if row.badge and row.badge ~= "" then text(row.badge, 12, "dim") end
			if row.line and row.line ~= "" then text(row.line, 13, "dim") end
		else
			text(options.hint or "Pick a server, or type its address", 13,
					"dim")
		end
	end
	describe(nil)
	function list:set_rows(rows)
		view.list:RemoveAllChildren()
		-- Free while the rows go in: a vertical layout is redone for each
		-- one added (list_view's fit())
		view.list:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
		view.list:SetPosition(0, 0)
		for _, row in ipairs(rows) do
			if row.header then
				view:header(row.header)
			else
				local b = view:row({label = row.name or "", icon = row.icon},
						row.badge)
				b:SetFocusMode(magic.FM_FOCUSABLE)
				magic.SubscribeToEvent(b, "HoverBegin", function()
					describe(row)
				end)
				magic.SubscribeToEvent(b, "HoverEnd", function()
					describe(picked)
				end)
				magic.SubscribeToEvent(b, "Released", function()
					local now = buildat.get_time_us()
					local second = picked == row and now - last_us < 1000000
					picked, last_us = row, now
					describe(row)
					on_pick(row, second)
				end)
			end
		end
		view:fit()
		-- The list's height stays: the window does not move under the
		-- mouse as rows come and go
		view.viewport:SetFixedSize(width, height)
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
	t.color = magic.Color(M.safe.rgb("error"))
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

-- **A way back to the menu** (user, 2026-10-06): a "Menu" button in the
-- bottom right corner of parent, for a launch UI with no menu of its own
-- to switch from (the console, the room). It switches to launch_menu_v2;
-- before(), if given, runs first, for one that has to take its own
-- screen down, and opts go to set_launch_ui ({close = true}). Returns
-- the button, whose visible the caller may set.
function M.safe.menu_button(parent, before, opts)
	local box = parent:CreateChild("UIElement")
	box.defaultStyle = magic.cache:GetResource("XMLFile",
			"launch_menu/res/main_style.xml")
	box:SetAlignment(HA_RIGHT, magic.VA_BOTTOM)
	box:SetFixedSize(80, 30)
	box:SetPosition(-10, -10)
	box.priority = 950
	local b = box:CreateChild("Button")
	b:SetStyleAuto()
	b:SetName("Button")
	b:SetFixedSize(80, 30)
	b:SetLayout(LM_VERTICAL, 0, magic.IntRect(0, 0, 0, 0))
	-- A click's, not the keyboard's: Tab in the console cycles its
	-- fields, and Enter on this would leave it
	b:SetFocusMode(FM_NOTFOCUSABLE)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t.text = "Menu"
	t:SetTextAlignment(HA_CENTER)
	magic.SubscribeToEvent(b, "Released", function()
		if before then before() end
		local ok, why = (buildat.safe or buildat).set_launch_ui(
				"launch_menu_v2", opts)
		if not ok then
			log:warning("menu_button: " .. tostring(why))
			M.safe.show_message_dialog(tostring(why))
		end
	end)
	return box
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
	ok_button:SetStyle("PrimaryButton")
	ok_button:SetName("Button")
	ok_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	ok_button.minHeight = 20
	local ok_button_text = ok_button:CreateChild("Text")
	ok_button_text:SetName("ButtonText")
	ok_button_text:SetStyleAuto()
	ok_button_text.text = "Ok"
	ok_button_text:SetTextAlignment(HA_CENTER)

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

	-- The menu's keys: Enter, and Escape on the "Ok" that is the way back
	M.safe.bind_button_menu(root, {{ok_button, function()
		log:info("show_message_dialog: closed")
		close()
	end}})
	ok_button:SetFocus(true)
end

-- yes_label is the first button's, "Yes" when absent ([DELETE_WORDING]:
-- it was "Force kill", its first user's, and a deletion asked that)
function M.safe.show_confirm_dialog(message, on_yes, on_no, yes_label)
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
	yes_button:SetName("Button")
	yes_button:SetStyle("PrimaryButton")
	yes_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	yes_button.minHeight = 20
	local yes_text = yes_button:CreateChild("Text")
	yes_text:SetName("ButtonText")
	yes_text:SetStyleAuto()
	yes_text.text = yes_label or "Yes"
	yes_text:SetTextAlignment(HA_CENTER)

	local no_button = window:CreateChild("Button")
	no_button:SetName("Button")
	no_button:SetStyleAuto()
	no_button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	no_button.minHeight = 20
	local no_text = no_button:CreateChild("Text")
	no_text:SetName("ButtonText")
	no_text:SetStyleAuto()
	no_text.text = "Cancel"
	no_text:SetTextAlignment(HA_CENTER)

	-- The menu's keys ([MENU_KEYS]): the arrows, a letter, Enter, and
	-- Escape on "Cancel", the way back
	M.safe.bind_button_menu(root, {
		{yes_button, function() finish(true) end},
		{no_button, function() finish(false) end},
	})
	no_button:SetFocus(true)
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
					line = line .. " text " .. dump(unmark(text))
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
			-- What draws over what among siblings
			if child.priority ~= 0 then
				line = line .. " priority " .. child.priority
			end
			out[#out + 1] = line
			M.safe.scan_ui(label, child, depth + 1, out)
		end
	end
end

return M
-- vim: set noet ts=4 sw=4:
