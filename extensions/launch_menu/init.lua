-- Buildat: extension/launch_menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/launch_menu")
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe
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
		text.fixedWidth = text.width
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
	edit.minHeight = 24
	edit.minWidth = width or 300
	edit:SetText(value)
	return edit
end

local function connect_or_show_error(address)
	local ok, err = buildat.connect_server(address)
	if ok then
		log:info("connect_server() ok")
		uistack.main:push({desc="empty (game is running)"})
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

	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(LM_VERTICAL, 10, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(HA_LEFT, VA_CENTER)

	local address_edit = make_labeled_edit(window, "Address", "localhost")
	local port_edit = make_labeled_edit(window, "Port (optional)", "29500")
	address_edit:SetFocus(true)

	local function do_connect()
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
	magic.SubscribeToEvent(back_button, "Released",
	function(self, event_type, event_data)
		uistack.main:pop(root)
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			uistack.main:pop(root)
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

	local t0 = buildat.get_time_us()
	local done = false
	root:SubscribeToStackEvent("Update", function(event_type, event_data)
		if done then
			return
		end
		if buildat.local_server_ready() then
			done = true
			connect_or_show_error("localhost:"..buildat.local_server_port())
			return
		end
		if not buildat.local_server_running() then
			done = true
			show_error("Server exited")
			uistack.main:pop(root)
			return
		end
		if buildat.get_time_us() - t0 > 90 * 1000000 then
			done = true
			buildat.request_stop_local_server()
			show_error("Server did not start")
			uistack.main:pop(root)
		end
	end)

	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		local key = event_data:GetInt("Key")
		if key == KEY_ESCAPE then
			done = true
			buildat.request_stop_local_server()
			uistack.main:pop(root)
		end
	end)
end

local function do_start_local_game(game)
	local ok, err = buildat.start_local_server(game)
	if not ok then
		show_error(err)
		return
	end
	show_starting(game)
end

local function show_waiting_for_old_server(game)
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
			do_start_local_game(game)
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
					do_start_local_game(game)
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
		end
	end)
end

local function start_local_game(game)
	buildat.request_stop_local_server()
	if not buildat.local_server_running() then
		do_start_local_game(game)
		return
	end
	show_waiting_for_old_server(game)
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
		end
	end)
end

-- The two things this extension knows how to do, for the launch menu to put
-- in front of a player: the list of local games, and connecting to a remote
-- server. Both push a screen of their own and come back on their own.
M.show_local_game = show_local_game
M.show_connect_to_server = show_connect_to_server

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
	local root = uistack.main:push("boot")

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
		end
	end)
end

return M
-- vim: set noet ts=4 sw=4:
