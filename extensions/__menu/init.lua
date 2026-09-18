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
local log = buildat.Logger("extension/__menu")
local dump = buildat.dump
local magic = require("buildat/extension/urho3d").safe
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils").safe
local launch_menu = require("buildat/extension/launch_menu")
local preferences = dofile(buildat.extension_path("__menu").."/preferences.lua")
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
local launch_grid = dofile(buildat.extension_path("__menu").."/launch_grid.lua")

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
	local root = uistack.main:push("boot")

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
	local function add(icon, text, action)
		items[#items + 1] = {button = menu_entry(icon, text),
				action = function()
					log:info("Menu entry: "..dump(text))
					action()
				end}
	end

	-- What the user sets once and every game honours; not a launch, so
	-- the menu's own rather than a tile from the tree
	add("__menu/res/icon_preferences.png", "Preferences", preferences.show)
	-- And every launch action the tree offers, in the grid's order
	local actions = launch_grid.actions(log)
	for _, action in ipairs(actions) do
		add(action.icon, action.label, action.run)
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
			engine:Exit()
		end
	end)
	nav:set_columns(columns)
	nav:on_change(function(button, selected, index)
		local c = selected and 1 or DIM
		button:GetChild("ButtonImage").color = magic.Color(c, c, c)
		button:GetChild("ButtonText").color = magic.Color(c, c, c)
		if selected and index then
			scroll_to(index)
		end
	end)

	if launch_action then
		local found = nil
		for _, action in ipairs(actions) do
			if action.from.."/"..tostring(action.id) == launch_action then
				found = action
			end
		end
		if found then
			log:info("Launch action: "..launch_action)
			found.run()
		else
			log:warning("Launch action "..dump(launch_action)..
					" is not on the grid")
		end
	end
end

return M
-- vim: set noet ts=4 sw=4:
