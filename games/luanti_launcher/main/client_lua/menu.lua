-- Buildat: luanti_launcher/client_lua/menu.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Which save, and which game it needs. The two were always two facts
-- pretending to be one in Luanti's own menu, and here they are two: a save
-- is listed with the game it says it needs, and a new one is named and given
-- a game to need.
--
-- The scan is the server's, because the server owns the filesystem; this
-- draws what it sends and sends back what was chosen. Once something is
-- chosen this goes away and main/init.lua is what arrives.
local log = buildat.Logger("luanti_launcher")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local ui_utils = require("buildat/extension/ui_utils")
local uistack = require("buildat/extension/uistack")

local root = nil
local games = {}

local function close()
	if root then
		uistack.main:pop(root)
		root = nil
	end
end

local function waiting(message)
	close()
	root = uistack.main:push({desc = "luanti_launcher menu"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(message)
end

-- A save is a button; a new one is a name typed in and one button per game,
-- which is the whole of "which game it needs" without a second screen.
local function draw(saves, save_games)
	close()
	root = uistack.main:push({desc = "luanti_launcher menu"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("luanti_launcher: which save?")

	-- simplified: the most recent few, because a vertical_menu does not
	-- scroll and a list longer than the screen is a list with saves nobody
	-- can reach. What it wants is a scrolling list; until then the server
	-- sorts by when each was last played and BUILDAT_LUANTI_SAVE opens one
	-- by name.
	local SHOWN = 12
	for i, name in ipairs(saves) do
		if i > SHOWN then
			break
		end
		local gameid = save_games[i]
		local known = false
		for _, g in ipairs(games) do
			if g == gameid then
				known = true
			end
		end
		local label = name .. "   (" ..
				(gameid ~= "" and gameid or "game not recorded") .. ")"
		if gameid ~= "" and not known then
			-- Still listed: a save whose game is not installed is a save,
			-- and saying so is more use than hiding it
			label = label .. "  -- no such game"
		end
		menu:add(label, function()
			waiting("Opening " .. name .. "...")
			buildat.send_packet("main:open",
					cereal.binary_output({name}, {"array", "string"}))
		end)
	end
	if #saves > SHOWN then
		local more = menu.window:CreateChild("Text")
		more:SetStyleAuto()
		more:SetText("and " .. (#saves - SHOWN) .. " older ones, which this" ..
				" list cannot reach yet")
	end

	local new_text = menu.window:CreateChild("Text")
	new_text:SetStyleAuto()
	new_text:SetText("or a new save, named:")

	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText("world")

	for _, gameid in ipairs(games) do
		menu:add("new, playing " .. gameid, function()
			local name = edit:GetText()
			waiting("Creating " .. name .. "...")
			buildat.send_packet("main:create",
					cereal.binary_output({name, gameid}, {"array", "string"}))
		end)
	end

	magic.input:SetMouseVisible(true)
end

buildat.sub_packet("main:saves", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	local n = tonumber(values[1]) or 0
	local saves = {}
	local save_games = {}
	for i = 1, n do
		saves[i] = values[i * 2] or ""
		save_games[i] = values[i * 2 + 1] or ""
	end
	games = {}
	for i = n * 2 + 2, #values do
		games[#games + 1] = values[i]
	end
	log:info("menu: " .. #saves .. " saves, " .. #games .. " games")
	draw(saves, save_games)
end)

buildat.sub_packet("main:menu_error", function(data)
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:warning("menu: " .. tostring(message))
	ui_utils.show_message_dialog(tostring(message))
	buildat.send_packet("main:get_saves", "")
end)

-- The world is up and main/init.lua is what draws from here on
buildat.sub_packet("main:menu_done", function()
	close()
end)

buildat.send_packet("main:get_saves", "")
waiting("Looking for saves...")
-- vim: set noet ts=4 sw=4:
