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

-- The extensions this menu offers as things to launch, in the order they are
-- shown. An extension named here says for itself what it is called, what it
-- looks like and what launching it does, in an M.launch table; see
-- doc/design.txt, "Launchable extensions".
--
-- The list is written here rather than found by looking: requiring every
-- extension in the tree to ask whether it is launchable would run all of
-- their loading code to build a menu.
local LAUNCHABLE = {
	"luanti_client",
}

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

function M.boot()
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

	-- The entries side by side, because there are several of them
	local row = layout:CreateChild("UIElement")
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

	add("__menu/res/icon_local.png", "Local game",
			launch_menu.show_local_game)
	add("__menu/res/icon_network.png", "Connect to server",
			launch_menu.show_connect_to_server)
	-- What the user sets once and every game honours
	add("__menu/res/icon_preferences.png", "Preferences", preferences.show)

	-- And an entry for every extension that says it can be launched
	for _, name in ipairs(LAUNCHABLE) do
		local ok, ext = pcall(require, "buildat/extension/"..name)
		local launch = ok and type(ext) == 'table' and ext.launch or nil
		if not launch or type(launch.run) ~= 'function' then
			-- A menu that cannot be drawn because one extension is missing
			-- or broken is worse than a menu with one entry fewer
			log:warning("Launchable extension "..dump(name)..
					" has no M.launch: "..
					(ok and "loaded" or dump(ext)))
		else
			add(launch.icon, launch.title or name, launch.run)
		end
	end

	-- Now that the entries are known: each in its place, and the row exactly
	-- as wide as they are, so that the layout's own border lines it up with
	-- the title above
	for i, item in ipairs(items) do
		item.button:SetPosition((i - 1) * (ENTRY_WIDTH + ENTRY_SPACING), 0)
	end
	row:SetFixedWidth(#items * ENTRY_WIDTH +
			math.max(0, #items - 1) * ENTRY_SPACING)
	row:SetFixedHeight(ENTRY_HEIGHT)

	-- launch_menu's keyboard selection, which is worth having here: up and
	-- down, left and right, enter, and the mouse moving the same selection
	local nav = ui_utils.bind_button_menu(root, items, function(key)
		if key == KEY_ESCAPE then
			log:info("KEY_ESCAPE pressed at top level")
			engine:Exit()
		end
	end)
	nav:on_change(function(button, selected)
		local c = selected and 1 or DIM
		button:GetChild("ButtonImage").color = magic.Color(c, c, c)
		button:GetChild("ButtonText").color = magic.Color(c, c, c)
	end)
end

return M
-- vim: set noet ts=4 sw=4:
