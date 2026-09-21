-- Buildat: vanilla/client_lua/menu.lua
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
local log = buildat.Logger("vanilla")
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
-- The screen a launch asked for, from the server's main:menu, until the
-- save list has opened it
local menu_wanted = nil
-- And the game the save list is for, when a tile asked for one game's
-- worlds ("worlds:<gameid>"): the list shows that game's saves and New
-- save is that game's ([LAUNCH_GRID])
local menu_game = nil
buildat.sub_packet("main:menu", function(data)
	local game = data:match("^worlds:(.+)$")
	if game then
		menu_game = game
		menu_wanted = nil
	else
		menu_wanted = data
	end
end)
local import_page = 1

-- What is typed into each list's filter box, kept across the redraws a page
-- turn or a filter change costs. See add_filter().
local save_filter = ""
local import_filter = ""
local game_filter = ""
-- Which page of the game list the new-save flow is on
local game_page = 1

local function close()
	-- A screen of another instance of this script: the media batch re-runs
	-- the client scripts, and the second instance's root is nil while the
	-- first's "Building the world" is still on top of the stack, held by
	-- nobody ([WIN_WORLD] (b), the box). The stack is the extension's, one
	-- for every instance, so the screen on top is closed by its name.
	if root == nil then
		local top = uistack.main.stack[#uistack.main.stack]
		if top and top:GetName():find(": vanilla menu: ", 1, true) then
			root = top
		end
	end
	if root then
		uistack.main:pop(root)
		root = nil
	end
	waiting_text = nil
end

-- The world came up while the menu was still asking for the save list: the
-- server was busy loading the game, so the answer it was asked for arrives
-- after it says the menu is done with. Without this the list draws itself
-- over the world the client is already in. And the guard the other way
-- round ([WIN8_START] 15): nothing here opens a screen once the world is
-- up, whatever packet asks -- a box kept "Building the world" over a
-- world the player was walking in.
local done = false

local function waiting(message)
	if done then
		log:info("menu: no waiting screen for " .. tostring(message) ..
				": the world is up")
		return
	end
	close()
	root = uistack.main:push({desc = "vanilla menu: waiting"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(message)
	waiting_text = text
	-- And the seconds under it, so the screen moves while the user can
	-- only wait ([FIRST_RUN]: a screen still for 4 s fails the driven
	-- first run); the message itself moves only when the server says
	local secs = menu.window:CreateChild("Text")
	secs:SetStyleAuto()
	local t0 = buildat.get_time_us()
	root:SubscribeToStackEvent("Update", function()
		secs:SetText(math.floor((buildat.get_time_us() - t0) / 1000000) .. " s")
	end)
end

-- A save is a button, and a new one is a game chosen and then named --
-- two screens, the way importing a world already is, because one button per
-- installed game is twenty-five buttons on this machine and a menu stops
-- being a menu somewhere around ten.
-- Declared first because a page button draws it again.
local draw
local draw_new_game
-- And the import screens, which go back to the save list
local draw_import_games
local draw_import_worlds
-- And the settings screen, drawn from the server's main:settings
local draw_settings
-- The key bindings editor, shared with the game's pause menu, and
-- whether it is the screen up now
local keys_open = false
local keys_editor = (function(ok, err, m)
	if not ok or type(m) ~= "table" then
		error("vanilla menu: could not load keys.lua: " .. tostring(err))
	end
	return m
end)(buildat.run_script_file("main/keys.lua"))
-- ContentDB's games ([CONTENTDB]): the server fetches, this asks and draws
local ask_contentdb, draw_contentdb
local contentdb_query = ""
-- And the name field of a new save, which the one-game list goes to
local draw_new_save_name

-- Does this line answer what was typed? Case-insensitive, and every word has
-- to be in it somewhere, so "vox cave" finds a VoxeLibre world called caves.
-- A plain find rather than a pattern: a world named "world (2)" is a name
-- here and not a pattern, and so is anything else somebody types.
local function matches(label, filter)
	label = label:lower()
	for word in filter:lower():gmatch("%S+") do
		if not label:find(word, 1, true) then
			return false
		end
	end
	return true
end

-- A filter box over a long list, and the line that says what it did.
--
-- **The sandbox has no scrolling container** -- ui_utils.add_paged() exists
-- because of that -- and two hundred and thirty-four worlds twelve to a page
-- is twenty pages, which is not a list anybody reads. Three characters typed
-- here take it down to the few worth looking at, which beats scrolling even
-- where scrolling exists.
--
-- simplified: it applies when Enter is pressed rather than as the letters
-- arrive, because TextChanged is not in extensions/urho3d/safe_events.lua
-- and a redraw per letter would take the field out from under the typing
-- anyway. The upgrade path is whitelisting that event and rebuilding only
-- the list of buttons instead of the screen.
local function add_filter(menu, filter, total, shown, on_change)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	if filter ~= "" then
		text:SetText("filter (enter to apply): " .. shown .. " of " ..
				total .. " shown")
	else
		text:SetText("filter (enter to apply), " .. total .. " in the list:")
	end
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(filter)
	magic.SubscribeToEvent(edit, "TextFinished",
	function(self, event_type, event_data)
		on_change(edit:GetText())
	end)
	return edit
end

-- What is left of a list once the filter has had it, in the same order
local function filtered(items, filter)
	if filter == "" then
		return items
	end
	local out = {}
	for _, item in ipairs(items) do
		if matches(item.label, filter) then
			out[#out + 1] = item
		end
	end
	return out
end

do
	local items = {
		{label = "world   (minetest_game)"},
		{label = "caves   (voxelibre)  -- no such game"},
		{label = "world (2)   (nodecore)"},
	}
	assert(#filtered(items, "") == 3, "filter: an empty one takes nothing out")
	assert(#filtered(items, "WORLD") == 2, "filter: case")
	assert(filtered(items, "vox cave")[1] == items[2],
			"filter: every word, in any order")
	-- A name is a name and not a pattern, which is what a save called
	-- "world (2)" would be if this used one
	assert(#filtered(items, "world (2)") == 1, "filter: not a pattern")
	assert(#filtered(items, "nothing") == 0, "filter: no match is no rows")
end

function draw(saves, save_games)
	last_saves, last_save_games = saves, save_games
	close()
	root = uistack.main:push({desc = "vanilla menu: saves"})
	local menu = ui_utils.vertical_menu(root, {min_width = 420})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText(menu_game and (menu_game .. ": which world?") or
			"vanilla: which save?")

	-- Every save, twelve at a time, newest first: the server sorts them by
	-- when each was last played
	local items = {}
	for i, name in ipairs(saves) do
		local gameid = save_games[i]
		if menu_game and gameid ~= menu_game then
			goto next_save
		end
		local known = false
		for _, g in ipairs(games) do
			if g == gameid then
				known = true
			end
		end
		local label = menu_game and name or (name .. "   (" ..
				(gameid ~= "" and gameid or "game not recorded") .. ")")
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
		::next_save::
	end
	local shown = filtered(items, save_filter)
	add_filter(menu, save_filter, #items, #shown, function(text)
		save_filter = text
		page = 1
		draw(saves, save_games)
	end)
	ui_utils.add_paged(menu, shown, {
		page = page,
		per_page = 12,
		redraw = function(new_page)
			page = new_page
			draw(saves, save_games)
		end,
	})

	-- One button rather than one per game: which game is a choice, and it
	-- goes on the same screen as the name it is being given
	menu:add(menu_game and "New world..." or "New save...", function()
		if menu_game then
			draw_new_save_name(menu_game)
			return
		end
		game_filter = ""
		game_page = 1
		draw_new_game()
	end)

	-- What a real Luanti installation has, which is where a game and a world
	-- come from until somebody has put one here by hand
	local function ask_for_imports(which)
		want_imports = which
		import_page = 1
		import_filter = ""
		waiting("Looking in your Luanti installation...")
		buildat.send_packet("main:get_imports", "")
	end
	menu:add("Import a game from Luanti...", function()
		ask_for_imports("games")
	end)
	menu:add("Import a world from Luanti...", function()
		ask_for_imports("worlds")
	end)

	magic.input:SetMouseVisible(true, "a menu screen")

	-- A launch that asked for an import screen goes straight to it, once
	-- the save list it comes back to is drawn ([LAUNCH_GRID])
	if menu_wanted == "import_game" then
		menu_wanted = nil
		ask_for_imports("games")
	elseif menu_wanted == "import_world" then
		menu_wanted = nil
		ask_for_imports("worlds")
	elseif menu_wanted == "settings" then
		menu_wanted = nil
		waiting("Reading the settings...")
		buildat.send_packet("main:get_settings", "")
	elseif menu_wanted == "contentdb" then
		menu_wanted = nil
		ask_contentdb("")
	end
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
	root = uistack.main:push({desc = "vanilla menu: " .. title})
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
	magic.input:SetMouseVisible(true, "a menu screen")
end

-- The launcher's settings ([LAUNCH_GRID]): the import search paths, a list
-- to add to and remove from, kept by the server in user/luanti/launcher.json
-- and sent whole each way. The defaults (~/.luanti, ~/.minetest and the
-- variable) are the server's and not in the list.
function draw_settings(paths)
	local menu = import_menu("Luanti settings")
	-- The render mode rides in the list as "render_mode=<mode>", and the
	-- key bindings as "key.<action>=<name>" rows ([KEY_BINDINGS]), which
	-- keys.lua reads and the editor writes; both go back with the paths
	local mode = "pbr"
	local view_range = "120"
	local kept = {}
	local key_rows = {}
	for _, p in ipairs(paths) do
		local m = p:match("^render_mode=(.*)$")
		local r = p:match("^view_range=(%d+)$")
		if m then
			mode = m
		elseif r then
			view_range = r
		elseif p:match("^key%.") then
			key_rows[#key_rows + 1] = p
		else
			kept[#kept + 1] = p
		end
	end
	paths = kept
	local function send(list)
		waiting("Saving...")
		list[#list + 1] = "render_mode=" .. mode
		list[#list + 1] = "view_range=" .. view_range
		for _, r in ipairs(key_rows) do
			list[#list + 1] = r
		end
		buildat.send_packet("main:set_settings",
				cereal.binary_output(list, {"array", "string"}))
	end
	-- The key bindings editor, keys.lua's screen; the server's answer to
	-- its save draws this screen again, so back comes here with the rows
	menu:add("Key bindings...", function()
		local all = {}
		for _, p in ipairs(paths) do
			all[#all + 1] = p
		end
		all[#all + 1] = "render_mode=" .. mode
		all[#all + 1] = "view_range=" .. view_range
		for _, r in ipairs(key_rows) do
			all[#all + 1] = r
		end
		keys_editor.apply(all)
		close()
		keys_open = true
		keys_editor.draw(function()
			keys_open = false
			buildat.send_packet("main:get_settings", "")
			waiting("Loading settings...")
		end)
	end)
	-- The mode a session draws in, unless BUILDAT_LUANTI_PBR says
	-- otherwise ([RENDER_MODES]); the current one marked
	local modes = menu.window:CreateChild("Text")
	modes:SetStyleAuto()
	modes:SetText("Render mode (the next session's; BUILDAT_LUANTI_PBR overrides):")
	for _, m in ipairs({"pbr", "shadows", "unlit"}) do
		menu:add((m == mode and "[x] " or "[ ] ") .. m, function()
			mode = m
			local list = {}
			for _, p in ipairs(paths) do
				list[#list + 1] = p
			end
			send(list)
		end)
	end
	-- The viewing range ([VIEW_RANGE]): how far the server sends, the
	-- client meshes and the camera draws; 120 unless set, so a new
	-- install does not bet on a strong computer. Applied at once in a
	-- running world, and to the next one.
	-- simplified: the five picks; a number field for the rest when
	-- somebody wants 90.
	local range_text = menu.window:CreateChild("Text")
	range_text:SetStyleAuto()
	range_text:SetText("View range, in nodes (farther is slower):")
	for _, r in ipairs({"60", "120", "200", "300", "400"}) do
		menu:add((r == view_range and "[x] " or "[ ] ") .. r, function()
			view_range = r
			local list = {}
			for _, p in ipairs(paths) do
				list[#list + 1] = p
			end
			send(list)
		end)
	end
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText("Import search paths, besides ~/.luanti and ~/.minetest:")
	for i, path in ipairs(paths) do
		menu:add("remove  " .. path, function()
			local list = {}
			for j, p in ipairs(paths) do
				if j ~= i then
					list[#list + 1] = p
				end
			end
			send(list)
		end)
	end
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText("")
	menu:add("Add the path above", function()
		local path = edit:GetText()
		path = path:gsub("^%s+", ""):gsub("%s+$", "")
		if path == "" then
			return
		end
		local list = {}
		for _, p in ipairs(paths) do
			list[#list + 1] = p
		end
		list[#list + 1] = path
		send(list)
	end)
	back_to_saves(menu)
end

-- ContentDB's games, fetched by the server ([CONTENTDB]): a search field,
-- a line per game with its title, author and one-line description, and
-- Install on each, which the server answers with progress lines and a
-- message when the game is in place (it shows on the grid as an imported
-- game does). simplified: no thumbnails yet, and the first page only --
-- the query narrows it.
function ask_contentdb(query)
	contentdb_query = query
	waiting("Asking ContentDB...")
	buildat.send_packet("main:contentdb_query",
			cereal.binary_output({query}, {"array", "string"}))
end

function draw_contentdb(flat)
	local menu = import_menu("ContentDB: games" ..
			(contentdb_query ~= "" and (" matching \"" .. contentdb_query .. "\"") or ""))
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(contentdb_query)
	menu:add("Search", function()
		ask_contentdb((edit:GetText():gsub("^%s+", ""):gsub("%s+$", "")))
	end)
	local n = 0
	for i = 1, #flat - 4, 5 do
		local author, name, title, desc = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		n = n + 1
		menu:add("Install  " .. title .. "  by " .. author ..
				(desc ~= "" and ("  -- " .. desc) or ""), function()
			waiting("Fetching " .. name .. "...")
			buildat.send_packet("main:contentdb_install",
					cereal.binary_output({author, name}, {"array", "string"}))
		end)
	end
	if n == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("Nothing found")
	end
	back_to_saves(menu)
end

-- A new save, in the two steps importing a world already takes: which game,
-- and then what to call it. The name field is on the second screen with the
-- game it is for, rather than above a column of one button per game.
function draw_new_save_name(gameid)
	local menu = import_menu("New save, playing " .. gameid)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText("named:")
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText("world")
	-- The seed, beside the name: empty is a random one; a number is
	-- Luanti's fixed_map_seed for this world ([FIRST_RUN]: the driven
	-- first run types the seed it knows how to play)
	local seed_text = menu.window:CreateChild("Text")
	seed_text:SetStyleAuto()
	seed_text:SetText("seed (empty for a random one):")
	local seed_edit = menu.window:CreateChild("LineEdit")
	seed_edit:SetStyleAuto()
	seed_edit.minHeight = 26
	seed_edit.enabled = true
	seed_edit:SetText("")
	menu:add("Create and play", function()
		local name = edit:GetText()
		local seed = seed_edit:GetText()
		waiting("Creating " .. name .. "...")
		buildat.send_packet("main:create",
				cereal.binary_output({name, gameid, seed},
				{"array", "string"}))
	end)
	menu:add("< back", function()
		draw_new_game()
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
end

function draw_new_game()
	local menu = import_menu("New save: which game?")
	local items = {}
	for _, gameid in ipairs(games) do
		items[#items + 1] = {label = gameid, action = function()
			draw_new_save_name(gameid)
		end}
	end
	if #items == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("No games installed. Import one from Luanti first.")
	end
	local shown = filtered(items, game_filter)
	add_filter(menu, game_filter, #items, #shown, function(text)
		game_filter = text
		game_page = 1
		draw_new_game()
	end)
	ui_utils.add_paged(menu, shown, {
		page = game_page,
		per_page = 12,
		redraw = function(new_page)
			game_page = new_page
			draw_new_game()
		end,
	})
	back_to_saves(menu)
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
	local shown = filtered(items, import_filter)
	add_filter(menu, import_filter, #items, #shown, function(text)
		import_filter = text
		import_page = 1
		draw_import_games()
	end)
	ui_utils.add_paged(menu, shown, {
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
	magic.input:SetMouseVisible(true, "a menu screen")
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
	local shown = filtered(items, import_filter)
	add_filter(menu, import_filter, #items, #shown, function(text)
		import_filter = text
		import_page = 1
		draw_import_worlds()
	end)
	ui_utils.add_paged(menu, shown, {
		page = import_page,
		per_page = 12,
		redraw = function(new_page)
			import_page = new_page
			draw_import_worlds()
		end,
	})
	back_to_saves(menu)
end


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

buildat.sub_packet("main:contentdb_list", function(data)
	if done then
		return
	end
	draw_contentdb(cereal.binary_input(data, {"array", "string"}))
end)

buildat.sub_packet("main:settings", function(data)
	if done then
		return
	end
	local list = cereal.binary_input(data, {"array", "string"})
	-- The editor's own save comes back here: its rows, not a screen
	-- over it
	if keys_open then
		keys_editor.apply(list)
		return
	end
	draw_settings(list)
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
	log:verbose("menu: progress " .. line)
	if waiting_text then
		waiting_text:SetText(line)
	else
		waiting(line)
	end
end)

-- News, not an error: the list it changed is asked for again and the
-- line shown over it for a moment
buildat.sub_packet("main:menu_message", function(data)
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:info("menu: " .. tostring(message))
	buildat.send_packet("main:get_saves", "")
	ui_utils.show_notification(tostring(message), 4.0)
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
	log:info("menu: done; the world is up")
	done = true
	waiting_text = nil
	close()
end)

buildat.send_packet("main:get_saves", "")
waiting("Looking for saves...")
-- vim: set noet ts=4 sw=4:
