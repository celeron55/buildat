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
-- The one line the waiting screen shows, kept so that the next thing to say
-- is a text change rather than a screen built again: what the server says
-- while a game loads is one line per mod, and a game has a couple of hundred
local waiting_text = nil
local games = {}
-- Which page of the save list is on the screen; the list is redrawn when it
-- changes, which is what every other change to this menu does too
local page = 1
-- What the last save list said, so that a screen that goes back to it does
-- not have to ask the server again
local last_saves, last_save_games = {}, {}
-- What is out there to import, as main:imports last said: each entry is
-- {id or name, title or gameid, "installed" or ""}
local import_games, import_worlds = {}, {}
-- Which of the two import lists the next main:imports is for, and which page
-- of it is on the screen
local want_imports = nil
local import_page = 1

local function close()
	if root then
		uistack.main:pop(root)
		root = nil
	end
	waiting_text = nil
end

local function waiting(message)
	close()
	root = uistack.main:push({desc = "luanti_launcher menu"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(message)
	waiting_text = text
end

-- A save is a button; a new one is a name typed in and one button per game,
-- which is the whole of "which game it needs" without a second screen.
-- Declared first because a page button draws it again.
local draw
-- And the import screens, which go back to it
local draw_import_games
local draw_import_worlds

function draw(saves, save_games)
	last_saves, last_save_games = saves, save_games
	close()
	root = uistack.main:push({desc = "luanti_launcher menu"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("luanti_launcher: which save?")

	-- Every save, twelve at a time, newest first: the server sorts them by
	-- when each was last played
	local items = {}
	for i, name in ipairs(saves) do
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
		items[#items + 1] = {label = label, action = function()
			waiting("Opening " .. name .. "...")
			buildat.send_packet("main:open",
					cereal.binary_output({name}, {"array", "string"}))
		end}
	end
	ui_utils.add_paged(menu, items, {
		page = page,
		per_page = 12,
		redraw = function(new_page)
			page = new_page
			draw(saves, save_games)
		end,
	})

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

	-- What a real Luanti installation has, which is where a game and a world
	-- come from until somebody has put one here by hand
	local function ask_for_imports(which)
		want_imports = which
		import_page = 1
		waiting("Looking in your Luanti installation...")
		buildat.send_packet("main:get_imports", "")
	end
	menu:add("Import a game from Luanti...", function()
		ask_for_imports("games")
	end)
	menu:add("Import a world from Luanti...", function()
		ask_for_imports("worlds")
	end)

	magic.input:SetMouseVisible(true)
end

-- How big it is, the way buildat's own game menu says it: see
-- format_bytes() in extensions/launch_menu/init.lua, which this is the same
-- ladder as. A menu that says nothing about size is a menu that cannot tell
-- a moment's copy from a minute's.
local function format_bytes(n)
	n = math.floor(tonumber(n) or 0)
	if n < 1024 then
		return n .. " B"
	end
	local kb = n / 1024
	if kb < 1024 then
		if kb < 10 then
			return string.format("%.1f KB", kb)
		end
		return math.floor(kb + 0.5) .. " KB"
	end
	local mb = kb / 1024
	if mb < 1024 then
		if mb < 10 then
			return string.format("%.1f MB", mb)
		end
		return math.floor(mb + 0.5) .. " MB"
	end
	local gb = mb / 1024
	if gb < 10 then
		return string.format("%.1f GB", gb)
	end
	return math.floor(gb + 0.5) .. " GB"
end

-- The screen the two import buttons lead to. Both are a list of what was
-- found with a line each, and both can go back to the save list.
local function import_menu(title)
	close()
	root = uistack.main:push({desc = "luanti_launcher menu"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(title)
	return menu
end

local function back_to_saves(menu)
	menu:add("< back", function()
		draw(last_saves, last_save_games)
	end)
	magic.input:SetMouseVisible(true)
end

function draw_import_games()
	local menu = import_menu("Which game? (copied into buildat's own games)")
	local items = {}
	for _, g in ipairs(import_games) do
		local label = g[1]
		if g[2] ~= "" and g[2] ~= g[1] then
			label = label .. "   (" .. g[2] .. ")"
		end
		label = label .. "   " .. format_bytes(g[4])
		if g[3] == "installed" then
			-- Listed and said so rather than hidden: the same rule the save
			-- list follows about a save whose game is missing
			label = label .. "  -- already installed"
		end
		items[#items + 1] = {label = label, action = function()
			if g[3] == "installed" then
				ui_utils.show_message_dialog(g[1] .. " is already installed." ..
						" Remove it yourself if you mean to replace it.")
				return
			end
			waiting("Copying " .. g[1] .. "...")
			buildat.send_packet("main:import_game",
					cereal.binary_output({g[1]}, {"array", "string"}))
		end}
	end
	if #items == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("Nothing found. Looked in $LUANTI_EXTRA_IMPORT_PATH," ..
				" ~/.luanti and ~/.minetest.")
	end
	ui_utils.add_paged(menu, items, {
		page = import_page,
		per_page = 12,
		redraw = function(new_page)
			import_page = new_page
			draw_import_games()
		end,
	})
	back_to_saves(menu)
end

-- A world becomes a save rather than being copied, so what this asks for on
-- the way is the save's name -- prefilled with the world's own, which is
-- what the user meant nine times in ten
local function draw_import_world_name(world)
	local menu = import_menu("Import the world " .. world[1] ..
			" (game: " .. world[2] .. ", " .. format_bytes(world[4]) .. ")")
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText("as a save named:")
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(world[1])
	menu:add("Import and play", function()
		local name = edit:GetText()
		waiting("Importing " .. world[1] .. " into " .. name .. "...")
		buildat.send_packet("main:import_world",
				cereal.binary_output({world[1], name}, {"array", "string"}))
	end)
	menu:add("< back", function()
		draw_import_worlds()
	end)
	magic.input:SetMouseVisible(true)
end

function draw_import_worlds()
	local menu = import_menu("Which world? (read into a new save)")
	local items = {}
	for _, w in ipairs(import_worlds) do
		local label = w[1] .. "   (" .. w[2] .. ")   " .. format_bytes(w[4])
		if w[3] ~= "installed" then
			label = label .. "  -- import " .. w[2] .. " first"
		end
		items[#items + 1] = {label = label, action = function()
			if w[3] ~= "installed" then
				ui_utils.show_message_dialog(w[1] .. " wants the game " ..
						w[2] .. ", which is not installed. Import that" ..
						" first.")
				return
			end
			draw_import_world_name(w)
		end}
	end
	if #items == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("Nothing found. Looked in $LUANTI_EXTRA_IMPORT_PATH," ..
				" ~/.luanti and ~/.minetest.")
	end
	ui_utils.add_paged(menu, items, {
		page = import_page,
		per_page = 12,
		redraw = function(new_page)
			import_page = new_page
			draw_import_worlds()
		end,
	})
	back_to_saves(menu)
end

-- The world came up while the menu was still asking for the save list: the
-- server was busy loading the game, so the answer it was asked for arrives
-- after it says the menu is done with. Without this the list draws itself
-- over the world the client is already in.
local done = false

buildat.sub_packet("main:saves", function(data)
	if done then
		return
	end
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

buildat.sub_packet("main:imports", function(data)
	if done then
		return
	end
	local values = cereal.binary_input(data, {"array", "string"})
	local n = tonumber(values[1]) or 0
	import_games = {}
	import_worlds = {}
	for i = 1, n do
		local at = 1 + (i - 1) * 4
		import_games[i] = {values[at + 1] or "", values[at + 2] or "",
				values[at + 3] or "", values[at + 4] or "0"}
	end
	local at = 1 + n * 4 + 1
	while at + 3 <= #values do
		import_worlds[#import_worlds + 1] = {values[at], values[at + 1],
				values[at + 2], values[at + 3]}
		at = at + 4
	end
	log:info("menu: " .. #import_games .. " games and " .. #import_worlds ..
			" worlds to import")
	if want_imports == "worlds" then
		draw_import_worlds()
	else
		draw_import_games()
	end
end)

-- What the server is doing while the game loads: 220 mods take minutes and
-- a line that says "Creating <name>..." for all of them looks hung. The
-- server names each mod as it loads it; see set_progress_handler() in
-- builtin/luanti/api.h.
buildat.sub_packet("main:progress", function(data)
	if done then
		return
	end
	local line = cereal.binary_input(data, {"array", "string"})[1]
	if line == nil then
		return
	end
	if waiting_text then
		waiting_text:SetText(line)
	else
		waiting(line)
	end
end)

buildat.sub_packet("main:menu_error", function(data)
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:warning("menu: " .. tostring(message))
	-- The list is asked for again once the dialog is gone, not while it is
	-- up: the dialog is on top of the menu in the UI stack, and drawing the
	-- menu again takes the menu's own root out from under it
	ui_utils.show_message_dialog(tostring(message), function()
		buildat.send_packet("main:get_saves", "")
	end)
end)

-- The world is up and main/init.lua is what draws from here on
buildat.sub_packet("main:menu_done", function()
	done = true
	waiting_text = nil
	close()
end)

buildat.send_packet("main:get_saves", "")
waiting("Looking for saves...")
-- vim: set noet ts=4 sw=4:
