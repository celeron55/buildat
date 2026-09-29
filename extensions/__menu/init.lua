-- Buildat: extension/__menu/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
--
-- The launch menu: what the client shows when it is started with nothing to
-- connect to, which is what starting buildat does.
--
-- There used to be two of these -- this one, which the client booted, and
-- extensions/launch_menu, which a separate `buildat` launcher binary ran
-- through `buildat_client -m launch_menu`. There is one binary now and one
-- menu: this one, with launch_menu's local-game and connect-to-server
-- screens behind it and its keyboard selection under it.
-- **This menu runs in the sandbox** ([LAUNCH_SANDBOX]), which is what
-- its launch_ui.txt asks for. Three shapes come with that: the safe API
-- is `buildat` itself here and `buildat.safe` outside, `require`
-- answers an extension's safe half inside and the whole extension
-- outside, and a file of its own is loaded by a verb rather than by
-- `dofile` and a path.
local api = buildat.safe or buildat
local log = buildat.Logger("extension/__menu")
local dump = api.dump
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
local uistack = require("buildat/extension/uistack")
uistack = uistack.main and uistack or uistack.safe
local ui_utils = require("buildat/extension/ui_utils")
ui_utils = ui_utils.bind_button_menu and ui_utils or ui_utils.safe
local launch_menu = require("buildat/extension/launch_menu")
local preferences = api.run_extension_file("preferences.lua")
-- **The constants are globals in trusted Lua and fields of the safe
-- table in the sandbox**, so they are named once here and the code
-- below reads the same on both sides ([LAUNCH_SANDBOX])
local FILTER_NEAREST, HA_CENTER, HA_LEFT, KEY_ESCAPE, LM_VERTICAL, VA_CENTER, VA_TOP =
		magic.FILTER_NEAREST, magic.HA_CENTER, magic.HA_LEFT, magic.KEY_ESCAPE, magic.LM_VERTICAL, magic.VA_CENTER, magic.VA_TOP

local M = {safe = nil}

