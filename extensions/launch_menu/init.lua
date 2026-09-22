-- Buildat: extension/launch_menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/launch_menu")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe
local network = require("buildat/extension/network").safe
local M = {safe = nil}

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

-- Same min width as the local-game list, so the boot menu is as wide.
local MENU_BUTTON_WIDTH = 200

local function make_button(parent, label)
	local button = parent:CreateChild("Button")
	button:SetStyleAuto()
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

-- Name + size as separate texts so the size can be smaller and duller.
-- minWidth is ~30% over the old single-line content width.
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
	size_text.color = magic.Color(0.5, 0.5, 0.5)
	size_text:SetTextAlignment(HA_RIGHT)
	return button
end

local function make_labeled_edit(parent, label, value, width)
	local text = parent:CreateChild("Text")
	text:SetStyleAuto()
	text.text = label
	local edit = parent:CreateChild("LineEdit")
	edit:SetStyleAuto()
	-- Fixed, not min: a column beside a tall list would stretch it
	edit:SetFixedHeight(26)
	edit.minWidth = width or 300
	edit:SetText(value)
	return edit
end

-- The placeholder under a running game's screens; leave_game() pops the
-- stack down through it
local game_root = nil

-- A menu-only connection left for the launcher ([MENU_CONTEXT]): the
-- client drops the connection, the server and the sandbox's leavings
-- (__buildat_leave_to_menu), and the stack comes back to the grid
local function leave_game()
	if not game_root then
		return
	end
	__buildat_leave_to_menu()
	-- Down through the grid, the stack's first screen -- the starting
	-- screen and the placeholder go with the game's own -- and the grid
	-- drawn again: a game installed from ContentDB is a new tile
	uistack.main:pop_to(uistack.main.stack[1], true)
	game_root = nil
	magic.input:SetMouseVisible(true, "back to the launcher")
	require("buildat/extension/__menu").boot()
end

local function connect_or_show_error(address)
	local ok, err = buildat.connect_server(address)
	if ok then
		log:info("connect_server() ok")
		game_root = uistack.main:push({desc="empty (game is running)"})
		magic.ui:SetFocusElement(nil)
	else
		log:info("connect_server() failed")
		show_error(err)
	end
end

local function show_connect_to_server()
	buildat.request_stop_local_server()
	local root = uistack.main:push({desc="connect_to_server"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

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

	local address_edit = make_labeled_edit(window, "Address", "localhost")
	local port_edit = make_labeled_edit(window, "Port (optional)", "29500")
	address_edit:SetFocus(true)
	local do_connect
	local used = left:CreateChild("Text")
	used:SetStyleAuto()
	used.text = "Servers used:"
	local list = ui_utils.server_list(left, {width = 440, height = 300},
			function(row, second)
		address_edit:SetText(row.host)
		port_edit:SetText(row.port)
		if second then
			do_connect()
		end
	end)
	local rows = {}
	for _, e in ipairs(network.known_addresses()) do
		local host, port = e.uri:match("^%a+://(.-):(%d+)$")
		if host and e.accepted then
			rows[#rows + 1] = {name = host .. ":" .. port, host = host, port = port,
					line = e.description ~= "" and e.description or nil}
		end
	end
	if #rows == 0 then
		used.text = "No servers used yet"
	end
	list:set_rows(rows)

	do_connect = function()
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
		connect_or_show_error(address)
	end

	local connect_button = make_button(window, "Connect")
	magic.SubscribeToEvent(connect_button, "Released",
	function(self, event_type, event_data)
		do_connect()
	end)
	magic.SubscribeToEvent(address_edit, "TextFinished",
	function(self, event_type, event_data)
		do_connect()
	end)
	magic.SubscribeToEvent(port_edit, "TextFinished",
	function(self, event_type, event_data)
		do_connect()
	end)

	local back_button = make_button(window, "Back")
	-- Fixed: the column beside the list would stretch the last button
	back_button:SetFixedHeight(26)
	magic.SubscribeToEvent(back_button, "Released",
	function(self, event_type, event_data)
		uistack.main:pop(root)
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function show_starting(game)
	local root = uistack.main:push({desc="starting_local_server"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local status = window:CreateChild("Text")
	status:SetStyleAuto()
	status.text = "Starting "..game.."..."
	-- What the server says it is doing, off the STATUS lines of its log
	-- ([START_PROGRESS]): a first start compiles fourteen modules behind
	-- this screen, and this is what makes that read as progress
	local stage = window:CreateChild("Text")
	stage:SetStyleAuto()
	stage.text = ""

	local t0 = buildat.get_time_us()
	local last_status, last_status_at, last_poll = nil, t0, 0
	local done = false
	-- While this screen is up a frame that stalls two seconds is logged
	-- with this thread's stack: the counter froze on the box while the
	-- server loaded worldgen and luanti_mapgen, and the client does
	-- nothing for the server then ([BOX_PLAYTEST_2] 12). Put back with
	-- the screen. The frame's own phase word is in the log too.
	buildat.set_watchdog_seconds(2)
	root:SubscribeToStackEvent("Update", function(event_type, event_data)
		if done then
			buildat.set_watchdog_seconds(0)
			return
		end
		if buildat.local_server_ready() then
			done = true
			connect_or_show_error("localhost:"..buildat.local_server_port())
			return
		end
		if not buildat.local_server_running() then
			done = true
			uistack.main:pop(root)
			M.show_dead_server("The server exited while starting")
			return
		end
		local now = buildat.get_time_us()
		if now - last_poll > 250000 then
			last_poll = now
			local line = buildat.local_server_status()
			if line ~= last_status then
				last_status, last_status_at = line, now
			end
		end
		-- The seconds since the stage began, always: a screen that sits
		-- still while the user can only wait is the failure [FIRST_RUN]'s
		-- run looks for, and before the server's first status line
		-- there was nothing here to move
		local secs = math.floor((now - last_status_at) / 1000000)
		stage.text = (last_status or "Waiting for the server").."  "..secs.." s"
		-- Not a fixed wait: a fresh compile of every module can outlast
		-- one on a slow machine. A hang is no new status line for 120 s.
		if now - last_status_at > 120 * 1000000 then
			done = true
			buildat.request_stop_local_server()
			uistack.main:pop(root)
			show_error("Server did not start: no progress for 120 s"..
					(last_status and (", last at \""..last_status.."\"") or ""))
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			done = true
			buildat.request_stop_local_server()
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function do_start_local_game(game, launch)
	local ok, err = buildat.start_local_server(game, launch)
	if not ok then
		show_error(err)
		return
	end
	show_starting(game)
end

local function show_waiting_for_old_server(game, launch)
	local root = uistack.main:push({desc="stopping_old_server"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local status = window:CreateChild("Text")
	status:SetStyleAuto()
	status.text = "Stopping previous server..."

	local t0 = buildat.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function(event_type, event_data)
		if done then
			return
		end
		if not buildat.local_server_running() then
			done = true
			uistack.main:pop(root)
			do_start_local_game(game, launch)
			return
		end
		if buildat.get_time_us() - t0 > 10 * 1000000 then
			done = true
			uistack.main:pop(root)
			ui_utils.show_confirm_dialog(
				"The previous local server is still running.\n"..
				"It may be saving. Force kill it?",
				function()
					buildat.force_kill_local_server()
					do_start_local_game(game, launch)
				end,
				function()
				end)
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			done = true
			uistack.main:pop(root)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

local function start_local_game(game, launch)
	buildat.request_stop_local_server()
	if not buildat.local_server_running() then
		do_start_local_game(game, launch)
		return
	end
	show_waiting_for_old_server(game, launch)
end

local function show_local_game()
	local root = uistack.main:push({desc="local_game"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local menu = ui_utils.vertical_menu(root, {min_width = MENU_BUTTON_WIDTH})

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Local game"

	local games = buildat.list_games()
	if #games == 0 then
		local empty = menu.window:CreateChild("Text")
		empty:SetStyleAuto()
		empty.text = "No games found"
	else
		for _, game in ipairs(games) do
			local name = game.name
			local button = make_game_button(menu.window, name, game.size)
			menu:add(button, function()
				start_local_game(name)
			end)
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

-- The two things this extension knows how to do, for the launch menu to put
-- in front of a player: the list of local games, and connecting to a remote
-- server. Both push a screen of their own and come back on their own.
-- A local server that died: the last lines of its log and where the
-- whole of it is, so a crash's backtrace is on the screen and not just
-- gone ([START_PROGRESS]). on_close runs when the dialog is closed.
function M.show_dead_server(title, on_close)
	local path, tail = buildat.local_server_log_tail(20)
	ui_utils.show_message_dialog(title.."\n\n"..tail..
			"\nThe full log is at "..path, on_close)
end

M.show_local_game = show_local_game
M.show_connect_to_server = show_connect_to_server
-- And starting a game by name, which is what a tile on the launch grid
-- ends in ([LAUNCH_GRID]); the same screens as picking it from the list
M.start_local_game = start_local_game
M.leave_game = leave_game
-- And the same two for the sandboxed launcher file ([LAUNCH_GRID]): each
-- pushes a trusted screen and comes back, and takes nothing from the caller
M.safe = {
	show_local_game = function() show_local_game() end,
	show_connect_to_server = function() show_connect_to_server() end,
}

-- Kept so that `-m launch_menu` still starts something: the launch menu
-- itself is extensions/__menu, which is what the client boots by default.
-- Required here rather than at the top, because that one requires this one.
function M.boot()
	require("buildat/extension/__menu").boot()
end

-- The vertical-menu version of the launch menu, which is what the `buildat`
-- launcher binary used to run. Kept because it is a working menu with
-- keyboard selection and no icons to load, and it is one call away if the
-- icon menu ever needs replacing.
function M.boot_plain()
	local root = uistack.main:push({desc = "boot"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	root.defaultStyle = style

	local menu = ui_utils.vertical_menu(root, {
		spacing = 16,
		padding = magic.IntRect(10, 20, 10, 20),
		min_width = MENU_BUTTON_WIDTH,
	})

	local logo = menu.window:CreateChild("Sprite")
	logo:SetTexture(magic.cache:GetResource("Texture2D", "buildat_logo.png"))
	logo:SetFixedSize(160, 160)

	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Buildat"
	title:SetFontSize(28)
	title:SetTextAlignment(HA_CENTER)

	menu:add("Local game", show_local_game)
	menu:add("Connect to server", show_connect_to_server)
	menu:add("Exit", function()
		engine:Exit()
	end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			engine:Exit()
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
