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

function M.boot()
	local root = uistack.main:push("boot")

	local style = magic.cache:GetResource("XMLFile", "__menu/res/boot_style.xml")
	root.defaultStyle = style

	local layout = root:CreateChild("Window")
	layout:SetStyleAuto()
	layout:SetName("Layout")
	layout:SetLayout(LM_VERTICAL, 16, magic.IntRect(20, 20, 20, 20))
	layout:SetAlignment(HA_LEFT, VA_CENTER)

	local logo = layout:CreateChild("Sprite")
	logo:SetTexture(magic.cache:GetResource("Texture2D", "buildat_logo.png"))
	logo:SetFixedSize(160, 160)

	local title = layout:CreateChild("Text")
	title:SetStyleAuto()
	title.text = "Buildat"
	title:SetFontSize(28)
	title:SetTextAlignment(HA_CENTER)
	title.color = magic.Color(0.867, 0.867, 0.867)

	-- The entries side by side, because there are several of them
	local row = layout:CreateChild("UIElement")
	row:SetLayout(LM_HORIZONTAL, 24, magic.IntRect(0, 0, 0, 0))
	row:SetAlignment(HA_CENTER, VA_TOP)
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