-- The launch grid ([LAUNCH_GRID]): the tiles come from the tree, any number
-- from every games/*, builtin/* and extensions/* that ships
-- launcher/init.lua, found by buildat.list_launchers() and run in the
-- sandbox -- module client-Lua trust, since the file is on the way into a
-- game and a whole-server sandbox is only as good as the least-trusted code
-- on that path. A file that errors, returns a non-table or an action with
-- no label or run is one warning naming it, and the rest of the grid draws.
-- The one way out of a file is ctx.launch, below, whose params cross as
-- plain data and whose target is entered through on_untrusted_launch().
-- **The grid comes through the verb**, not through the trusted file:
-- `launch_actions()` answers the same tiles as plain data with a key,
-- and `launch(key)` is what runs one ([LAUNCH_SANDBOX]).

local DIM = 0.55

-- One entry is this wide, which is what centring the row of them needs to be
-- arithmetic rather than a guess: a vertical layout stretches its children to
-- its own width, so a row left to itself is as wide as the menu and its icons
-- sit at the left of it while everything else is centred.
local ENTRY_WIDTH = 190
local ENTRY_SPACING = 24
-- The icon plus the label under it, which is what the row has to be tall
-- enough for; a row with nothing laying it out does not work it out itself
local ENTRY_HEIGHT = 160

-- launch_action is -a's kind/name/id: the grid is drawn and that one
-- action is run on top of it, the way picking its tile would
function M.boot(launch_action)
	local root = uistack.main:push({desc = "boot"})

	local style = magic.cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	root.defaultStyle = style

	local layout = root:CreateChild("Window")
	layout:SetStyleAuto()
	layout:SetName("Layout")
	layout:SetLayout(LM_VERTICAL, 16, magic.IntRect(20, 20, 20, 20))
	-- HA_LEFT, because the UI stack's own element is a horizontal layout and
	-- refuses anything else -- with a warning on every boot. Centring the
	-- whole menu on the screen would mean giving that element a different
	-- layout; centring what is *inside* the menu is what the logo and the
	-- row of entries below do.
	layout:SetAlignment(HA_LEFT, VA_CENTER)

	-- The logo, centred over the rest. It needs an element of its own to be
	-- centred in: a child of a layout does not get its horizontal alignment
	-- honoured -- Urho3D's UIElement::GetLayoutChildPosition() only reads it
	-- to decide which border to apply -- so the holder is what the layout
	-- stretches to the full width, and the logo centres inside that.
	local logo_holder = layout:CreateChild("UIElement")
	logo_holder:SetFixedHeight(160)
	-- A BorderImage rather than a Sprite: a Sprite works out its own screen
	-- position from a hotspot and a transform, so an alignment does not
	-- centre it, while a BorderImage is a plain element with a texture on it
	local logo = logo_holder:CreateChild("BorderImage")
	logo.texture = magic.cache:GetResource("Texture2D", "buildat_logo.png")
	logo:SetFixedSize(160, 160)
	logo:SetAlignment(HA_CENTER, VA_TOP)

	-- What this is, top left, small ([VERSION]): the version and the hash
	-- of the tree it was built from, "-dirty" when that was nobody's commit
	-- The first child of the menu's own layout: the stack's root is a
	-- horizontal layout that argues with anything placed by hand
	local version, hash = api.version()
	local label = layout:CreateChild("Text")
	label:SetStyleAuto()
	label.text = version .. " " .. hash
	label:SetFontSize(11)
	label.color = magic.Color(0.6, 0.6, 0.6)
	label:SetTextAlignment(HA_LEFT)

	local title = layout:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Buildat"
	title:SetFontSize(28)
	title:SetTextAlignment(HA_CENTER)
	title.color = magic.Color(0.867, 0.867, 0.867)

	-- The grid, inside a viewport that is as tall as the window allows
	-- and clips the rest: a grid of more lines than fit scrolls by the
	-- selection, below
	local viewport = layout:CreateChild("UIElement")
	viewport:SetAlignment(HA_LEFT, VA_TOP)
	viewport.clipChildren = true
	viewport.enabled = true
	-- The entries side by side, because there are several of them
	local row = viewport:CreateChild("UIElement")
	-- HA_LEFT rather than HA_CENTER: inside a layout the alignment only says
	-- which border to apply, and the row is made exactly as wide as its
	-- entries below, so the left border is what lines it up with the rest
	row:SetAlignment(HA_LEFT, VA_TOP)
	-- No layout on it: the entries are placed by hand below. A horizontal
	-- layout re-applies its children's own alignments, and a button whose
	-- style gives it any alignment but the left is then a warning from
	-- Urho3D on every boot -- for a row of three fixed-width things, saying
	-- where they go is less machinery than arguing with the layout.
	-- An element Urho3D has not been told is enabled is not hit by a click,
	-- and neither is anything inside it
	row.enabled = true

	-- One entry: an icon, a word for it, and what picking it does. The
	-- selected one is drawn bright and the rest dim, which is what the
	-- keyboard and the mouse both move.
	-- Tiles whose icon is named and does not resolve; a tile that quietly
	-- falls back to a blank square is how twenty-two games shared one
	-- picture without anybody noticing ([LAUNCH_API])
	local icons_drawn, icons_missing = 0, 0
	local function menu_entry(icon, text)
		local button = row:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		button:SetFixedWidth(ENTRY_WIDTH)
		button:SetAlignment(HA_LEFT, VA_TOP)
		local button_image = button:CreateChild("Sprite")
		button_image:SetName("ButtonImage")
		local tex = icon and
				magic.cache:GetResource("Texture2D", icon) or nil
		if tex then
			-- The icons are drawn at the size they are painted, and a
			-- game's own icon is pixel art
			tex.filterMode = magic.FILTER_NEAREST
			button_image:SetTexture(tex)
			icons_drawn = icons_drawn + 1
		elseif icon then
			icons_missing = icons_missing + 1
			log:warning("__menu: tile "..dump(text).." names an icon that "..
					"does not resolve: "..dump(icon))
		end
		button_image.color = magic.Color(DIM, DIM, DIM)
		button_image:SetFixedSize(120, 120)
		local button_text = button:CreateChild("Text")
		button_text:SetName("ButtonText")
		button_text:SetStyleAuto()
		button_text.text = text
		button_text.color = magic.Color(DIM, DIM, DIM)
		button_text:SetAlignment(HA_CENTER, VA_TOP)
		button_text:SetTextAlignment(HA_CENTER)
		return button
	end

	local items = {}
	local function add(icon, text, action, description)
		items[#items + 1] = {button = menu_entry(icon, text),
				label = text, description = description,
				action = function()
					log:info("Menu entry: "..dump(text))
					action()
				end}
	end

	-- What the user sets once and every game honours; not a launch, so
	-- the menu's own rather than a tile from the tree
	add("__menu/res/icon_preferences.png", "Engine settings", preferences.show,
			"What every game honours: the window, the sound, the mouse.")
	-- **The console offers its screen and the menu takes it too**
	-- ([LAUNCH_CONSOLE]: it is offered to every launch UI, and the room
	-- already had it). Not a launch either: it draws over this screen
	-- and hands it back. The menu's own keys stand down by themselves
	-- while it is up -- a stack subscription only fires for the element
	-- with the focus, and the console takes it.
	local console = require("buildat/extension/launch_console")
	console = console and (console.show and console or console.safe)
	if not (console and console.show) then
		log:warning("__menu: no developer console to offer")
	end
	if console and console.show then
		add("__menu/res/icon_console.png", "Developer console", function()
			console.show(function() end)
		end, "A Lua console in the sandbox, with the API document beside it.")
	end
	-- And every launch action the tree offers, in the grid's order
	local actions = api.launch_actions()
	local played = 0
	for _, action in ipairs(actions) do
		if action.last_launched then played = played + 1 end
		add(action.icon, action.label, function()
			local ok, why = api.launch(action.key)
			if not ok then
				log:warning("__menu: "..tostring(why))
			end
		end, action.description)
	end

	log:info("__menu: "..#items.." tiles, "..icons_drawn..
			" of them with a picture and "..icons_missing.." without, "..
			played.." launched before")

	-- The selected entry's name and description, to the right of the logo
	-- in the logo's row ([LAUNCH_DESC]): the label on the first line,
	-- larger, the description under it, wrapping to the window's right
	-- edge; set as the selection moves, by keys or by the mouse, and
	-- cleared when nothing is selected
	local DESC_MARGIN = 24
	local desc_x = math.floor(magic.ui.root.width / 2) + 80 + DESC_MARGIN
	local desc_w = math.max(100, magic.ui.root.width - desc_x - DESC_MARGIN)
	local desc_name = logo_holder:CreateChild("Text")
	desc_name:SetStyleAuto()
	desc_name:SetFontSize(22)
	desc_name:SetPosition(desc_x, 40)
	desc_name:SetFixedWidth(desc_w)
	desc_name.color = magic.Color(0.867, 0.867, 0.867)
	local desc_text = logo_holder:CreateChild("Text")
	desc_text:SetStyleAuto()
	desc_text:SetFontSize(14)
	desc_text:SetPosition(desc_x, 72)
	desc_text:SetFixedWidth(desc_w)
	desc_text:SetWordwrap(true)
	desc_text.color = magic.Color(0.7, 0.7, 0.7)
	local function show_description(item)
		desc_name.text = item and item.label or ""
		desc_text.text = item and item.description or ""
	end

	-- Now that the entries are known: a grid wrapping by the window's
	-- width and the row exactly as wide as its columns, so that the
	-- layout's own border lines it up with the title above
	local columns = math.max(1, math.min(#items, math.floor(
			(magic.ui.root.width - 2 * 20 + ENTRY_SPACING) /
			(ENTRY_WIDTH + ENTRY_SPACING))))
	for i, item in ipairs(items) do
		local col = (i - 1) % columns
		local line = math.floor((i - 1) / columns)
		item.button:SetPosition(col * (ENTRY_WIDTH + ENTRY_SPACING),
				line * (ENTRY_HEIGHT + ENTRY_SPACING))
	end
	local lines = math.ceil(#items / columns)
	local grid_w = columns * ENTRY_WIDTH +
			math.max(0, columns - 1) * ENTRY_SPACING
	local grid_h = lines * ENTRY_HEIGHT +
			math.max(0, lines - 1) * ENTRY_SPACING
	row:SetFixedWidth(grid_w)
	row:SetFixedHeight(grid_h)
	-- What the window leaves for the grid under the logo and the title,
	-- in whole lines; the viewport is that tall and the row moves inside
	-- it so the selected line is always in view
	local line_step = ENTRY_HEIGHT + ENTRY_SPACING
	local room = magic.ui.root.height - 2 * 20 - 160 - 16 - 40 - 16
	local visible_lines = math.max(1, math.min(lines,
			math.floor((room + ENTRY_SPACING) / line_step)))
	viewport:SetFixedWidth(grid_w)
	viewport:SetFixedHeight(visible_lines * ENTRY_HEIGHT +
			math.max(0, visible_lines - 1) * ENTRY_SPACING)
	local first_line = 0
	local function scroll_to(i)
		local line = math.floor((i - 1) / columns)
		if line < first_line then
			first_line = line
		elseif line >= first_line + visible_lines then
			first_line = line - visible_lines + 1
		end
		row:SetPosition(0, -first_line * line_step)
	end

	-- launch_menu's keyboard selection, which is worth having here: up and
	-- down, left and right, enter, and the mouse moving the same selection
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			log:info("KEY_ESCAPE pressed at top level")
			api.quit()
		end
	end)
	nav:set_columns(columns)
	nav:on_change(function(button, selected, index)
		local c = selected and 1 or DIM
		button:GetChild("ButtonImage").color = magic.Color(c, c, c)
		button:GetChild("ButtonText").color = magic.Color(c, c, c)
		if selected and index then
			scroll_to(index)
			show_description(items[index])
		elseif not selected and index and desc_name.text == items[index].label then
			show_description(nil)
		end
	end)

	-- **The setting said another launch UI and it did not load**, so
	-- this one says so rather than leaving the player wondering why
	-- their choice did nothing ([LAUNCH_SANDBOX]'s fallback)
	local fell_back = api.launch_ui_fell_back and api.launch_ui_fell_back()
	if fell_back then
		ui_utils.show_message_dialog("The launch UI \"" .. fell_back ..
				"\" did not load, so this is the menu.\n\n" ..
				"The log has the error.")
	end

	if launch_action then
		local found = nil
		for _, action in ipairs(actions) do
			if action.key == launch_action or
					action.from.."/"..tostring(action.id) == launch_action then
				found = action
			end
		end
		if found then
			log:info("Launch action: "..launch_action)
			api.launch(found.key)
		else
			log:warning("Launch action "..dump(launch_action)..
					" is not on the grid")
		end
	end
end

-- **What the client asks a launcher for** ([MENU_CONTEXT]): a game's
-- own menu offers "back to the launcher" and calls `buildat.leave()`,
-- which comes here. This grid had none of these, so that call found
-- nothing and fell through to a plain disconnect -- the client sat with
-- no server and no menu, which is what [FIRST_RUN] had been failing on
-- since ContentDB's install was driven (2026-09-24).
--
-- The screens a game is started through are launch_menu's, pushed onto
-- the same stack this grid is on, so leaving is the stack coming back
-- down to the grid -- as launch_menu's own leave_game does.
local in_a_game = false

-- **A game that was launched into a menu of its own says when the
-- choosing is over** ([LAUNCH_API]'s fourth ask). The grid has no
-- animation to resume, so it says so and no more; the room is what
-- wants this.
function M.game_loading(what)
	log:info("__menu: the game is loading a " .. tostring(what))
end

function M.entered_game()
	in_a_game = true
end

function M.in_game()
	return in_a_game
end

-- A local server that died: the last lines of its log and where the
-- whole of it is, so a crash's backtrace is on the screen and not just
-- gone ([START_PROGRESS]). The client asks the launcher for this when
-- the server it started goes away, and a launcher that cannot answer
-- leaves the player with a shutdown and no reason for it -- which is
-- what the grid did until 2026-09-24.
function M.show_dead_server(title, on_close)
	local path, tail = api.local_server_log_tail(20)
	ui_utils.show_message_dialog(title .. "\n\n" .. tail ..
			"\nThe full log is at " .. path, on_close)
end

function M.leave_game()
	if not in_a_game and not api.local_server_running() then
		return false
	end
	-- **The stack comes down before the sweep, not after it.** The
	-- screens over the grid are the game's own -- vanilla's menu pushes
	-- onto this same stack -- and `leave_to_menu` takes the game's
	-- elements with it, so popping afterwards is popping things that
	-- are already gone ("UIElement ... was removed", 2026-09-24).
	if uistack.main.stack[1] then
		pcall(function()
			uistack.main:pop_to(uistack.main.stack[1], true)
		end)
	end
	-- The connection, the server and the sandbox's leavings
	api.leave_to_menu()
	in_a_game = false
	magic.input:SetMouseVisible(true, "back to the launcher")
	M.boot()
	log:info("back to the grid")
	return true
end

return M
-- vim: set noet ts=4 sw=4:
