-- Buildat: extension/launch_menu/screens.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The screens a game is started through: the local game list, connecting
-- to a server, a local server stopping and starting, and one that died.
-- Every launch UI's game starts end here -- client/launch_grid.lua runs
-- this file for a tile's or a save's launch -- so it runs in the sandbox
-- and reaches the server through the safe API's verbs only. It keeps no
-- state: whether a game runs is the stack's placeholder, so any number
-- of copies of this file agree.
local api = buildat.safe or buildat
local log = buildat.Logger("extension/launch_menu/screens")
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe
local network = require("buildat/extension/network")
network = network.safe or network
local starport = require("buildat/extension/starport")
starport = starport.safe or starport
local HA_CENTER, HA_LEFT, HA_RIGHT, KEY_ESCAPE, LM_HORIZONTAL, LM_VERTICAL, VA_CENTER =
		magic.HA_CENTER, magic.HA_LEFT, magic.HA_RIGHT, magic.KEY_ESCAPE, magic.LM_HORIZONTAL, magic.LM_VERTICAL, magic.VA_CENTER
local STYLE = "launch_menu/res/main_style.xml"
-- The stack's placeholder while a game runs; uistack's scan stands aside
-- for a top of this name
local GAME_RUNNING = "empty (game is running)"
local M = {}

local function show_error(message)
	ui_utils.show_message_dialog(message)
end

local function format_bytes(n)
	n = math.floor(tonumber(n) or 0)
	if n < 1024 then
		return n.." B"
	end
	local kb = n / 1024
	if kb < 1024 then
		if kb < 10 then
			return string.format("%.1f KB", kb)
		end
		return math.floor(kb + 0.5).." KB"
	end
	local mb = kb / 1024
	if mb < 10 then
		return string.format("%.1f MB", mb)
	end
	return math.floor(mb + 0.5).." MB"
end

local MENU_BUTTON_WIDTH = 200

local function make_button(parent, label, main)
	local button = parent:CreateChild("Button")
	if main then button:SetStyle("PrimaryButton") else button:SetStyleAuto() end
	button:SetName("Button")
	button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
	button.minHeight = 24
	button.minWidth = MENU_BUTTON_WIDTH
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = label
	text:SetTextAlignment(HA_CENTER)
	return button
end

-- Name + size as separate texts so the size can be smaller and duller
local function make_game_button(parent, name, size)
	local button = parent:CreateChild("Button")
	button:SetStyleAuto()
	button:SetName("Button")
	button:SetLayout(LM_HORIZONTAL, 8, magic.IntRect(12, 2, 12, 2))
	button.minHeight = 24
	button.minWidth = MENU_BUTTON_WIDTH
	local text = button:CreateChild("Text")
	text:SetName("ButtonText")
	text:SetStyleAuto()
	text.text = name
	if text.width > 0 then
		-- So the size beside it does not squeeze the name: a function
		-- because the fixedWidth property has no setter in the bindings
		text:SetFixedWidth(text.width)
	end
	local size_text = button:CreateChild("Text")
	size_text:SetStyleAuto()
	size_text.text = format_bytes(size)
	size_text:SetFontSize(12)
	size_text.color = magic.Color(ui_utils.rgb("dim"))
	size_text:SetTextAlignment(HA_RIGHT)
	return button
end

local function make_labeled_edit(parent, label, value, width)
	local text = parent:CreateChild("Text")
	text:SetStyleAuto()
	text.text = label
	local edit = parent:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	-- Fixed, not min: a column beside a tall list would stretch it
	edit:SetFixedHeight(26)
	edit.minWidth = width or 300
	edit:SetText(value)
	return edit
end

-- A screen of one window with a line of text in it
local function push_status_screen(desc, text)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)
	local status = window:CreateChild("Text")
	status:SetStyleAuto()
	status.text = text
	return root, window, status
end

-- Whether a game runs under the launcher's screens ([MENU_ERRORS] reads
-- it: a dialog before a join, a notice line in a game)
function M.in_app()
	for _, e in ipairs(uistack.main.stack) do
		local ok, name = pcall(function() return e:GetName() end)
		if ok and name and name:find(GAME_RUNNING, 1, true) then
			return true
		end
	end
	return false
end

-- A local server that died: the last lines of its log and where the
-- whole of it is, so a crash's backtrace is on the screen and not just
-- gone ([START_PROGRESS]). on_close runs when the dialog is closed.
function M.show_dead_server(title, on_close)
	local path, tail = api.local_server_log_tail(20)
	ui_utils.show_message_dialog(title.."\n\n"..tail..
			"\nThe full log is at "..path, on_close)
end

-- The connect runs on a worker and this screen polls it
-- ([BOX_PLAYTEST_2] 12): a blocking connect froze the frame
-- `fallbacks`: the addresses to try next when this one fails, a pool's
-- other servers ([STARPORT] 2b)
local function connect_or_show_error(address, fallbacks)
	local ok, why = api.connect_start(address)
	if not ok then
		show_error(why)
		return
	end
	local root, _, status = push_status_screen("connecting",
			"Connecting to "..address.."...")
	local t0 = api.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		local state, err = api.connect_poll()
		if state == "pending" then
			-- The seconds, so that the screen says it is still going
			status.text = "Connecting to "..address.."...  "..
					math.floor((api.get_time_us() - t0) / 1000000).." s"
			return
		end
		done = true
		uistack.main:pop(root)
		if state == "ok" then
			log:info("connect_server() ok")
			-- **The placeholder goes on the stack whichever launcher
			-- this is** ([MENU_LEAVE]): the launcher's screens are not
			-- drawn through the world, and the scan a driven run reads
			-- stands aside only for a top named "game is running". A
			-- launcher leaving a game pops the whole stack.
			uistack.main:push({desc = GAME_RUNNING, tap_outside = false})
			magic.ui:SetFocusElement(nil)
		elseif fallbacks and #fallbacks > 0 then
			log:info("connect_server() failed; the pool's next server")
			local rest = {}
			for i = 2, #fallbacks do
				rest[#rest + 1] = fallbacks[i]
			end
			connect_or_show_error(fallbacks[1], rest)
		else
			log:info("connect_server() failed")
			show_error(err)
		end
	end)
end

-- A connect asked for by the launch grid ("Feedback..." on an app)
function M.connect(address)
	api.stop_local_server()
	connect_or_show_error(address)
end

function M.show_connect_to_server()
	api.stop_local_server()
	local root = uistack.main:push({desc="connect_to_server"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)

	local outer = root:CreateChild("Window")
	outer:SetStyleAuto()
	outer:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	outer:SetAlignment(HA_LEFT, VA_CENTER)

	-- Two columns ([SERVER_LIST]): the addresses this client has used on
	-- the left (the network extension's file), the fields on the right; a
	-- pick fills them, a second pick connects
	local columns = outer:CreateChild("UIElement")
	columns:SetLayout(LM_HORIZONTAL, 16, magic.IntRect(0, 0, 0, 0))
	local left = columns:CreateChild("UIElement")
	left:SetLayout(LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	left:SetFixedWidth(440)
	local window = columns:CreateChild("UIElement")
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))

	-- A typed address, and the servers used, unless the Starport lock
	-- says the list is the only way in ([STARPORT] 4)
	local direct = starport.direct_connect_allowed()
	local address_edit, port_edit
	if direct then
		address_edit = make_labeled_edit(window, "Address", "localhost")
		port_edit = make_labeled_edit(window, "Port (optional)", "29500")
		address_edit:SetFocus(true)
	end
	local do_connect
	local picked = nil
	-- The fleet open, or nil for the top ([STARPORT] 2b); the public list's
	-- drawing, which a fleet's row opens
	local open_fleet, show_public = nil, nil
	local function pick(row, second)
		if row.back or row.fleet_id then
			open_fleet = row.fleet_id
			picked = row.fleet_id and row or nil
			show_public()
			return
		end
		picked = row
		if direct then
			address_edit:SetText(row.host)
			port_edit:SetText(row.port)
		end
		if second and not row.native_only then
			do_connect()
		end
	end

	-- [PLAY_PAGE] (b): an https page reaches a server by a secure
	-- WebSocket only, so one with no TLS in front is the native client's
	local web_tls_only = buildat.get_env("BUILDAT_PAGE_HTTPS") == "1"

	-- **Public servers** from the Starports in the settings, merged and
	-- filtered by the extension; a search narrows what came
	local sp_title = left:CreateChild("Text")
	sp_title:SetStyleAuto()
	sp_title.text = "Public servers: asking the Starports..."
	-- A Starport's error is long; it wraps in the column, not widens it
	sp_title:SetWordwrap(true)
	sp_title:SetFixedWidth(440)
	local search = left:CreateChild("LineEdit")
	search:SetStyleAuto()
	search.minHeight = 24
	search.textCopyable = true
	search.textSelectable = true
	local sp_list = ui_utils.server_list(left, {width = 440,
			height = direct and 170 or 440}, pick)
	local sp_rows = {}
	local function categories(x)
		local d = {}
		for k, v in pairs(x.descriptors or {}) do
			if v ~= "no" and v ~= "none" then
				d[#d + 1] = k .. " " .. tostring(v)
			end
		end
		table.sort(d)
		return tostring(x.kind) .. ", " .. tostring(x.audience) .. ", " ..
				tostring(x.access) ..
				(#d > 0 and " (" .. table.concat(d, ", ") .. ")" or "")
	end
	show_public = function()
		local q = search:GetText():lower()
		local shown = {}
		for _, x in ipairs(sp_rows) do
			local f = type(x.fleet) == "table" and x.fleet or {}
			local hay = (tostring(x.name) .. " " .. tostring(x.description) ..
					" " .. table.concat(x.tags or {}, " ") .. " " ..
					tostring(f.name or "")):lower()
			if q == "" or hay:find(q, 1, true) then
				shown[#shown + 1] = x
			end
		end
		local rows = {}
		if open_fleet then
			rows[1] = {name = "< All public servers", back = true}
		end
		for _, g in ipairs(starport.group(shown, open_fleet)) do
			local x = g.server
			local row = {group = g}
			if g.kind == "fleet" then
				row.name = tostring(g.name) .. "   fleet of " .. g.count ..
						", " .. g.players .. " playing"
				row.line = tostring(g.description or "")
				row.fleet_id = g.fleet.id
			else
				row.host, row.port = x.address:match("^(.*):(%d+)$")
				row.address = x.address
				row.name = (g.kind == "pool" and tostring(g.name) .. "   " ..
						g.count .. " servers, " or tostring(x.name) .. "   ") ..
						g.players .. " playing"
				row.line = tostring(x.description or "") .. "\n" ..
						categories(x) .. "  via " ..
						table.concat(x.starports or {}, ", ")
				-- [STARPORT] 3: said before the connect, not after
				if x.access == "external" then
					row.signup = tostring(x.signup_url or "")
					row.line = row.line .. "\nSign up at " .. row.signup ..
							" first"
				end
				if web_tls_only and not x.tls then
					row.native_only = true
					row.line = "Native client only: no TLS in front of " ..
							"it, which a web page needs\n" .. row.line
				end
				-- A pool: its best first, the others to fall back on
				row.fallbacks = {}
				for i = 2, #g.servers do
					row.fallbacks[#row.fallbacks + 1] = g.servers[i].address
				end
			end
			rows[#rows + 1] = row
		end
		sp_list:set_rows(rows)
	end
	magic.SubscribeToEvent(search, "TextFinished", show_public)
	local function refresh(ask)
		starport.fetch(function(rows, info)
			sp_rows = rows
			sp_title.text = "Public servers: " .. #rows ..
					(info.hidden > 0 and ", " .. info.hidden ..
					" hidden by your filters" or "") ..
					(info.unasked > 0 and "; Refresh asks " .. info.unasked ..
					" more Starport(s)" or "") ..
					(info.stale > 0 and "; kept from " ..
					math.floor(info.stale / 60) .. " min ago" or "") ..
					(#info.errors > 0 and "\n" .. table.concat(info.errors,
					"\n") or "")
			show_public()
		end, ask)
	end
	refresh(false)
	local sp_buttons = left:CreateChild("UIElement")
	sp_buttons:SetLayout(LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
	for _, b in ipairs({
		{"Refresh", function() refresh(true) end},
		{"Report...", function()
			local address = picked and (picked.address or (picked.group and
					picked.group.servers[1].address))
			if not address or not starport.open_report(address) then
				show_error("Pick a public server to report")
			end
		end},
	}) do
		local button = make_button(sp_buttons, b[1])
		button:SetFixedHeight(26)
		magic.SubscribeToEvent(button, "Released", b[2])
	end

	-- **On this network** ([LAN_DISCOVERY]): what announces itself on
	-- the LAN, asked every second; redrawn only when it changed, so a
	-- pick and the scroll stay. Anyone on the network can announce, so
	-- it is said as heard, and the join is the ordinary connect.
	if direct then
		local lan_title = left:CreateChild("Text")
		lan_title:SetStyleAuto()
		local lan_list = ui_utils.server_list(left, {width = 440,
				height = 110}, pick)
		local shown, next_us = nil, 0
		root:SubscribeToStackEvent("Update", function()
			local now = api.get_time_us()
			if now < next_us then
				return
			end
			next_us = now + 1000000
			local rows = {}
			for _, e in ipairs(api.lan_servers()) do
				rows[#rows + 1] = {host = e.host, port = e.port,
						name = (e.name ~= "" and e.name or e.host) .. "   " ..
						e.players .. " playing",
						line = e.app .. " " .. e.version .. "  at " .. e.host ..
						":" .. e.port .. (e.account and
						"; needs an account there" or "")}
			end
			table.sort(rows, function(a, b) return a.name < b.name end)
			local sig = {}
			for _, r in ipairs(rows) do
				sig[#sig + 1] = r.name .. r.line
			end
			sig = table.concat(sig, "\n")
			if sig ~= shown then
				shown = sig
				lan_title.text = #rows == 0 and
						"On this network: nothing heard yet" or
						"On this network (as announced):"
				lan_list:set_rows(rows)
			end
		end)

		local used = left:CreateChild("Text")
		used:SetStyleAuto()
		used.text = "Servers used:"
		local list = ui_utils.server_list(left, {width = 440, height = 170},
				pick)
		local rows = {}
		for _, e in ipairs(network.known_addresses()) do
			local host, port = e.uri:match("^%a+://(.-):(%d+)$")
			if host and e.accepted then
				rows[#rows + 1] = {name = host .. ":" .. port, host = host,
						port = port,
						line = e.description ~= "" and e.description or nil}
			end
		end
		if #rows == 0 then
			used.text = "No servers used yet"
		end
		list:set_rows(rows)
	end

	do_connect = function()
		if not direct then
			if not picked then
				show_error("Pick a server from the list")
				return
			end
			if not picked.host then
				show_error("Pick a server of the fleet")
				return
			end
			if picked.signup and not picked.told then
				picked.told = true
				show_error("This server needs an account made at\n" ..
						picked.signup .. " first.\nConnect again when you "..
						"have one.")
				return
			end
			connect_or_show_error(picked.host .. ":" .. picked.port,
					picked.fallbacks)
			return
		end
		local host = address_edit:GetText()
		local port = port_edit:GetText()
		if host == "" then
			show_error("Enter a server address")
			return
		end
		local address = host
		if port ~= "" then
			address = host..":"..port
		end
		if picked and picked.address == address and picked.signup and
				not picked.told then
			picked.told = true
			show_error("This server needs an account made at\n" ..
					picked.signup .. " first.\nConnect again when you have one.")
			return
		end
		connect_or_show_error(address, picked and
				picked.address == address and picked.fallbacks or nil)
	end

	local connect_button = make_button(window, "Connect", true)
	magic.SubscribeToEvent(connect_button, "Released", function()
		do_connect()
	end)
	if direct then
		magic.SubscribeToEvent(address_edit, "TextFinished", function()
			do_connect()
		end)
		magic.SubscribeToEvent(port_edit, "TextFinished", function()
			do_connect()
		end)
	end

	local back_button = make_button(window, "Back")
	-- Fixed: the column beside the list would stretch the last button
	back_button:SetFixedHeight(26)
	magic.SubscribeToEvent(back_button, "Released", function()
		uistack.main:pop(root)
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		if event_data:GetInt("Key") == KEY_ESCAPE then
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function show_starting(game)
	local root, window = push_status_screen("starting_local_server",
			"Starting "..game.."...")
	-- What the server says it is doing, off the STATUS lines of its log
	-- ([START_PROGRESS]): a first start compiles fourteen modules behind
	-- this screen, and this is what makes that read as progress
	local stage = window:CreateChild("Text")
	stage:SetStyleAuto()
	stage.text = ""

	local t0 = api.get_time_us()
	local last_status, last_status_at, last_poll = nil, t0, 0
	local done = false
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		local port, line = api.local_server_state()
		if port then
			done = true
			-- **This screen goes when the game comes** ([MENU_LEAVE]):
			-- left on the stack, its window sat in the played world and
			-- its Escape stopped the server instead of pausing
			uistack.main:pop(root)
			connect_or_show_error("localhost:"..port)
			return
		end
		if not api.local_server_running() then
			done = true
			uistack.main:pop(root)
			M.show_dead_server("The server exited while starting")
			return
		end
		local now = api.get_time_us()
		if now - last_poll > 250000 then
			last_poll = now
			if line ~= last_status then
				last_status, last_status_at = line, now
			end
		end
		-- The seconds since the stage began, always: a screen that sits
		-- still while the user can only wait is the failure [FIRST_RUN]'s
		-- run looks for
		local secs = math.floor((now - last_status_at) / 1000000)
		stage.text = (last_status or "Waiting for the server").."  "..secs.." s"
		-- Not a fixed wait: a fresh compile of every module can outlast
		-- one on a slow machine. A hang is no new status line for 120 s.
		if now - last_status_at > 120 * 1000000 then
			done = true
			api.stop_local_server()
			uistack.main:pop(root)
			show_error("Server did not start: no progress for 120 s"..
					(last_status and (", last at \""..last_status.."\"") or ""))
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		-- Only while there is still a start to cancel ([MENU_LEAVE])
		if done then
			return
		end
		if event_data:GetInt("Key") == KEY_ESCAPE then
			done = true
			api.stop_local_server()
			uistack.main:pop(root)
			-- **The launcher hears the cancel** ([RELEASE_RED] core.sh,
			-- 2026-10-04): the room had stood down for the launch and
			-- stayed stood down, its input with nobody, until told
			api.leave()
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function do_start_local_game(game, launch)
	local ok, err = api.start_local_server(game, launch)
	if not ok then
		show_error(err)
		return
	end
	show_starting(game)
end

local function show_waiting_for_old_server(game, launch)
	local root = push_status_screen("stopping_old_server",
			"Stopping previous server...")
	local t0 = api.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function()
		if done then
			return
		end
		if not api.local_server_running() then
			done = true
			uistack.main:pop(root)
			do_start_local_game(game, launch)
			return
		end
		if api.get_time_us() - t0 > 10 * 1000000 then
			done = true
			uistack.main:pop(root)
			ui_utils.show_confirm_dialog(
				"The previous local server is still running.\n"..
				"It may be saving. Force kill it?",
				function()
					api.stop_local_server(true)
					do_start_local_game(game, launch)
				end,
				function()
				end)
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		if event_data:GetInt("Key") == KEY_ESCAPE then
			done = true
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

-- A game by name, with launch: key=value lines for the server's -u, or
-- nil. What a tile on the launch grid ends in ([LAUNCH_GRID]).
function M.start_local_app(game, launch)
	api.stop_local_server()
	if not api.local_server_running() then
		do_start_local_game(game, launch)
		return
	end
	show_waiting_for_old_server(game, launch)
end

function M.show_local_apps(page)
	local root = uistack.main:push({desc="local_game"})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)

	local menu = ui_utils.vertical_menu(root, {min_width = MENU_BUTTON_WIDTH})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Local app"

	local games = api.list_apps()
	if #games == 0 then
		local empty = menu.window:CreateChild("Text")
		empty:SetStyleAuto()
		empty.text = "No apps found"
	else
		-- A page at a time: at 720 px high the whole list ran off the
		-- screen, Back with it
		-- simplified: 15 a page; a window under ~600 px high still clips
		-- one, and the height read from the window is the upgrade
		local per_page = 15
		local pages = math.ceil(#games / per_page)
		page = math.max(1, math.min(page or 1, pages))
		for i = (page - 1) * per_page + 1, math.min(#games, page * per_page) do
			local name = games[i].name
			local button = make_game_button(menu.window, name, games[i].size)
			menu:add(button, function()
				M.start_local_app(name)
			end)
		end
		local function redraw(p)
			uistack.main:pop(root)
			M.show_local_apps(p)
		end
		if page > 1 then
			menu:add("^ previous   (page " .. (page - 1) .. " of " .. pages .. ")",
					function() redraw(page - 1) end)
		end
		if page < pages then
			menu:add("v more   (page " .. (page + 1) .. " of " .. pages .. ")",
					function() redraw(page + 1) end)
		end
	end

	menu:add("Back", function()
		uistack.main:pop(root)
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
