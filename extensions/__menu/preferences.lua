-- Buildat: extension/__menu/preferences.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The preferences screen: what the user sets once and every game honours.
--
-- doc/plan/client_preferences_plan.md built the preferences and made every
-- game honour them, but until this nothing set them except a file and -o.
-- The C++ side stays the authority -- buildat.set_preference() parses and
-- range checks a value through the same code -o goes through, applies what
-- takes effect now, and persists the rest -- so this file is a page of
-- widgets that knows nothing about the file and cannot set a value a flag
-- could not.
--
-- One button per preference, cycling through the values worth offering.
-- Cycling rather than a slider because the keyboard navigation this menu
-- already has moves up and down a list of buttons, and a slider inside one
-- would need a second kind of focus for one screen's sake.
local log = buildat.Logger("extension/__menu/preferences")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe

local M = {}

-- The values each preference offers, and how one is written out. The ranges
-- are the parser's own -- see parse_preference_options() in src/client/app.cpp
-- -- so nothing here can be refused; what is offered is the useful subset of
-- what is allowed.
local function percent(v)
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

local PREFERENCES = {
	{
		name = "render_scale",
		label = "Render scale",
		-- 1.0 is no scaling at all and is the bypass: the game draws into
		-- the window itself. Above it is supersampling, which the same code
		-- path gives away for free.
		values = {0.5, 0.67, 0.75, 1.0, 1.5, 2.0},
		show = percent,
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
	{
		name = "sound_volume",
		label = "Sound volume",
		values = {0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0},
		show = percent,
	},
	{
		name = "sound_mute",
		label = "Mute",
		values = {false, true},
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
		local d = math.abs(v - value)
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

function M.show()
	local root = uistack.main:push({desc = "preferences"})

	local menu = ui_utils.vertical_menu(root, {
		on_key = function(key)
			if key == KEY_ESCAPE then
				uistack.main:pop(root)
			end
		end,
	})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Preferences"
	title:SetFontSize(20)

	for _, pref in ipairs(PREFERENCES) do
		local value = buildat.get_preference(pref.name)
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
				local ok, err = buildat.set_preference(pref.name,
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

	menu:add("Back", function()
		uistack.main:pop(root)
	end)
end

return M
-- vim: set noet ts=4 sw=4:
