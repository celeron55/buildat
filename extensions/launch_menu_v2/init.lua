-- Buildat: extension/launch_menu_v2/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch menu organized by what a player does ([LAUNCH_MENU_V2]):
-- Home is a Continue list of what was last used, the ways in, and one
-- search over every source, results grouped by kind; Browse is one list
-- per kind with a detail panel beside it holding the thing's actions.
-- Beside launch_menu, which it replaces when the user says so. Runs in
-- the sandbox, as launch_menu does; the screens it does not draw itself
-- (the connecting screen, the Engine settings) are launch_menu's,
-- reached by verb.
--
-- Settings is one tree (Display and sound, Controls, Luanti, Developer),
-- and Controls edits the client's key store (client/api.lua's
-- declare_keys).
-- simplified: no pins and none of the actions that do not exist anywhere
-- yet (the plan's step 4, when someone asks for them).
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
local KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_TAB =
		magic.KEY_LEFT, magic.KEY_RIGHT, magic.KEY_UP, magic.KEY_DOWN,
		magic.KEY_TAB

local M = {safe = nil}

-- In a browser there are no local apps, saves, LAN or Quit: what cannot
-- work there is left out by this one check. "1" is an https page, which
-- reaches a server only through TLS.
local page = api.get_env("BUILDAT_PAGE_HTTPS")
local web = page ~= nil

local CONTINUE_MAX = 10
local SEARCH_MIN = 2
local SEARCH_CAP = 20
local ROW_HEIGHT = 28
local ICON_SIZE = 20
local PANEL_WIDTH = 300
local GAME_RUNNING = "empty (game is running)"

-- The kinds, in the order the results show them
local KINDS = {"app", "save", "server", "catalog", "action"}
local KIND_TITLE = {app = "Apps", save = "Saves", server = "Servers",
		catalog = "Get more", action = "Other"}
local PRIMARY = {app = "Play", save = "Continue", server = "Join",
		catalog = "Open", action = "Open"}
-- Launch actions that are a catalog to get more from, or a server's
-- address typed, rather than what their category says
local CATALOG_KEYS = {["extension/launch_menu/aitta"] = true,
		["app/vanilla/contentdb"] = true,
		["builtin/luanti/import_game"] = true,
		["builtin/luanti/import_world"] = true}
local SERVER_KEYS = {["extension/launch_menu/connect"] = "Buildat",
		["extension/luanti_client/connect"] = "Luanti",
		["extension/serverlist/refresh"] = "Luanti"}
-- And the settings screens that are tiles, which the Settings tree has
local SETTINGS_KEYS = {["app/vanilla/settings"] = true,
		["extension/luanti_client/settings"] = true}

-- How well an entry matches what is typed: 2 its label starts with it, 1
-- it is in the label or the badge, nil not at all
local function match(e, q)
	local at = e.label:lower():find(q, 1, true)
	if at == 1 then return 2 end
	if at or (e.badge or ""):lower():find(q, 1, true) then return 1 end
	return nil
end

-- The order of a list: "recent" is the player's own history first (most
-- recent), then the better match, then the label; "name" the label alone
local function sorted(list, by)
	table.sort(list, function(a, b)
		if by ~= "name" then
			local la, lb = a.e.last or 0, b.e.last or 0
			if la ~= lb then return la > lb end
			if a.m ~= b.m then return a.m > b.m end
		end
		return a.e.label:lower() < b.e.label:lower()
	end)
	local out = {}
	for _, x in ipairs(list) do out[#out + 1] = x.e end
	return out
end

-- The search: every entry that matches, grouped by kind in KINDS' order,
-- each group in `by`'s order. Pure, so the check below runs it.
local function search(entries, query, by)
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
		if by_kind[kind] then
			local group = sorted(by_kind[kind], by)
			group.kind = kind
			out[#out + 1] = group
		end
	end
	return out
end

-- Continue: what was used, the most recent first, at most n.
-- simplified: recency alone. The launch history keeps one line per key
-- (its last time), so frequency would need a count it does not have.
-- What has something new waiting (a Hearth's notifications) comes first
local function recent(entries, n)
	local used = {}
	for _, e in ipairs(entries) do
		if e.last or e.unseen then used[#used + 1] = e end
	end
	table.sort(used, function(a, b)
		if (a.unseen ~= nil) ~= (b.unseen ~= nil) then
			return a.unseen ~= nil
		end
		return (a.last or 0) > (b.last or 0)
	end)
	local out = {}
	for i = 1, math.min(n, #used) do out[i] = used[i] end
	return out
end

-- "3 h ago": when a thing was last used, for the panel
local function ago(t, now)
	local d = math.max(0, now - t)
	if d < 60 then return "just now" end
	if d < 3600 then return math.floor(d / 60) .. " min ago" end
	if d < 86400 then return math.floor(d / 3600) .. " h ago" end
	return math.floor(d / 86400) .. " days ago"
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
	r = search(es, "fl", "name")
	assert(r[1][1].label == "A floor mat", "search: by name")
	r = search(es, "planner")
	assert(#r == 2 and r[2][1].label == "flat", "search: badges match")
	assert(#search(es, "zz") == 0, "search: nothing")
	r = recent(es, 1)
	assert(#r == 1 and r[1].label == "flat", "recent: newest first")
	assert(ago(100, 100) == "just now" and ago(0, 7200) == "2 h ago" and
			ago(0, 3 * 86400) == "3 days ago", "ago")
end

-- **Notifications waiting** ([FORUM] 4): address -> count, from each
-- Buildat server this client keeps a login for (a Hearth answers),
-- asked at most once a minute
local unseen = {}
local unseen_asked = nil
-- Set when an app, save or server is run from here: a game's own way
-- out (luanti_client's leave) pops its screens without leave_app, so
-- Home comes back on top as drawn before it, and is drawn again then
local stale = false

-- Every source, as entries of one shape: {label, kind, badge,
-- description, last (unix s or nil), size, actions = {{label, run}}};
-- run is the first action's
local function gather()
	local entries = {}
	local function add(e)
		e.actions = e.actions or {}
		local run = e.run
		if e.kind ~= "action" then
			e.run = function() stale = true run() end
		end
		table.insert(e.actions, 1, {label = PRIMARY[e.kind], run = e.run})
		entries[#entries + 1] = e
		return e
	end
	local function warn_if(ok, why)
		if not ok then log:warning(tostring(why)) end
	end
	add({label = "Display and sound", kind = "action", badge = "Settings",
		icon = "launch_menu/res/icon_preferences.png",
		section = "Display and sound",
		description = "What every app honours: the window, the sound, " ..
				"the mouse, and which launch UI this is.",
		run = function() api.show_engine_settings() end})
	local console = require("buildat/extension/launch_console")
	console = console and (console.show and console or console.safe)
	if console and console.show then
		add({label = "Developer console", kind = "action",
			icon = "launch_menu/res/icon_console.png",
			badge = "Developer", section = "Developer",
			description = "A Lua console in the sandbox, with the API " ..
					"document beside it.",
			run = function() console.show(function() end) end})
	end
	-- The launch actions: apps, Luanti games, the server list, catalogs,
	-- tools. An app's other actions (vanilla's settings, an installed
	-- release's feedback) are its panel's as well as their own entries.
	local app_label = {vanilla = "Luanti"}
	local by_from = {}
	local actions = api.launch_actions()
	-- And an app's icon, for its saves: the first of its actions'
	local icon_of = {}
	for _, a in ipairs(actions) do
		local app = a.from:match("^app/(.+)$")
		if app and not app_label[app] then app_label[app] = a.label end
		icon_of[a.from] = icon_of[a.from] or a.icon
	end
	for _, a in ipairs(actions) do
		-- Locally started things need a local server, which a page has not
		if not (web and (a.kind ~= "extension" or
				a.key == "extension/launch_menu/local" or
				a.key == "extension/launch_menu/aitta")) and
				-- Its lists are this menu's Apps and Servers
				a.key ~= "extension/launch_menu/local" then
			local cat = a.category or "action"
			local kind = CATALOG_KEYS[a.key] and "catalog" or
					SERVER_KEYS[a.key] and "server" or
					SETTINGS_KEYS[a.key] and "action" or
					(cat == "app" or cat == "game") and "app" or
					cat == "server" and "server" or "action"
			local badge = SERVER_KEYS[a.key] or
					cat == "game" and "Luanti" or
					a.kind == "installed" and "Aitta" or
					cat == "server" and (a.from == "extension/serverlist" or
					a.from == "extension/luanti_client") and "Luanti" or nil
			local e = add({label = a.label, kind = kind,
				badge = SETTINGS_KEYS[a.key] and "Settings" or badge,
				section = SETTINGS_KEYS[a.key] and "Luanti", key = a.key,
				from = a.from, icon = a.icon,
				id = a.from .. "/" .. tostring(a.id),
				size = kind == "app" and a.kind ~= "builtin" and
						a.significance or nil,
				description = a.description, last = a.last_launched,
				run = function() warn_if(api.launch(a.key)) end})
			if kind == "app" then
				by_from[a.from] = by_from[a.from] or e
			else
				e.sibling_of = a.from
			end
		end
	end
	for _, e in ipairs(entries) do
		local app = e.sibling_of and by_from[e.sibling_of]
		if app then
			app.actions[#app.actions + 1] = {label = e.label, run = e.run}
		end
	end
	if not web then
		-- The saves straight into their world; when one was last played
		-- is when it was launched or its file written, the later
		for _, sv in ipairs(api.list_saves()) do
			local parent = app_label[sv.app] or sv.app
			local last = math.max(sv.last_launched or 0, sv.modified and
					math.floor(sv.modified / 1000000) or 0)
			add({label = sv.name, kind = "save", badge = parent,
				icon = icon_of["app/" .. sv.app],
				description = "Continue this save of " .. parent .. ".",
				last = last > 0 and last or nil,
				run = function()
					warn_if(api.launch_save(sv.app, sv.name))
				end})
		end
		-- simplified: the LAN as heard at boot; the list is not polled
		for _, s in ipairs(api.lan_servers()) do
			local address = s.host .. ":" .. s.port
			add({label = s.name ~= "" and s.name or address,
				kind = "server", badge = "Buildat, LAN",
				description = address .. "   " .. tostring(s.app) .. ", " ..
						tostring(s.players) .. " playing",
				run = function() api.join_server(address) end})
		end
	end
	-- The Buildat servers this client has joined, last joined first; a
	-- Luanti one (udp) is luanti_client's tile, which is used when this
	-- was, though its dialog rather than the tile was the way in
	local by_key = {}
	for _, e in ipairs(entries) do
		if e.key then by_key[e.key] = e end
	end
	local known = {}
	local net = require("buildat/extension/network")
	net = net.known_addresses and net or net.safe
	for _, a in ipairs(net.known_addresses()) do
		local host, port = a.uri:match("^%a+://(.-):(%d+)$")
		local tile = a.uri:sub(1, 6) == "udp://" and
				by_key["extension/luanti_client/s_" ..
					(host .. ":" .. tostring(port)):gsub("[^%w%.%-]", "_")]
		if tile and a.last_attempt > (tile.last or 0) then
			tile.last = a.last_attempt
		end
		if host and a.accepted and a.uri:sub(1, 6) == "tcp://" then
			local address = host .. ":" .. port
			known[address] = true
			add({label = a.name ~= "" and a.name or address,
				kind = "server", unseen = unseen[address],
				badge = unseen[address] and "Buildat, " .. unseen[address] ..
						" new" or "Buildat",
				description = address .. (a.description ~= "" and
						"   " .. a.description or ""),
				last = a.last_attempt > 0 and a.last_attempt or nil,
				run = function() api.join_server(address) end})
		end
	end
	-- And Starport's public list as last fetched (the connect screen
	-- fetches it again); on an https page only those behind TLS
	-- simplified: the kept list, not a fetch of this menu's own
	local starport = require("buildat/extension/starport")
	starport = starport and (starport.kept_rows and starport or
			starport.safe)
	for _, row in ipairs(starport and starport.kept_rows() or {}) do
		local address = tostring(row.address)
		if not known[address] and not (page == "1" and not row.tls) then
			add({label = tostring(row.name), kind = "server",
				badge = "Buildat, Starport",
				description = address .. "   " ..
						tostring(row.players or 0) .. " playing",
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

-- c: a colour's name, ui_utils.rgb's
local function text(parent, s, size, c)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t.text = s
	if size then t:SetFontSize(size) end
	if c then t.color = magic.Color(ui_utils.rgb(c)) end
	return t
end

-- A screen: a window on a stack root, a version line, and the line that
-- says what is typed. The caller adds the rest.
local function screen(desc, width, heading, query)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile",
			"launch_menu/res/main_style.xml")
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 8, magic.IntRect(16, 12, 16, 12))
	window:SetAlignment(HA_LEFT, VA_CENTER)
	window:SetFixedWidth(width)
	local version, hash = api.version()
	text(window, "Buildat " .. version .. " " .. hash, 11, "dim")
	text(window, query == "" and heading or "Search: " .. query .. "_", 20,
			query == "" and "dim" or "text")
	return root, window
end

-- A list of rows in a viewport that clips it and scrolls by the selection
local function list_view(parent, width, height)
	local viewport = parent:CreateChild("UIElement")
	viewport.clipChildren = true
	viewport.enabled = true
	-- **The layout is set in fit(), once the rows are in**: a vertical
	-- layout is redone for every child added, so 300 rows took 1.8 s
	-- where 50 took 30 ms ([SEARCH_CAP])
	local list = viewport:CreateChild("UIElement")
	list:SetFixedWidth(width)
	list.enabled = true
	local view = {viewport = viewport, list = list}
	function view:header(s)
		text(list, s, 13, "dim"):SetFixedHeight(ROW_HEIGHT - 4)
	end
	function view:row(e, badge)
		local b = list:CreateChild("Button")
		b:SetStyleAuto()
		b:SetName("Button")
		b:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(10, 2, 10, 2))
		b:SetFixedHeight(ROW_HEIGHT)
		-- The action's own icon, small enough to keep the row's height;
		-- an empty one where there is none, so that the labels line up
		local tex = e.icon and magic.cache:GetResource("Texture2D", e.icon)
		local icon = b:CreateChild(tex and "BorderImage" or "UIElement")
		icon:SetFixedSize(ICON_SIZE, ICON_SIZE)
		if tex then
			-- A game's own icon is pixel art
			tex.filterMode = magic.FILTER_NEAREST
			icon.texture = tex
			icon.blendMode = magic.BLEND_ALPHA
		end
		local label = text(b, e.label)
		label:SetName("ButtonText")
		label:SetFixedWidth(math.floor(width * 0.62))
		label:SetAlignment(HA_LEFT, VA_CENTER)
		text(b, badge or e.badge or "", 12, "dim"):SetAlignment(HA_LEFT,
				VA_CENTER)
		return b
	end
	function view:fit()
		list:SetLayout(LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
		viewport:SetFixedSize(width, math.max(ROW_HEIGHT,
				math.min(height, list.height)))
	end
	function view:show(button)
		local y = button.position.y
		local top = -list.position.y
		local h = viewport.height
		if y < top then
			list:SetPosition(0, -y)
		elseif y + ROW_HEIGHT > top + h then
			list:SetPosition(0, -(y + ROW_HEIGHT - h))
		end
	end
	return view
end

-- The keys a typed search takes: a character, Backspace, Escape to
-- clear. Answers the new query, or nil for a key that is not the search's.
local function search_key(key, query)
	local c = search_char(key)
	if c and magic.input:GetKeyPress(key) then
		return query .. c
	elseif key == KEY_BACKSPACE and query ~= "" then
		return query:sub(1, -2)
	elseif key == KEY_ESCAPE and query ~= "" then
		return ""
	end
	return nil
end

local browse, settings

local function home(query)
	local t0 = api.get_time_us()
	local width = math.min(magic.ui.root.width - 40, 760)
	local root, window = screen("launch_menu_v2", width,
			"Type to search apps, saves and servers", query)
	local view = list_view(window, width - 32,
			magic.ui.root.height - 24 - 160)
	local items = {}
	local function row(e, badge, run)
		items[#items + 1] = {button = view:row(e, badge), entry = e,
			action = function()
				log:info("launch_menu_v2: " .. e.kind .. " " .. e.label)
				run()
			end}
	end
	-- One character matches nearly everything, and drawing that many
	-- rows stalls each keypress: the search starts at two
	if #query < SEARCH_MIN then
		local cont = recent(entries, CONTINUE_MAX)
		if #cont > 0 then
			view:header("Continue")
			for _, e in ipairs(cont) do row(e, nil, e.run) end
		end
		-- The ways in: one list per kind
		view:header("Browse")
		for _, kind in ipairs({"app", "save", "server", "catalog"}) do
			local n = 0
			for _, e in ipairs(entries) do
				if e.kind == kind then n = n + 1 end
			end
			if n > 0 then
				row({label = KIND_TITLE[kind], kind = "browse",
					description = n .. " to choose from"}, tostring(n),
					function() browse(kind, "", "recent") end)
			end
		end
		view:header("Menu")
		row({label = "Settings", kind = "settings", description =
				"Display and sound, the keys, Luanti's, the developer's."},
				nil, function() settings() end)
	else
		-- At most SEARCH_CAP a kind, the best first; Browse has the rest
		for _, group in ipairs(search(entries, query)) do
			view:header(KIND_TITLE[group.kind] .. (#group > SEARCH_CAP and
					", " .. SEARCH_CAP .. " of " .. #group or ""))
			for i = 1, math.min(#group, SEARCH_CAP) do
				local e = group[i]
				row(e, nil, e.run)
			end
		end
		if #items == 0 then
			text(view.list, "Nothing matches \"" .. query ..
					"\" (Backspace, Escape)", nil, "dim")
		end
	end
	view:fit()

	-- The selection's description, under the list
	local desc = text(window, "", 13, "dim")
	desc:SetWordwrap(true)
	desc:SetFixedWidth(width - 32)
	desc:SetFixedHeight(40)

	local nav = ui_utils.bind_button_menu(root, items, function(key)
		local q = search_key(key, query)
		if q then
			uistack.main:pop(root)
			home(q)
			return true
		end
		if key == KEY_ESCAPE then
			-- On the web Escape on Home does nothing: the page is the
			-- launcher, and a browser tab has its own close
			if not web then
				ui_utils.show_confirm_dialog("Quit Buildat?",
						function() api.quit() end, nil, "Quit")
			end
			return true
		end
	end, {letters = false})
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if not (selected and item) then return end
		local e = item.entry
		desc.text = (e.badge and e.badge .. ": " or "") ..
				(e.description or "")
		view:show(button)
	end)
	log:info("launch_menu_v2: " .. #items .. " rows" ..
			(query ~= "" and " for \"" .. query .. "\"" or "") .. " in " ..
			math.floor((api.get_time_us() - t0) / 1000) .. " ms")
end

-- One kind's list, searchable and sorted, with the selection's detail
-- panel beside it: Enter or a double-click runs the primary action, Right
-- or Tab moves into the panel's actions, Left or Escape back. On a narrow
-- screen the panel is under the list.
-- simplified: one scrolled list rather than pages; hundreds of rows are
-- hundreds of buttons, which is fine at this size.
browse = function(kind, query, by)
	local narrow = magic.ui.root.width < 760
	local width = math.min(magic.ui.root.width - 40, 1000)
	local list_w = narrow and width - 32 or width - 32 - PANEL_WIDTH - 12
	local root, window = screen("launch_menu_v2 " .. kind, width,
			KIND_TITLE[kind] .. "   (type to search; Ctrl+S sorts by " ..
			(by == "name" and "recent use" or "name") .. ")", query)
	local body = window:CreateChild("UIElement")
	body:SetLayout(narrow and LM_VERTICAL or LM_HORIZONTAL, 12,
			magic.IntRect(0, 0, 0, 0))
	local room = magic.ui.root.height - 24 - 120 - (narrow and 200 or 0)
	local view = list_view(body, list_w, room)
	local panel = body:CreateChild("UIElement")
	panel:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	panel:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)
	-- A height that holds any entry's panel, so the window, which is
	-- centred, does not move the rows under the mouse as the panel changes
	-- simplified: a description longer than five lines still grows it
	panel.minHeight = math.min(room, 220)

	local of_kind = {}
	for _, e in ipairs(entries) do
		if e.kind == kind then of_kind[#of_kind + 1] = e end
	end
	local shown = search(of_kind, #query < SEARCH_MIN and "" or query,
			by)[1] or {}
	local items = {}
	local action_buttons = {}
	local current = nil
	-- **A clicked row is locked** (user, 2026-10-06): amber, and the
	-- panel is its while the mouse crosses other rows on the way to the
	-- panel's buttons. Another click locks another; an arrow key lets go,
	-- and the panel follows the selection again.
	local locked = nil
	local lock
	local last_click = {}
	for _, e in ipairs(shown) do
		local item = {entry = e}
		item.button = view:row(e)
		-- Enter runs it; a click locks it and a second one runs it
		item.action = function()
			local t = api.get_time_us()
			local enter = magic.input:GetKeyDown(magic.KEY_RETURN) or
					magic.input:GetKeyDown(magic.KEY_KP_ENTER)
			if enter or (last_click[e] and t - last_click[e] < 500000) then
				log:info("launch_menu_v2: " .. e.kind .. " " .. e.label)
				e.run()
			elseif not enter then
				lock(item)
			end
			last_click[e] = t
		end
		items[#items + 1] = item
	end
	if #items == 0 then
		text(view.list, query == "" and "Nothing here yet" or
				"Nothing matches \"" .. query .. "\" (Backspace, Escape)",
				nil, "dim")
	end
	view:fit()

	local now = os.time()
	local function fill(e)
		panel:RemoveAllChildren()
		action_buttons = {}
		text(panel, e.label, 18)
		text(panel, KIND_TITLE[kind] .. (e.badge and ", " .. e.badge or ""),
				12, "dim")
		if e.description and e.description ~= "" then
			local d = text(panel, e.description, 13, "dim")
			d:SetWordwrap(true)
			d:SetFixedWidth(narrow and width - 32 or PANEL_WIDTH)
		end
		if e.size then
			text(panel, string.format("Size: %.1f MB", e.size / 1048576),
					12, "dim")
		end
		text(panel, e.last and "Last used " .. ago(e.last, now) or
				"Not used yet", 12, "dim")
		for i, a in ipairs(e.actions) do
			local b = panel:CreateChild("Button")
			-- The first is the thing's own: Play, Continue, Join
			if i == 1 then b:SetStyle("PrimaryButton") else b:SetStyleAuto() end
			b:SetLayout(LM_VERTICAL, 0, magic.IntRect(10, 3, 10, 3))
			b:SetFixedHeight(ROW_HEIGHT)
			b:SetFocusMode(magic.FM_FOCUSABLE)
			local t = text(b, a.label)
			t:SetName("ButtonText")
			magic.SubscribeToEvent(b, "Released", function()
				log:info("launch_menu_v2: " .. a.label .. " on " .. e.label)
				a.run()
			end)
			action_buttons[#action_buttons + 1] = b
		end
	end
	-- The locked row's label in the main button's amber. Not the
	-- PrimaryButton style: a style brings a size of its own, and the rows
	-- then overlapped
	local function amber(item, on)
		local label = item.button:GetChild("ButtonText")
		if label then
			label.color = magic.Color(ui_utils.rgb(on and "main" or "text"))
		end
	end
	lock = function(item)
		if item == locked then return end
		if locked then amber(locked, false) end
		locked = item
		if item then amber(item, true) end
		log:info("launch_menu_v2: " .. (item and "locked " .. item.entry.label
				or "unlocked"))
		local subject = item or current
		if subject then fill(subject.entry) end
	end
	local function in_actions()
		for i, b in ipairs(action_buttons) do
			if b:HasFocus() then return i end
		end
		return nil
	end

	local nav = ui_utils.bind_button_menu(root, items, function(key)
		local i = in_actions()
		if i then
			-- In the panel: up and down between its actions, Left or
			-- Escape back to the row it is the panel of
			if key == KEY_UP or key == KEY_DOWN then
				local n = #action_buttons
				local j = (i - 1 + (key == KEY_DOWN and 1 or -1)) % n + 1
				action_buttons[j]:SetFocus(true)
				return true
			elseif key == KEY_LEFT or key == KEY_ESCAPE then
				local back = locked or current
				if back then back.button:SetFocus(true) end
				return true
			end
			return key == KEY_RIGHT or key == KEY_TAB
		end
		if (key == KEY_RIGHT or key == KEY_TAB) and action_buttons[1] then
			action_buttons[1]:SetFocus(true)
			return true
		end
		if key == KEY_LEFT then return true end
		if key == KEY_UP or key == KEY_DOWN or key == magic.KEY_PAGEUP or
				key == magic.KEY_PAGEDOWN then
			lock(nil)
		end
		if key == magic.KEY_S and
				magic.input:GetQualifierDown(magic.QUAL_CTRL) then
			uistack.main:pop(root)
			browse(kind, query, by == "name" and "recent" or "name")
			return true
		end
		local q = search_key(key, query)
		if q then
			uistack.main:pop(root)
			browse(kind, q, by)
			return true
		end
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end, {letters = false})
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if not (selected and item) or item == current then return end
		current = item
		if not locked then fill(item.entry) end
		view:show(button)
	end)
	log:info("launch_menu_v2: " .. kind .. ", " .. #items .. " rows" ..
			(query ~= "" and " for \"" .. query .. "\"" or "") ..
			", by " .. by)
end

-- **Settings**, one tree: each part once
local controls
settings = function()
	local width = math.min(magic.ui.root.width - 40, 760)
	local root, window = screen("launch_menu_v2 settings", width,
			"Settings", "")
	local view = list_view(window, width - 32, magic.ui.root.height - 200)
	local items = {}
	local function row(e, run)
		items[#items + 1] = {button = view:row(e), entry = e, action = run}
	end
	local by_section = {}
	for _, e in ipairs(entries) do
		if e.section then
			by_section[e.section] = by_section[e.section] or {}
			table.insert(by_section[e.section], e)
		end
	end
	for _, section in ipairs({"Display and sound", "Controls", "Luanti",
			"Developer"}) do
		if section == "Controls" then
			view:header(section)
			row({label = "Keys", description = "Every app's keys, the " ..
					"shared ones that bind them all at once, and the " ..
					"client's own."}, function() controls(1) end)
		elseif by_section[section] then
			view:header(section)
			for _, e in ipairs(by_section[section]) do row(e, e.run) end
		end
	end
	view:fit()
	local desc = text(window, "", 13, "dim")
	desc:SetWordwrap(true)
	desc:SetFixedWidth(width - 32)
	desc:SetFixedHeight(40)
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end, {letters = false})
	nav:on_change(function(button, selected, index)
		local item = index and items[index]
		if selected and item then
			desc.text = item.entry.description or ""
		end
	end)
end

-- **The keys** ([LAUNCH_MENU_V2] step 3): the client's own, the shared
-- names (most used first), and every app that declared its keys, each
-- action with its key and where that comes from. Enter on a row and then
-- a key binds it; Backspace on a row puts it back -- a shared name to
-- each app's own, an app's action to the shared or default key, a
-- client key to its default -- and Delete unbinds a client key (not the
-- overlay's, which the client refuses), giving it to the apps.
-- simplified: one list, not the plan's two tabs; a key the client keeps
-- cannot be captured here (no script hears it), so two client keys are
-- swapped through a free one.
local CLIENT_KEY_LABEL = {overlay = "Trusted overlay on and off",
	profiler = "The engine's profiler (Ctrl: physics geometry)",
	fullscreen = "Fullscreen on and off",
	screenshot = "A screenshot (Ctrl: the sandbox scan)"}
controls = function(focus)
	local store = api.key_store()
	local width = math.min(magic.ui.root.width - 40, 760)
	local root, window = screen("launch_menu_v2 keys", width,
			"Keys   (Enter and a key binds; Backspace resets)", "")
	local view = list_view(window, width - 32, magic.ui.root.height - 200)
	local rows = {}
	local function row(label, key, note, set, reset, unbind)
		rows[#rows + 1] = {button = view:row({label = label},
				(key or "-") .. (note and "   " .. note or "")),
			set = set, reset = reset, unbind = unbind, label = label}
	end
	view:header("This client's")
	for _, c in ipairs(store.client) do
		row(CLIENT_KEY_LABEL[c.which] or c.which, c.key ~= "" and c.key or nil,
				c.key ~= c.default and "(default " .. c.default .. ")" or nil,
				function(k) return api.set_client_key(c.which, k) end,
				function() return api.set_client_key(c.which, c.default) end,
				function() return api.set_client_key(c.which, nil) end)
	end
	-- The shared names, by how many apps use them
	local users = {}
	for _, a in ipairs(store.apps) do
		for _, e in ipairs(a.actions) do
			if e.shared then users[e.shared] = (users[e.shared] or 0) + 1 end
		end
	end
	local names = {}
	for i, n in ipairs(store.shared_names) do names[i] = n end
	table.sort(names, function(x, y)
		if (users[x] or 0) ~= (users[y] or 0) then
			return (users[x] or 0) > (users[y] or 0)
		end
		return x < y
	end)
	view:header("Shared, for every app that has not its own")
	for _, n in ipairs(names) do
		row(n, store.shared[n], store.shared[n] == nil and
				"each app's own, used by " .. (users[n] or 0) or
				"used by " .. (users[n] or 0),
				function(k) return api.set_shared_key(n, k) end,
				function() return api.set_shared_key(n, nil) end)
	end
	for _, a in ipairs(store.apps) do
		if #a.actions > 0 then
			view:header(a.label .. "   (" .. a.id .. ")")
			for _, e in ipairs(a.actions) do
				row(e.label, e.key, e.from == "shared" and "shared " ..
						e.shared or e.from == "app" and "this app's" or nil,
						function(k) return api.set_app_keys(a.id, {[e.id] = k}) end,
						function()
							return api.set_app_keys(a.id, {[e.id] = false})
						end)
			end
		end
	end
	view:fit()
	local line = text(window, "", 13, "dim")
	line:SetFixedHeight(20)
	local listening = nil
	-- The Enter that started a capture reaches the screen's handler after
	-- the button pressed itself on it; that one is not the key
	local enter_down = nil
	local selected = 1
	local function redraw()
		uistack.main:pop(root)
		controls(selected)
	end
	local items = {}
	for i, r in ipairs(rows) do
		items[i] = {button = r.button, action = function()
			listening = r
			enter_down = magic.input:GetKeyDown(magic.KEY_RETURN) and
					magic.KEY_RETURN or
					magic.input:GetKeyDown(magic.KEY_KP_ENTER) and
					magic.KEY_KP_ENTER or nil
			line.text = "Press a key for \"" .. r.label ..
					"\" (Escape leaves it)"
		end}
	end
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if listening and key == enter_down then
			enter_down = nil
			return true
		end
		if listening then
			local r = listening
			listening = nil
			if key ~= KEY_ESCAPE then
				local name = magic.input:GetKeyName(key)
				local ok, why = r.set(name)
				log:info("launch_menu_v2: " .. r.label .. " = " .. name ..
						(ok and "" or ": " .. tostring(why)))
				redraw()
			else
				line.text = ""
			end
			return true
		end
		local r = rows[selected]
		if key == KEY_BACKSPACE and r then
			r.reset()
			log:info("launch_menu_v2: " .. r.label .. " reset")
			redraw()
			return true
		end
		if key == magic.KEY_DELETE and r and r.unbind then
			local ok, why = r.unbind()
			log:info("launch_menu_v2: " .. r.label .. " unbound" ..
					(ok and "" or ": " .. tostring(why)))
			if ok then redraw() else line.text = tostring(why) end
			return true
		end
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end, {letters = false})
	nav:on_change(function(button, sel, index)
		if sel and index then
			selected = index
			view:show(button)
		end
	end)
	if rows[focus] then rows[focus].button:SetFocus(true) end
	log:info("launch_menu_v2: keys, " .. #rows .. " rows")
end

-- launch_action is -a's kind/name/id, run over Home as picking it would
function M.boot(launch_action)
	stale = false
	entries = gather()
	home("")
	local net = require("buildat/extension/network")
	net = net.unseen_counts and net or net.safe
	local t = os.time()
	if not web and net.unseen_counts and
			(unseen_asked == nil or t - unseen_asked >= 60) then
		unseen_asked = t
		net.unseen_counts(function(address, n)
			local was = unseen[address]
			unseen[address] = n > 0 and n or nil
			log:info("launch_menu_v2: " .. address .. " has " .. n .. " new")
			-- Home drawn again with the mark, if it is what is shown
			local top = uistack.main:top()
			if was ~= unseen[address] and top and
					top:GetName():find(": launch_menu_v2$") then
				M.refresh()
			end
		end)
	end
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

local function to_home()
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	M.boot()
end

-- Drawn again, as at boot: what it lists has changed under it
M.refresh = to_home

magic.SubscribeToEvent("Update", function()
	if not stale then return end
	local top = uistack.main:top()
	if top and top:GetName():find(": launch_menu_v2$") then
		log:info("launch_menu_v2: back on Home, drawn again")
		M.refresh()
	end
end)

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
