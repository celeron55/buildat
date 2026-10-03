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
-- Which screen the launch asked for, kept: the tile that opened the
-- settings or ContentDB is a submenu of the launcher ([MENU_CONTEXT]), so
-- that screen's back goes to the grid, not to a save list nobody asked
-- for. A launch for a game's worlds goes back through the world screen.
local launched_for = nil
-- A public server's ([VANILLA_PUBLIC] 5): "public", or "public_running"
-- when this is opened over the world running, from the pause menu
local public = nil
-- What the pause menu gets back as when this goes back to the world
local M = {back = nil}
buildat.sub_packet("main:menu", function(data)
	local game = data:match("^worlds:(.+)$")
	if data:match("^public") then
		public = data
	elseif game then
		menu_game = game
		menu_wanted = nil
	else
		menu_wanted = data
		launched_for = data
	end
end)
local import_page = 1

-- **A width that fits the screen** (user, 2026-09-30: a phone): what the
-- menu asks for, or the screen's width less a margin; a narrow screen
-- stacks the world list's two columns
local function fit(px)
	return math.min(px, magic.ui.root.width - 40)
end
local function narrow()
	return magic.ui.root.width < 1000
end

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
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
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
-- arrive, because TextChanged is not in client/extensions/urho3d/safe_events.lua
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
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
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

-- The save the world screen has selected, and the panel's texts, filled
-- by the main:save_info answer ([WORLD_LIST])
local selected_save = nil
local panel = nil

-- A menu button under any parent, registered with the menu's keyboard
-- walk: the same shape ui_utils' menu:add(label) makes on its own window
local function button_on(menu, parent, label, action, width)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetName("Button")
	b:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	-- A fixed height, not the column's share of what is left: a vertical
	-- layout stretches an unfixed child
	b:SetFixedHeight(28)
	if width then
		b:SetFixedWidth(width)
	end
	local t = b:CreateChild("Text")
	t:SetName("ButtonText")
	t:SetStyleAuto()
	t:SetText(label)
	t:SetTextAlignment(magic.HA_CENTER)
	menu:add(b, action)
	return b
end

-- The world screen in two columns: the saves on the left as a list that
-- scrolls, the selected one's glance, its two world.mt flags, Play and
-- Delete on the right. A row's click selects it and asks the server for
-- the glance; a second click (or Enter on it) plays.
-- simplified: a row shows the name and the game, not when it was last
-- played -- that is in the panel, read on select; official's Configure,
-- Host and Announce are not here.
function draw(saves, save_games)
	last_saves, last_save_games = saves, save_games
	close()
	root = uistack.main:push({desc = "vanilla menu: saves"})
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText(menu_game and (menu_game .. ": which world?") or
			"vanilla: which save?")

	local columns = menu.window:CreateChild("UIElement")
	columns:SetLayout(narrow() and magic.LM_VERTICAL or magic.LM_HORIZONTAL,
			16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(fit(520))
	local right = columns:CreateChild("UIElement")
	right:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(0, 0, 0, 0))
	right:SetFixedWidth(fit(420))

	-- Every save, newest first: the server sorts them by when each was
	-- last played
	local items = {}
	for i, name in ipairs(saves) do
		local gameid = save_games[i]
		-- No goto: the web client's Lua is 5.1
		if not menu_game or gameid == menu_game then
			local known = false
			for _, g in ipairs(games) do
				if g == gameid then
					known = true
				end
			end
			local label = menu_game and name or (name .. "   (" ..
					(gameid ~= "" and gameid or "game not recorded") .. ")")
			if gameid ~= "" and not known then
				-- Still listed: a save whose game is not installed is a
				-- save, and saying so is more use than hiding it
				label = label .. "  -- no such game"
			end
			items[#items + 1] = {label = label, name = name}
		end
	end
	local shown = filtered(items, save_filter)
	add_filter({window = left}, save_filter, #items, #shown, function(text)
		save_filter = text
		draw(saves, save_games)
	end)
	local list = left:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(520), narrow() and
			math.max(100, math.floor(magic.ui.root.height * 0.18)) or 520)
	if selected_save then
		local still = false
		for _, item in ipairs(shown) do
			if item.name == selected_save then
				still = true
			end
		end
		if not still then
			selected_save = nil
		end
	end
	local row_buttons = {}
	local function select(name)
		selected_save = name
		for n, b in pairs(row_buttons) do
			b.selected = (n == name)
		end
		buildat.send_packet("main:save_info",
				cereal.binary_output({name}, {"array", "string"}))
	end
	local function play(name)
		-- The menu is done choosing; a launch UI that paused something
		-- for it can carry on ([LAUNCH_API])
		buildat.launch_loading("world")
		waiting("Opening " .. name .. "...")
		buildat.send_packet("main:open",
				cereal.binary_output({name}, {"array", "string"}))
	end
	for _, item in ipairs(shown) do
		local row = list.contentElement:CreateChild("Button")
		row:SetStyleAuto()
		row:SetName("Button")
		row:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(8, 0, 8, 0))
		row:SetFixedWidth(fit(520) - 24)
		row.minHeight = 28
		local text = row:CreateChild("Text")
		text:SetName("ButtonText")
		text:SetStyleAuto()
		text:SetText(item.label)
		text:SetTextAlignment(magic.HA_LEFT)
		row_buttons[item.name] = row
		menu:add(row, function()
			if selected_save == item.name then
				play(item.name)
			else
				select(item.name)
			end
		end)
		list:AddItem(row)
	end
	if #shown == 0 then
		local none = left:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText(#items == 0 and "No saves yet" or "Nothing matches")
	end

	-- One button rather than one per game: which game is a choice, and it
	-- goes on the same screen as the name it is being given
	local under = {add = function(_, label, action)
		return button_on(menu, left, label, action, fit(520))
	end}
	under:add(menu_game and "New world..." or "New save...", function()
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
	if public then
		-- A game from ContentDB is on the server for everyone, where an
		-- import is from this computer's Luanti
		under:add("Get a game from ContentDB...", function()
			ask_contentdb("")
		end)
	else
		under:add("Import a game from Luanti...", function()
			ask_for_imports("games")
		end)
		under:add("Import a world from Luanti...", function()
			ask_for_imports("worlds")
		end)
	end
	if public == "public_running" then
		under:add("< back to the world", function()
			done = true
			close()
			if M.back then
				M.back()
			end
		end)
	else
		-- Back to the launcher's grid ([MENU_CONTEXT]); a client that came
		-- straight to this server leaves it instead
		under:add("< back to the launcher", function()
			buildat.leave()
		end)
	end

	-- The right column: the glance, the flags, Play and Delete
	panel = {lines = {}, flags = {}}
	local head = right:CreateChild("Text")
	head:SetStyleAuto()
	head:SetText(selected_save or (narrow() and "Pick a world above" or
			"Pick a world on the left"))
	panel.head = head
	-- On a narrow screen the glance is one line that wraps, so that the
	-- screen fits a phone's height
	for k = 1, narrow() and 1 or 7 do
		local line = right:CreateChild("Text")
		line:SetStyleAuto()
		line:SetText("")
		line:SetTextAlignment(magic.HA_LEFT)
		if narrow() then
			line:SetWordwrap(true)
			line:SetFixedWidth(fit(420))
		end
		panel.lines[k] = line
	end
	local function flag_row(key, label)
		local b = button_on(menu, right, "[ ] " .. label, function()
			if not selected_save or panel.flags[key] == nil then
				return
			end
			local f = panel.flags
			f[key] = not f[key]
			buildat.send_packet("main:set_world_flags",
					cereal.binary_output({selected_save,
					f.creative_mode and "true" or "false",
					f.enable_damage and "true" or "false"}, {"array", "string"}))
		end, fit(420))
		panel[key] = {button = b, label = label}
	end
	flag_row("creative_mode", "Creative mode")
	flag_row("enable_damage", "Enable damage")
	button_on(menu, right, "Play", function()
		if selected_save then
			play(selected_save)
		end
	end, fit(420))
	button_on(menu, right, "Delete...", function()
		local name = selected_save
		if not name then
			return
		end
		ui_utils.show_confirm_dialog("Move the world \"" .. name ..
				"\" to the trash?", function()
			selected_save = nil
			waiting("Moving " .. name .. " to the trash...")
			buildat.send_packet("main:delete",
					cereal.binary_output({name}, {"array", "string"}))
		end, function() end)
	end, fit(420))
	if selected_save then
		select(selected_save)
	end

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
-- format_bytes() in extensions/launch_menu/screens.lua, which this is the same
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
	-- Over the HUD and the hotbar (priority 10) when over the world
	root.priority = 100
	local menu = ui_utils.vertical_menu(root, {min_width = fit(420)})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText(title)
	return menu
end

local function back_to_saves(menu, screen)
	if screen and launched_for == screen then
		menu:add("< back to the launcher", function()
			buildat.leave()
		end)
	else
		menu:add("< back", function()
			draw(last_saves, last_save_games)
		end)
	end
	magic.input:SetMouseVisible(true, "a menu screen")
end

-- The launcher's settings ([LAUNCH_GRID]): the import search paths, a list
-- to add to and remove from, kept by the server in user/shared/vanilla/settings.json
-- and sent whole each way. The defaults (~/.luanti, ~/.minetest and the
-- variable) are the server's and not in the list.
function draw_settings(paths)
	local menu = import_menu("Luanti settings")
	-- The render mode rides in the list as "render_mode=<mode>", and the
	-- key bindings as "key.<action>=<name>" rows ([KEY_BINDINGS]), which
	-- keys.lua reads and the editor writes; both go back with the paths
	local mode = "pbr"
	local view_range = "120"
	local view_bobbing = "1"
	local shoulder = "0"
	local lod_detail = "full"
	local kept = {}
	local key_rows = {}
	for _, p in ipairs(paths) do
		local m = p:match("^render_mode=(.*)$")
		local r = p:match("^view_range=(%d+)$")
		local b = p:match("^view_bobbing_amount=([%d.]+)$")
		local sh = p:match("^third_person_shoulder=([01])$")
		local ld = p:match("^lod_detail=(%a+)$")
		if sh then
			shoulder = sh
		elseif ld then
			lod_detail = ld
		elseif m then
			mode = m
		elseif r then
			view_range = r
		elseif b then
			view_bobbing = b
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
		list[#list + 1] = "lod_detail=" .. lod_detail
		list[#list + 1] = "view_bobbing_amount=" .. view_bobbing
		list[#list + 1] = "third_person_shoulder=" .. shoulder
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
		all[#all + 1] = "lod_detail=" .. lod_detail
		all[#all + 1] = "view_bobbing_amount=" .. view_bobbing
		all[#all + 1] = "third_person_shoulder=" .. shoulder
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
	-- How far full detail reaches, as a share of the range above
	-- ([CLIENT_FRAME]): past it a chunk is meshed from a downsampled
	-- volume -- a quarter of the triangles at the first step, and a
	-- coarser silhouette in the distance. It is the setting for a machine
	-- whose GPU is slower than its processor, which is most laptops: on
	-- this desk's Intel a made VoxeLibre world reads 30 fps at full and
	-- 55 at half, and on its Nvidia the same change is worth almost
	-- nothing. Full is the default, so nobody pays for the distance who
	-- is not short of GPU.
	local lod_text = menu.window:CreateChild("Text")
	lod_text:SetStyleAuto()
	lod_text:SetText("Distant terrain detail (less is faster):")
	for _, d in ipairs({{"full", "Full"}, {"half", "Reduced past half range"},
			{"third", "Reduced past a third"}}) do
		menu:add((d[1] == lod_detail and "[x] " or "[ ] ") .. d[2], function()
			lod_detail = d[1]
			local list = {}
			for _, p in ipairs(paths) do
				list[#list + 1] = p
			end
			send(list)
		end)
	end
	-- View bobbing ([VIEW_BOB]): official's view_bobbing_amount, 1 or off
	-- simplified: on or off; the amount when somebody wants 0.5
	menu:add((view_bobbing ~= "0" and "[x] " or "[ ] ") .. "View bobbing",
			function()
		view_bobbing = view_bobbing ~= "0" and "0" or "1"
		local list = {}
		for _, p in ipairs(paths) do
			list[#list + 1] = p
		end
		send(list)
	end)
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
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
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
	back_to_saves(menu, "settings")
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

-- The pictures the rows wait for, by client file name; the server names
-- each as it lands and the row asks the cache until it is there
local pictures = {}

function draw_contentdb(flat)
	local menu = import_menu("ContentDB: games" ..
			(contentdb_query ~= "" and (" matching \"" .. contentdb_query .. "\"") or ""))
	if public then
		-- [VANILLA_PUBLIC] 7: a game's mods are Lua that runs on the server
		local warn = menu.window:CreateChild("Text")
		warn:SetStyleAuto()
		warn:SetText("A game's mods run on this server: " ..
				"install only games you trust.")
		warn:SetColor(magic.Color(1.0, 0.8, 0.4))
	end
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(contentdb_query)
	menu:add("Search", function()
		ask_contentdb((edit:GetText():gsub("^%s+", ""):gsub("%s+$", "")))
	end)
	-- A row a game in a list that scrolls ([CONTENTDB_LIST]): the picture,
	-- the title and author over the description, left-aligned and
	-- wrapped, and Install at the right. The Install buttons are the
	-- menu's own, so the arrows and Enter walk them; the wheel scrolls.
	-- simplified: the arrows do not scroll the list to the selected row.
	local list = menu.window:CreateChild("ListView")
	list:SetStyleAuto()
	list:SetFixedSize(fit(860), math.min(620,
			math.floor(magic.ui.root.height * 0.6)))
	-- A phone's row has no room for the picture
	local row_w = fit(860) - 40
	local with_pic = row_w >= 600
	pictures = {}
	local n = 0
	for i = 1, #flat - 4, 5 do
		local author, name, title, desc = flat[i], flat[i + 1], flat[i + 2], flat[i + 3]
		n = n + 1
		local row = list.contentElement:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 10, magic.IntRect(4, 4, 4, 4))
		row:SetFixedWidth(row_w)
		if with_pic then
			local pic = row:CreateChild("Sprite")
			pic:SetFixedSize(96, 64)
			pic.color = magic.Color(0.3, 0.3, 0.3)
			pictures["contentdb/" .. author .. "_" .. name .. ".png"] = pic
		end
		local block_w = row_w - (with_pic and 106 or 0) - 120
		local block = row:CreateChild("UIElement")
		block:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
		block:SetFixedWidth(block_w)
		local head = block:CreateChild("Text")
		head:SetStyleAuto()
		head:SetText(title .. "  by " .. author)
		head:SetTextAlignment(magic.HA_LEFT)
		if desc ~= "" then
			local body = block:CreateChild("Text")
			body:SetStyleAuto()
			body:SetFixedWidth(block_w)
			body:SetWordwrap(true)
			body:SetText(desc)
			body:SetTextAlignment(magic.HA_LEFT)
		end
		-- In a cell of its own: the row's layout stretches a child to the
		-- picture's 64, and a button that tall draws its word at its top;
		-- the cell is stretched instead and the button sits in its middle
		local cell = row:CreateChild("UIElement")
		cell:SetFixedWidth(100)
		local button = cell:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		button:SetFixedSize(100, 28)
		button:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
		local label = button:CreateChild("Text")
		label:SetName("ButtonText")
		label:SetStyleAuto()
		label:SetText("Install")
		label:SetTextAlignment(magic.HA_CENTER)
		menu:add(button, function()
			waiting("Fetching " .. name .. "...")
			buildat.send_packet("main:contentdb_install",
					cereal.binary_output({author, name}, {"array", "string"}))
		end)
		list:AddItem(row)
	end
	if n == 0 then
		local none = menu.window:CreateChild("Text")
		none:SetStyleAuto()
		none:SetText("Nothing found")
	end
	-- The pictures as they land: the file is announced before it has
	-- crossed, so a name is asked for each frame until the cache has it
	local pending = {}
	local pending_n = 0
	root:SubscribeToStackEvent("Update", function()
		if pending_n == 0 then
			return
		end
		for file, pic in pairs(pending) do
			local tex = magic.cache:GetResource("Texture2D", file)
			if tex then
				pic:SetTexture(tex)
				pic.color = magic.Color(1, 1, 1)
				pending[file] = nil
				pending_n = pending_n - 1
			end
		end
	end)
	pictures.__add = function(file)
		local pic = pictures[file]
		if pic and not pending[file] then
			pending[file] = pic
			pending_n = pending_n + 1
		end
	end
	back_to_saves(menu, "contentdb")
end

buildat.sub_packet("main:contentdb_picture", function(data)
	local file = cereal.binary_input(data, {"array", "string"})[1]
	if file and pictures.__add then
		pictures.__add(file)
	end
end)

-- A new save, in the two steps importing a world already takes: which game,
-- and then what to call it. The name field is on the second screen with the
-- game it is for, rather than above a column of one button per game.
-- The mapgens Luanti ships, official's default first ([NEW_WORLD_FORM]):
-- what the world is made of is a choice made once, when it is made, and a
-- world made with the wrong one is a world made again.
--
-- simplified: a constant rather than core.get_mapgen_names(), which is the
-- engine's answer and there is no engine running while the menu is up. The
-- upgrade path is the luanti module answering a main:get_mapgens packet.
local MAPGENS = {"v7", "v5", "valleys", "carpathian", "flat", "fractal",
		"v6", "singlenode"}
-- What each game offers of them, the server's reading of its game.conf
-- and minetest.conf, the one to pick first ([GAME_CONF_MAPGENS])
local game_mapgens = {}
buildat.sub_packet("main:game_mapgens", function(data)
	local values = cereal.binary_input(data, {"array", "string"})
	game_mapgens = {}
	for i = 1, #values - 1, 2 do
		local list = {}
		for name in values[i + 1]:gmatch("[^,]+") do
			list[#list + 1] = name
		end
		game_mapgens[values[i]] = list
	end
end)

-- What the screen was holding when a create failed, so that a name already
-- taken does not throw the rest away ([NEW_WORLD_FORM]); nil when no create
-- is outstanding
local creating = nil

function draw_new_save_name(gameid, state)
	state = state or {}
	local menu = import_menu("New save, playing " .. gameid)
	-- Why the last create did not happen, on the screen rather than in a
	-- dialog: a dialog closes the screen and the name, the seed and the
	-- toggles go with it
	if state.error then
		local why = menu.window:CreateChild("Text")
		why:SetStyleAuto()
		why:SetText(state.error)
		why.color = magic.Color(1, 0.5, 0.5)
	end
	local text = menu.window:CreateChild("Text")
	text:SetStyleAuto()
	text:SetText("named:")
	local edit = menu.window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 26
	edit.enabled = true
	edit:SetText(state.name or "world")
	-- The seed, beside the name: empty is a random one; a number is
	-- Luanti's fixed_map_seed for this world ([FIRST_RUN]: the driven
	-- first run types the seed it knows how to play)
	local seed_text = menu.window:CreateChild("Text")
	seed_text:SetStyleAuto()
	seed_text:SetText("seed (empty for a random one):")
	local seed_edit = menu.window:CreateChild("LineEdit")
	seed_edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	seed_edit.textCopyable = true
	seed_edit.textSelectable = true
	seed_edit.minHeight = 26
	seed_edit.enabled = true
	seed_edit:SetText(state.seed or "")
	-- The new world's two world.mt flags, official's defaults
	-- ([WORLD_LIST]); the buttons say their state
	local flags = state.flags or
			{creative_mode = false, enable_damage = true}
	for _, f in ipairs({{"creative_mode", "Creative mode"},
			{"enable_damage", "Enable damage"}}) do
		local b
		b = menu:add((flags[f[1]] and "[x] " or "[ ] ") .. f[2], function()
			flags[f[1]] = not flags[f[1]]
			b:GetChild("ButtonText"):SetText((flags[f[1]] and "[x] " or "[ ] ") .. f[2])
		end)
	end
	-- Which mapgen, one button each with the picked one marked: the same
	-- shape as the flags above, and the sandbox has no dropdown
	local offered = game_mapgens[gameid] or MAPGENS
	if #offered == 0 then
		offered = MAPGENS
	end
	local mapgen = state.mapgen or offered[1]
	local mapgen_buttons = {}
	for _, name in ipairs(offered) do
		local b
		b = menu:add((mapgen == name and "[x] " or "[ ] ") .. "mapgen " ..
				name, function()
			mapgen = name
			for other, ob in pairs(mapgen_buttons) do
				ob:GetChild("ButtonText"):SetText(
						(mapgen == other and "[x] " or "[ ] ") ..
						"mapgen " .. other)
			end
		end)
		mapgen_buttons[name] = b
	end
	-- Over a running world a new one is only made ([VANILLA_PUBLIC] 5)
	menu:add(public == "public_running" and "Create" or "Create and play",
			function()
		local name = edit:GetText()
		local seed = seed_edit:GetText()
		-- Kept, so that a create the server refuses comes back to this
		-- screen with what was typed still in it
		creating = {gameid = gameid, name = name, seed = seed,
				mapgen = mapgen, flags = flags}
		buildat.launch_loading("world")
		waiting("Creating " .. name .. "...")
		buildat.send_packet("main:create",
				cereal.binary_output({name, gameid, seed,
				flags.creative_mode and "true" or "false",
				flags.enable_damage and "true" or "false", mapgen},
				{"array", "string"}))
	end)
	menu:add("< back", function()
		draw_new_game()
	end)
	magic.input:SetMouseVisible(true, "a menu screen")
	-- The focus in the name, which is the field an error is usually about
	magic.ui:SetFocusElement(edit)
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
	back_to_saves(menu, "import_game")
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
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
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
	back_to_saves(menu, "import_world")
end


-- The selected save's glance, into the panel; the flags' buttons say
-- their state
buildat.sub_packet("main:save_info", function(data)
	if done or not panel then
		return
	end
	local values = cereal.binary_input(data, {"array", "string"})
	local info = {}
	for i = 1, #values - 1, 2 do
		info[values[i]] = values[i + 1]
	end
	if info.name ~= selected_save then
		return
	end
	panel.head:SetText(info.name .. (info.title and info.title ~= "" and
			("  --  " .. info.title) or ""))
	local lines = {}
	if info.mapgen and info.mapgen ~= "" or info.seed and info.seed ~= "" then
		lines[#lines + 1] = "mapgen " .. (info.mapgen ~= "" and info.mapgen or "?") ..
				", seed " .. (info.seed or "?")
	end
	if info.day then
		lines[#lines + 1] = "day " .. info.day .. ", " .. (info.time or "") ..
				"; " .. (info.played or "?") .. " played"
	end
	if info.created_at then
		lines[#lines + 1] = "created " .. info.created_at
	end
	if info.played_at then
		lines[#lines + 1] = "last played " .. info.played_at
	end
	local sections = tonumber(info.sections) or 0
	lines[#lines + 1] = "explored: " .. sections .. " sections, " ..
			math.floor(math.sqrt(sections) * 64 + 0.5) .. " nodes across"
	lines[#lines + 1] = format_bytes(tonumber(info.bytes) or 0) .. " on disk"
	if #panel.lines == 1 then
		panel.lines[1]:SetText(table.concat(lines, "; "))
	else
		for k, line in ipairs(panel.lines) do
			line:SetText(lines[k] or "")
		end
	end
	panel.flags.creative_mode = info.creative_mode == "true"
	panel.flags.enable_damage = info.enable_damage == "true"
	for _, key in ipairs({"creative_mode", "enable_damage"}) do
		local b = panel[key]
		b.button:GetChild("ButtonText"):SetText((panel.flags[key] and "[x] " or
				"[ ] ") .. b.label)
	end
end)

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
	if done then
		return
	end
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:info("menu: " .. tostring(message))
	buildat.send_packet("main:get_saves", "")
	ui_utils.show_notification(tostring(message), 4.0)
end)

buildat.sub_packet("main:menu_error", function(data)
	if done then
		return
	end
	local message = cereal.binary_input(data, {"array", "string"})[1]
	log:warning("menu: " .. tostring(message))
	-- A create that did not happen goes back to the screen it came from
	-- with the name, the seed, the toggles and the mapgen still in it
	-- ([NEW_WORLD_FORM]): a dialog here would close the screen and throw
	-- all of it away
	if creating then
		local state = creating
		creating = nil
		state.error = tostring(message)
		draw_new_save_name(state.gameid, state)
		return
	end
	-- The list is asked for again once the dialog is gone, not while it is
	-- up: the dialog is on top of the menu in the UI stack, and drawing the
	-- menu again takes the menu's own root out from under it
	ui_utils.show_message_dialog(tostring(message), function()
		buildat.send_packet("main:get_saves", "")
	end)
end)

-- The world is up and main/init.lua is what draws from here on
buildat.sub_packet("main:menu_done", function()
	creating = nil
	log:info("menu: done; the world is up")
	done = true
	waiting_text = nil
	close()
end)

buildat.send_packet("main:get_saves", "")
waiting("Looking for saves...")
return M
-- vim: set noet ts=4 sw=4:
