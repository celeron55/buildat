-- Buildat: extension/launch_menu_v2/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch menu organized by what a player does ([LAUNCH_MENU_V2]):
-- Home is a Continue list of what was last used and one search over every
-- source, results grouped by kind. Beside launch_menu, which it replaces
-- when the user says so. Runs in the sandbox, as launch_menu does; the
-- screens it does not draw itself (the connecting screen, the Engine
-- settings) are launch_menu's, reached by verb.
--
-- simplified: step 1 of the plan's four -- no per-kind lists or detail
-- panel yet (step 2), no settings tree or key store (step 3), no pins.
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu_v2")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe
local HA_LEFT, VA_CENTER, LM_VERTICAL, LM_HORIZONTAL =
		magic.HA_LEFT, magic.VA_CENTER, magic.LM_VERTICAL,
		magic.LM_HORIZONTAL
local KEY_ESCAPE, KEY_BACKSPACE = magic.KEY_ESCAPE, magic.KEY_BACKSPACE

local M = {safe = nil}

-- In a browser there are no local apps, saves, LAN or Quit: what cannot
-- work there is left out by this one check
local web = api.get_env("BUILDAT_PAGE_HTTPS") ~= nil

local CONTINUE_MAX = 10
local ROW_HEIGHT = 28
local GAME_RUNNING = "empty (game is running)"

-- The kinds, in the order the results show them
local KINDS = {"app", "save", "server", "action"}
local KIND_TITLE = {app = "Apps", save = "Saves", server = "Servers",
		action = "Other"}

-- How well an entry matches what is typed: 2 its label starts with it, 1
-- it is in the label or the badge, nil not at all
local function match(e, q)
	local at = e.label:lower():find(q, 1, true)
	if at == 1 then return 2 end
	if at or (e.badge or ""):lower():find(q, 1, true) then return 1 end
	return nil
end

-- The search: every entry that matches, grouped by kind in KINDS' order,
-- and within a kind the player's own history first (most recent), then
-- the better match, then the label. Pure, so the check below runs it.
local function search(entries, query)
	local q = query:lower()
	local by_kind = {}
	for _, e in ipairs(entries) do
		local m = match(e, q)
		if m then
			local list = by_kind[e.kind] or {}
			by_kind[e.kind] = list
			list[#list + 1] = {e = e, m = m}
		end
	end
	local out = {}
	for _, kind in ipairs(KINDS) do
		local list = by_kind[kind]
		if list then
			table.sort(list, function(a, b)
				local la, lb = a.e.last or 0, b.e.last or 0
				if la ~= lb then return la > lb end
				if a.m ~= b.m then return a.m > b.m end
				return a.e.label:lower() < b.e.label:lower()
			end)
			local group = {kind = kind}
			for _, x in ipairs(list) do group[#group + 1] = x.e end
			out[#out + 1] = group
		end
	end
	return out
end

-- Continue: what was used, the most recent first, at most n.
-- simplified: recency alone. The launch history keeps one line per key
-- (its last time), so frequency would need a count it does not have.
local function recent(entries, n)
	local used = {}
	for _, e in ipairs(entries) do
		if e.last then used[#used + 1] = e end
	end
	table.sort(used, function(a, b) return a.last > b.last end)
	local out = {}
	for i = 1, math.min(n, #used) do out[i] = used[i] end
	return out
end

do
	local es = {
		{label = "Floor planner", kind = "app", last = 5},
		{label = "Fleet", kind = "server", badge = "Luanti"},
		{label = "flat", kind = "save", badge = "Floor planner", last = 9},
		{label = "A floor mat", kind = "app"},
		{label = "Engine settings", kind = "action"},
	}
	local r = search(es, "FL")
	assert(#r == 3 and r[1].kind == "app" and r[2].kind == "save" and
			r[3].kind == "server", "search: grouped by kind, in order")
	assert(r[1][1].label == "Floor planner" and r[1][2].label ==
			"A floor mat", "search: used first, then the match")
	r = search(es, "planner")
	assert(#r == 2 and r[2][1].label == "flat", "search: badges match")
	assert(#search(es, "zz") == 0, "search: nothing")
	r = recent(es, 1)
	assert(#r == 1 and r[1].label == "flat", "recent: newest first")
end

-- Every source, as entries of one shape: {label, kind, badge,
-- description, last (unix s or nil), run}
local function gather()
	local entries = {}
	local function add(e) entries[#entries + 1] = e end
	add({label = "Engine settings", kind = "action", badge = "Settings",
		description = "What every app honours: the window, the sound, " ..
				"the mouse, and which launch UI this is.",
		run = function() api.show_engine_settings() end})
	local console = require("buildat/extension/launch_console")
	console = console and (console.show and console or console.safe)
	if console and console.show then
		add({label = "Developer console", kind = "action",
			badge = "Developer",
			description = "A Lua console in the sandbox, with the API " ..
					"document beside it.",
			run = function() console.show(function() end) end})
	end
	-- The launch actions: apps, Luanti games, the server list, tools
	local app_label = {vanilla = "Luanti"}
	for _, a in ipairs(api.launch_actions()) do
		local app = a.from:match("^app/(.+)$")
		if app and not app_label[app] then app_label[app] = a.label end
		-- Locally started things need a local server, which a page has not
		if not (web and (a.kind ~= "extension" or
				a.key == "extension/launch_menu/local" or
				a.key == "extension/launch_menu/aitta")) then
			local cat = a.category or "action"
			local kind = (cat == "app" or cat == "game") and "app" or
					cat == "server" and "server" or "action"
			local badge = cat == "game" and "Luanti" or
					a.kind == "installed" and "Aitta" or
					cat == "server" and a.from == "extension/serverlist" and
					"Luanti" or nil
			add({label = a.label, kind = kind, badge = badge, key = a.key,
				id = a.from .. "/" .. tostring(a.id),
				description = a.description, last = a.last_launched,
				run = function()
					local ok, why = api.launch(a.key)
					if not ok then log:warning(tostring(why)) end
				end})
		end
	end
	if not web then
		-- The saves straight into their world; when one was last played
		-- is when its file was written
		for _, sv in ipairs(api.list_saves()) do
			local parent = app_label[sv.app] or sv.app
			add({label = sv.name, kind = "save", badge = parent,
				description = "Continue this save of " .. parent .. ".",
				last = sv.modified and math.floor(sv.modified / 1000000),
				run = function()
					local ok, why = api.launch_save(sv.app, sv.name)
					if not ok then log:warning(tostring(why)) end
				end})
		end
		-- simplified: the LAN as heard at boot; the list is not polled
		for _, s in ipairs(api.lan_servers()) do
			local address = s.host .. ":" .. s.port
			add({label = s.name ~= "" and s.name or address,
				kind = "server", badge = "LAN",
				description = address .. "   " .. tostring(s.app) .. ", " ..
						tostring(s.players) .. " playing",
				run = function() api.join_server(address) end})
		end
	end
	-- The Buildat servers this client has joined, last joined first
	local net = require("buildat/extension/network")
	net = net.known_addresses and net or net.safe
	for _, a in ipairs(net.known_addresses()) do
		local host, port = a.uri:match("^%a+://(.-):(%d+)$")
		if host and a.accepted and a.uri:sub(1, 4) ~= "http" then
			local address = host .. ":" .. port
			add({label = a.name ~= "" and a.name or address,
				kind = "server", badge = "Buildat",
				description = address .. (a.description ~= "" and
						"   " .. a.description or ""),
				last = a.last_attempt > 0 and a.last_attempt or nil,
				run = function() api.join_server(address) end})
		end
	end
	return entries
end

-- The character a key types into the search, or nil: key codes are SDL's,
-- which are the lower case ASCII of what the key says
local function search_char(key)
	if (key >= 97 and key <= 122) or (key >= 48 and key <= 57) or
			key == 32 or key == 45 or key == 46 then
		return string.char(key)
	end
	return nil
end

local entries = nil

local function draw(query)
	local root = uistack.main:push({desc = "launch_menu_v2"})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"launch_menu/res/main_style.xml")
	local width = math.min(magic.ui.root.width - 40, 760)
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	window:SetAlignment(HA_LEFT, VA_CENTER)
	window:SetFixedWidth(width)

	local function text(parent, s, size, c)
		local t = parent:CreateChild("Text")
		t:SetStyleAuto()
		t.text = s
		if size then t:SetFontSize(size) end
		if c then t.color = magic.Color(c, c, c) end
		return t
	end
	local version, hash = api.version()
	text(window, "Buildat " .. version .. " " .. hash, 11, 0.6)
	text(window, query == "" and
			"Type to search apps, saves and servers" or
			"Search: " .. query .. "_", 20, query == "" and 0.6 or 0.9)

	-- The list, in a viewport that clips it and scrolls by the selection
	local room = magic.ui.root.height - 24 - 160
	local viewport = window:CreateChild("UIElement")
	viewport.clipChildren = true
	viewport.enabled = true
	local list = viewport:CreateChild("UIElement")
	list:SetLayout(LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	list:SetFixedWidth(width - 32)
	list.enabled = true

	local items = {}
	local function header(s)
		local t = text(list, s, 13, 0.6)
		t:SetFixedHeight(ROW_HEIGHT - 4)
	end
	local function row(e)
		local b = list:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName("Button")
		b:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(10, 2, 10, 2))
		b:SetFixedHeight(ROW_HEIGHT)
		local label = text(b, e.label)
		label:SetName("ButtonText")
		label:SetFixedWidth(math.floor((width - 32) * 0.65))
		label:SetAlignment(HA_LEFT, VA_CENTER)
		local badge = text(b, e.badge or "", 12, 0.55)
		badge:SetAlignment(HA_LEFT, VA_CENTER)
		items[#items + 1] = {button = b, entry = e, action = function()
			log:info("launch_menu_v2: " .. e.kind .. " " .. e.label)
			e.run()
		end}
	end

	if query == "" then
		local cont = recent(entries, CONTINUE_MAX)
		if #cont > 0 then
			header("Continue")
			for _, e in ipairs(cont) do row(e) end
		end
		header("Menu")
		for _, e in ipairs(entries) do
			if e.kind == "action" and (e.badge == "Settings" or
					e.badge == "Developer" or
					(e.key or ""):find("^extension/launch_menu/")) then
				row(e)
			end
		end
	else
		for _, group in ipairs(search(entries, query)) do
			header(KIND_TITLE[group.kind])
			for _, e in ipairs(group) do row(e) end
		end
		if #items == 0 then
			text(list, "Nothing matches \"" .. query ..
					"\" (Backspace, Escape)", nil, 0.7)
		end
	end
	viewport:SetFixedSize(width - 32, math.max(ROW_HEIGHT,
			math.min(room, list.height)))

	-- The selection's description, under the list
	local desc = text(window, "", 13, 0.7)
	desc:SetWordwrap(true)
	desc:SetFixedWidth(width - 32)
	desc:SetFixedHeight(40)

	local function research(q)
		uistack.main:pop(root)
		draw(q)
	end
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			if query ~= "" then
				research("")
			elseif not web then
				ui_utils.show_confirm_dialog("Quit Buildat?",
						function() api.quit() end, nil, "Quit")
			end
			-- On the web Escape on Home does nothing: the page is the
			-- launcher, and a browser tab has its own close
			return true
		end
		local c = search_char(key)
		if c and magic.input:GetKeyPress(key) then
			research(query .. c)
			return true
		elseif key == KEY_BACKSPACE and query ~= "" then
			research(query:sub(1, -2))
			return true
		end
	end, {letters = false})
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if not (selected and item) then return end
		local e = item.entry
		desc.text = (e.badge and e.badge .. ": " or "") ..
				(e.description or "")
		-- Scrolled so the selected row is in view
		local y = button.position.y
		local top = -list.position.y
		local h = viewport.height
		if y < top then
			list:SetPosition(0, -y)
		elseif y + ROW_HEIGHT > top + h then
			list:SetPosition(0, -(y + ROW_HEIGHT - h))
		end
	end)
	log:info("launch_menu_v2: " .. #items .. " rows" ..
			(query ~= "" and " for \"" .. query .. "\"" or ""))
end

-- launch_action is -a's kind/name/id, run over Home as picking it would
function M.boot(launch_action)
	entries = gather()
	draw("")
	local fell_back = api.launch_ui_fell_back and api.launch_ui_fell_back()
	if fell_back then
		ui_utils.show_message_dialog("The launch UI \"" .. fell_back ..
				"\" did not load, so this is the menu.\n\n" ..
				"The log has the error.")
	end
	if launch_action then
		launch_action = launch_action:gsub("^game/", "app/")
		for _, e in ipairs(entries) do
			if e.key == launch_action or e.id == launch_action then
				log:info("Launch action: " .. launch_action)
				e.run()
				return
			end
		end
		log:warning("Launch action " .. launch_action .. " is not here")
	end
end

-- What the client asks a launch UI for: see launch_menu/init.lua's own,
-- which these are
function M.app_loading(what)
	log:info("launch_menu_v2: the app is loading a " .. tostring(what))
end

function M.in_app()
	for _, e in ipairs(uistack.main.stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and name and name:find(GAME_RUNNING, 1, true) then
			return true
		end
	end
	return false
end

function M.show_dead_server(title, on_close)
	local path, tail = api.local_server_log_tail(20)
	ui_utils.show_message_dialog(title .. "\n\n" .. tail ..
			"\nThe full log is at " .. path, on_close)
end

local function home()
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	M.boot()
end

-- Drawn again, as at boot: what it lists has changed under it
M.refresh = home

function M.leave_app()
	if not M.in_app() and not api.local_server_running() then
		return false
	end
	-- The stack comes down before the sweep: the screens over Home are
	-- the app's own, and leave_to_menu takes their elements with it
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	api.leave_to_menu()
	magic.input:SetMouseVisible(true, "back to the launcher")
	M.boot()
	log:info("launch_menu_v2: back to Home")
	return true
end

return M
-- vim: set noet ts=4 sw=4:
