-- Buildat: extensions/luanti_client/settings.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The extension's own settings ([EXT_SETTINGS]), in
-- <user>/luanti_client/settings.json: the render mode, the view range,
-- the view bobbing amount, the player name and the last address. Read at
-- load; the BUILDAT_* environment variables stay one-run overrides for the
-- harness (init.lua reads those first). The screen is show(), a trusted
-- menu on the UI stack: back pops it, no server behind it.
--
-- The key bindings are init.lua's table; what differs from its defaults is
-- the "keys" map here (action -> Urho3D key name), applied at load, and
-- the editor is the one apps/vanilla shares (res/key_editor.lua).

local M = {}

local log = buildat.Logger("luanti_client/settings")
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local magic = require("buildat/extension/urho3d")
-- The engine's constants come from magic in the sandbox
local KEY_ESCAPE =
	magic.KEY_ESCAPE

-- The JSON reader and writer the network extension carries
local network = require("buildat/extension/network")
local json = {parse = network.parse_json, write = network.write_json}

-- In the extension's own storage: <user>/luanti_client/settings.json
local path = "settings.json"

-- The initial player name is made up once, two words ([BOX_PLAYTEST_2]
-- 4): every player called "buildat" on a public server is a name taken
local ADJECTIVES = {"quiet", "bright", "swift", "mossy", "amber", "brave",
		"clever", "dusty", "eager", "gentle", "hardy", "jolly", "keen", "lucky",
		"merry", "nimble", "plain", "rusty", "sunny", "witty"}
local NOUNS = {"otter", "heron", "badger", "finch", "lynx", "marten", "newt",
		"osprey", "pike", "raven", "stoat", "tern", "vole", "wren", "beaver",
		"crane", "dace", "elk", "fox", "grouse"}
local function random_name()
	local a, n = buildat.random_bytes(2):byte(1, 2)
	return ADJECTIVES[a % #ADJECTIVES + 1] .. "-" .. NOUNS[n % #NOUNS + 1]
end

M.DEFAULTS = {mode = "unlit", view_range = 120, view_bobbing = 1,
		shoulder = 0, name = random_name(), address = "localhost:30000",
		-- What was typed in the server list's filter last time: a player
		-- filters for the same server every time ([BOX_PLAYTEST_2] 13b)
		server_filter = "", keys = {}}

-- The bindings table, for the screen's "Key bindings..." row; init.lua
-- sets it
M.bindings = nil

function M.load()
	local out = {}
	for k, v in pairs(M.DEFAULTS) do
		out[k] = type(v) == "table" and {} or v
	end
	local text = buildat.storage_read(path)
	if text then
		local data = json.parse(text)
		for k, _ in pairs(M.DEFAULTS) do
			if data and data[k] ~= nil and type(data[k]) == type(M.DEFAULTS[k]) then
				out[k] = data[k]
			end
		end
	end
	return out
end

function M.save(settings)
	local ok, err = buildat.storage_write(path, json.write(settings, true))
	if not ok then
		log:warning("cannot write "..path..": "..tostring(err))
		return false
	end
	return true
end

-- The saved names applied to the bindings table: a name that is no key
-- here leaves the default
function M.apply_keys(bindings)
	local keys = M.load().keys
	local changed = 0
	for _, b in ipairs(bindings) do
		if b.default_key ~= nil then
			local name = keys[b.action]
			local key = type(name) == "string" and
					magic.input:GetKeyFromName(name) or 0
			if key ~= 0 then
				b.key, b.name = key, name
				changed = changed + 1
			else
				b.key, b.name = b.default_key, b.default_name
			end
		end
	end
	if changed > 0 then
		log:info(changed.." key bindings from the settings")
	end
end

-- The shared editor over the bindings table; a change writes the map of
-- what differs from the defaults. on_back is what the back row does.
function M.show_keys(bindings, on_back)
	local editor = buildat.run_extension_file("res/key_editor.lua")
	return editor.draw{magic = magic, uistack = uistack, ui_utils = ui_utils,
			bindings = bindings,
			save = function()
				local s = M.load()
				s.keys = {}
				for _, b in ipairs(bindings) do
					if b.default_key ~= nil and b.key ~= b.default_key then
						s.keys[b.action] = b.name
					end
				end
				M.save(s)
			end,
			on_back = on_back or function() end}
end

-- The name a join went through with, kept on the server's row in the
-- network extension's address store ([BOX_PLAYTEST_2] 4); the connect
-- screen fills it in when that server is picked again. Here rather than
-- in init.lua's session callback, which is at Lua's 60-upvalue line.
function M.remember_server_name(host, port, name)
	local uri = "udp://" .. host .. ":" .. port
	local ok = require("buildat/extension/network").set_address_name(uri, name)
	log:info("player name " .. name .. (ok and " kept for " or " not kept for ") .. uri)
end

local MODES = {"unlit", "shadows", "pbr"}
local RANGES = {60, 120, 200, 300, 400}

-- The screen: every row cycles its value and saves; back pops
function M.show()
	local s = M.load()
	local root = uistack.main:push({desc = "luanti_client settings"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Luanti client settings"
	local function labeled_edit(label, value)
		local text = menu.window:CreateChild("Text")
		text:SetStyleAuto()
		text.text = label
		local edit = menu.window:CreateChild("LineEdit")
		edit:SetStyleAuto()
		-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
		edit.textCopyable = true
		edit.textSelectable = true
		edit:SetFixedHeight(26)
		edit.minWidth = 300
		edit:SetText(value or "")
		return edit
	end
	local name_edit = labeled_edit("Player name", s.name)
	local address_edit = labeled_edit("Last address", s.address)
	local function cycle(list, value)
		for i, v in ipairs(list) do
			if v == value then
				return list[i % #list + 1]
			end
		end
		return list[1]
	end
	local rows = {}
	local function redraw_rows()
		rows.mode:GetChild("ButtonText"):SetText("Render mode (next session): "..s.mode)
		rows.range:GetChild("ButtonText"):SetText("View range (next session): "..s.view_range)
		rows.bob:GetChild("ButtonText"):SetText("View bobbing: "..
				(s.view_bobbing ~= 0 and "on" or "off"))
		rows.shoulder:GetChild("ButtonText"):SetText(
				"Third person: "..(s.shoulder ~= 0 and "over the shoulder"
				or "centred"))
	end
	local function save()
		s.name = name_edit:GetText()
		s.address = address_edit:GetText()
		M.save(s)
		redraw_rows()
	end
	rows.mode = menu:add("", function()
		s.mode = cycle(MODES, s.mode)
		save()
	end)
	rows.range = menu:add("", function()
		s.view_range = cycle(RANGES, s.view_range)
		save()
	end)
	rows.bob = menu:add("", function()
		s.view_bobbing = s.view_bobbing ~= 0 and 0 or 1
		save()
	end)
	rows.shoulder = menu:add("", function()
		s.shoulder = s.shoulder ~= 0 and 0 or 1
		save()
	end)
	redraw_rows()
	if M.bindings then
		menu:add("Key bindings...", function()
			save()
			M.show_keys(M.bindings)
		end)
	end
	menu:add("Save", save)
	menu:add("Back", function()
		save()
		uistack.main:pop(root)
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			save()
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
