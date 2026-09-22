-- Buildat: extensions/luanti_client/settings.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The extension's own settings ([EXT_SETTINGS]), in
-- <user>/luanti_client/settings.json: the render mode, the view range,
-- the view bobbing amount, the player name and the last address. Read at
-- load; the BUILDAT_* environment variables stay one-run overrides for the
-- harness (init.lua reads those first). The screen is show(), a trusted
-- menu on the UI stack: back pops it, no server behind it.
--
-- simplified: the key bindings stay init.lua's table; the editor shared
-- with vanilla's keys.lua is the next step.

local M = {}

local log = buildat.Logger("luanti_client/settings")
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe
local magic = require("buildat/extension/urho3d").safe

-- The JSON reader and writer the network extension carries
local json
do
	local saved = rawget(_G, "core")
	rawset(_G, "core", {log = function(_, message) log:warning(message) end})
	dofile(__buildat_extension_path("network").."/json.lua")
	json = {parse = core.parse_json, write = core.write_json}
	rawset(_G, "core", saved)
end

local dir = __buildat_get_path("user").."/luanti_client"
local path = dir.."/settings.json"

M.DEFAULTS = {mode = "unlit", view_range = 120, view_bobbing = 1,
		name = "buildat", address = "localhost:30000"}

function M.load()
	local out = {}
	for k, v in pairs(M.DEFAULTS) do
		out[k] = v
	end
	local f = io.open(path, "rb")
	if f then
		local data = json.parse(f:read("*a"))
		f:close()
		for k, _ in pairs(M.DEFAULTS) do
			if data and data[k] ~= nil and type(data[k]) == type(M.DEFAULTS[k]) then
				out[k] = data[k]
			end
		end
	end
	return out
end

function M.save(settings)
	os.execute("mkdir -p '"..dir.."'")
	local f = io.open(path, "wb")
	if not f then
		log:warning("cannot write "..path)
		return false
	end
	f:write(json.write(settings, true))
	f:close()
	return true
end

local MODES = {"unlit", "shadows", "pbr"}
local RANGES = {60, 120, 200, 300, 400}

-- The screen: every row cycles its value and saves; back pops
function M.show()
	local s = M.load()
	local root = uistack.main:push({desc = "luanti_client settings"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
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
	redraw_rows()
	menu:add("Save", save)
	menu:add("Back", function()
		save()
		uistack.main:pop(root)
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			save()
			uistack.main:pop(root)
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
