-- Buildat: extension/launch_menu/preferences.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The preferences screen: what the user sets once and every game honours.
--
-- doc/plan/client_preferences_plan.md built the preferences and made every
-- game honour them, but until this nothing set them except a file and -o.
-- The C++ side stays the authority -- api.set_preference() parses and
-- range checks a value through the same code -o goes through, applies what
-- takes effect now, and persists the rest -- so this file is a page of
-- widgets that knows nothing about the file and cannot set a value a flag
-- could not.
--
-- One button per preference, cycling through the values worth offering.
-- Cycling rather than a slider because the keyboard navigation this menu
-- already has moves up and down a list of buttons, and a slider inside one
-- would need a second kind of focus for one screen's sake.
-- Run by the menu's own verb, so it loads on either side
-- ([LAUNCH_SANDBOX]): `require` answers an extension's safe half inside
-- the sandbox and the whole extension outside it, and the safe half
-- raises on a name it does not have rather than answering nil
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu/preferences")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe

-- **The constants are globals in trusted Lua and fields of the safe
-- table in the sandbox**, so they are named once here and the code
-- below reads the same on both sides ([LAUNCH_SANDBOX])
local HA_CENTER, KEY_ESCAPE, LM_VERTICAL =
		magic.HA_CENTER, magic.KEY_ESCAPE, magic.LM_VERTICAL

local M = {}

-- The values each preference offers, and how one is written out. The ranges
-- are the parser's own -- see parse_preference_options() in src/client/app.cpp
-- -- so nothing here can be refused; what is offered is the useful subset of
-- what is allowed.
local function percent(v)
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

-- Named as the -l numbers are; the two upper ones say what they cost
local LOG_LEVEL_NAMES = {[1] = "error", [2] = "warning", [3] = "info",
		[4] = "verbose (large logs, slower)", [5] = "debug (huge logs, slow)"}

local PREFERENCES = {
	{
		name = "render_scale",
		label = "Render scale",
		-- 1.0 is no scaling at all and is the bypass: the game draws into
		-- the window itself. Above it is supersampling, which the same code
		-- path gives away for free.
		values = {"auto", 0.5, 0.67, 0.75, 1.0, 1.5, 2.0},
		show = function(v)
			if v == "auto" then
				return "automatic (" ..
						percent(api.get_preferred_render_scale()) .. ")"
			end
			return percent(v)
		end,
	},
	{
		name = "vsync",
		label = "Vertical sync",
		values = {false, true},
	},
	{
		name = "max_fps",
		label = "Frame limit",
		-- 200 is Urho3D's own desktop default, which is what a client that
		-- says nothing gets; 0 is no limit at all.
		values = {30, 60, 75, 120, 144, 200, 0},
		show = function(v) return v == 0 and "unlimited" or tostring(v) end,
	},
	{
		name = "multisampling",
		label = "Antialiasing",
		values = {1, 2, 4, 8, 16},
		show = function(v) return v == 1 and "off" or (v.."x") end,
	},
	-- **Decibels below full, not a fader position** ([VOLUME_LAW], user
	-- 2026-09-28: "80% vs 100% linear is basically no change at all").
	-- Eleven levels 3 dB apart and silence under them, so every step is
	-- heard as the same step; the gain is made from this in the client,
	-- where it is applied.
	{
		name = "sound_volume_db",
		label = "Sound volume",
		values = {-33, -30, -27, -24, -21, -18, -15, -12, -9, -6, -3, 0},
		show = function(v)
			return v <= -33 and "off" or (v .. " dB")
		end,
	},
	{
		name = "sound_mute",
		label = "Mute",
		values = {false, true},
	},
	-- The two logs' levels ([LOG_LEVEL_PREF]): a box report without a
	-- shell. The client's takes at once, the server's on its next start;
	-- -l on the command line wins for that run. The logs are
	-- cache/buildat.log and cache/buildat_server.log.
	{
		name = "log_level",
		label = "Client log (cache/buildat.log)",
		values = {1, 2, 3, 4, 5},
		show = function(v) return LOG_LEVEL_NAMES[v] end,
	},
	{
		name = "server_log_level",
		label = "Server log (cache/buildat_server.log), next start",
		values = {1, 2, 3, 4, 5},
		show = function(v) return LOG_LEVEL_NAMES[v] end,
	},
}

local function show_value(pref, value)
	if type(value) == "boolean" then
		return value and "on" or "off"
	end
	if pref.show then
		return pref.show(value)
	end
	return tostring(value)
end

-- The entry of pref.values that is nearest to what the preference actually
-- is. Nearest rather than equal because the value may have come from a
-- hand-edited file or from -o, and neither is restricted to this list; an
-- unlisted value still shows as the closest thing and cycles on from there.
local function nearest_index(pref, value)
	if type(value) == "boolean" then
		return value and 2 or 1
	end
	local best, best_d = 1, nil
	for i, v in ipairs(pref.values) do
		if v == value then
			return i
		end
		local d = type(v) == "number" and type(value) == "number" and
				math.abs(v - value) or math.huge
		if best_d == nil or d < best_d then
			best, best_d = i, d
		end
	end
	return best
end

-- A button and the Text inside it, kept rather than looked up again:
-- GetChild() hands back a UIElement and "text" is a property of Text, which
-- the sandbox is right to refuse. ui_utils.vertical_menu():add() takes a
-- button as readily as a label, so making it here costs nothing.
local function make_row(window, label)
	local button = window:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = 24
	button.minWidth = 320
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button, text
end

-- The launch UIs as a list, the one in use first: each its title, its
-- extension name, its description and whether it is experimental.
-- Picking one switches to it; Back and Escape leave it as it is.
local function show_launch_uis(uis, now)
	local root = uistack.main:push({desc = "launch UIs"})
	local menu = ui_utils.vertical_menu(root, {
		on_key = function(key)
			if key == KEY_ESCAPE then
				uistack.main:pop(root)
				return true
			end
		end,
	})
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Launch UI"
	title:SetFontSize(20)
	local order = {}
	for _, e in ipairs(uis) do
		table.insert(order, e.name == now and 1 or #order + 1, e)
	end
	for _, e in ipairs(order) do
		local button = menu.window:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(LM_VERTICAL, 2, magic.IntRect(8, 4, 8, 6))
		button:SetFixedWidth(460)
		local function line(text, size, colour)
			local t = button:CreateChild("Text")
			t:SetStyleAuto()
			t.text = text
			if size then t:SetFontSize(size) end
			if colour then t.color = colour end
			return t
		end
		line(e.title .. "   (" .. e.name .. ")" ..
				(e.name == now and "   - in use" or ""))
		if e.experimental then
			line("experimental", 12, magic.Color(1, 0.35, 0.3))
		end
		if e.description then
			local d = line(e.description, 12, magic.Color(0.7, 0.7, 0.7))
			-- simplified: 400 and not the row's 444, since under a UI
			-- scale the wrap measures a line narrower than it is drawn;
			-- the real fix is in the font scaling, not here
			d:SetFixedWidth(400)
			d:SetWordwrap(true)
		end
		menu:add(button, function()
			if e.name == now then
				uistack.main:pop(root)
				return
			end
			local ok, err = api.set_launch_ui(e.name)
			if not ok then
				log:warning("launch_ui: " .. tostring(err))
				ui_utils.show_message_dialog("Launch UI: " .. tostring(err))
			end
		end)
	end
	menu:add("Back", function()
		uistack.main:pop(root)
	end)
end

function M.show()
	local root = uistack.main:push({desc = "preferences"})

	local menu = ui_utils.vertical_menu(root, {
		on_key = function(key)
			if key == KEY_ESCAPE then
				uistack.main:pop(root)
				return true -- taken; the menu's own Escape = Back stands down
			end
		end,
	})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Engine settings"
	title:SetFontSize(20)

	for _, pref in ipairs(PREFERENCES) do
		local value = api.get_preference(pref.name)
		if value == nil then
			-- A build whose preferences this one does not have: leave the
			-- row out rather than showing a control that does nothing
			log:warning("No preference by the name "..pref.name)
		else
			local index = nearest_index(pref, value)
			local button, text = make_row(menu.window, pref.label)
			local function relabel()
				text.text =
						pref.label..": "..show_value(pref, pref.values[index])
			end
			menu:add(button, function()
				index = index % #pref.values + 1
				local ok, err = api.set_preference(pref.name,
						pref.values[index])
				if not ok then
					-- Cannot happen with the values above, and saying so is
					-- better than a button that quietly does nothing
					log:warning(pref.name..": "..tostring(err))
					ui_utils.show_message_dialog(
							pref.label..": "..tostring(err))
					return
				end
				relabel()
			end)
			relabel()
		end
	end

	-- **The name games offer when they ask for one** ([FP_LAUNCH]): a
	-- text, so a field rather than a cycling row. Enter sets it through
	-- the parser; a name it refuses is said and the field goes back.
	local username = api.get_preference("default_username")
	if username ~= nil then
		local row = menu.window:CreateChild("UIElement")
		row:SetLayout(LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		local label = row:CreateChild("Text")
		label:SetStyleAuto()
		label.text = "Default username for apps"
		local edit = row:CreateChild("LineEdit")
		edit:SetStyleAuto()
		edit:SetFixedHeight(26)
		edit.minWidth = 320
		edit.textSelectable = true
		edit.textCopyable = true
		edit:SetText(username)
		magic.SubscribeToEvent(edit, "TextFinished", function()
			local ok, err = api.set_preference("default_username",
					edit:GetText())
			if not ok then
				log:warning("default_username: " .. tostring(err))
				ui_utils.show_message_dialog(tostring(err))
				edit:SetText(api.get_preference("default_username") or "")
			end
		end)
	end

	-- **Which launch UI this is** ([LAUNCH_SANDBOX]'s slot, and
	-- [TWO_AUDIENCES]: switching is one action from either side). The
	-- listing is read from the extensions that ship a `launch_ui.txt`,
	-- not by running them. **Looking is not taking** (user, 2026-09-24):
	-- one of the options is a bare console, so the row only says which
	-- one is in use and opens the list, and the list takes nothing until
	-- an entry is picked (2026-10-06: the cycling row and its "Use"
	-- button under it read as two settings, and a long title did not fit).
	local uis = api.list_launch_uis and api.list_launch_uis() or {}
	if #uis > 1 then
		local now = api.launch_ui_name()
		local now_title = now
		for _, e in ipairs(uis) do
			if e.name == now then now_title = e.title end
		end
		local button = make_row(menu.window, "Launch UI: " .. now_title ..
				"  >")
		menu:add(button, function() show_launch_uis(uis, now) end)
	end

	menu:add("Back", function()
		uistack.main:pop(root)
	end)
end

return M
-- vim: set noet ts=4 sw=4:
