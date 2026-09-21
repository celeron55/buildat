-- Buildat: vanilla/client_lua/keys.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The key bindings, and the one screen that edits them ([KEY_BINDINGS]):
-- the Luanti settings screen of the launcher and the pause menu's "Key
-- bindings" both draw this. The table is the code's own -- key_down() in
-- init.lua reads it -- so a key cannot be bound here and missed there.
-- What differs from the defaults is kept as "key.<action>=<key name>" rows
-- in the launcher's settings list, which the server keeps in
-- user/luanti/launcher.json and sends whole as main:settings; the client
-- applies the rows when they arrive and the editor sends the whole list
-- back through main:set_settings. Key names are Urho3D's, so the file is
-- readable; the mouse's buttons and wheel are not bindable.
local magic = require("buildat/extension/urho3d")
local uistack = require("buildat/extension/uistack")
local ui_utils = require("buildat/extension/ui_utils")
local cereal = require("buildat/extension/cereal")
local log = buildat.Logger("vanilla/keys")

local M = {}

M.BINDINGS = {
	{action = "forward", key = magic.KEY_W, name = "W", what = "Walk forward"},
	{action = "back", key = magic.KEY_S, name = "S", what = "Walk back"},
	{action = "left", key = magic.KEY_A, name = "A", what = "Walk left"},
	{action = "right", key = magic.KEY_D, name = "D", what = "Walk right"},
	{action = "jump", key = magic.KEY_SPACE, name = "Space",
			what = "Jump, and up while flying"},
	{action = "sneak", key = magic.KEY_LSHIFT, name = "Shift",
			what = "Sneak, and down while flying"},
	{action = "fast", key = magic.KEY_LCTRL, name = "Ctrl", what = "Move fast"},
	{action = "fly", key = magic.KEY_K, name = "K", what = "Fly on and off"},
	{action = "noclip", key = magic.KEY_H, name = "H",
			what = "Through walls on and off"},
	{action = "hotbar", first = magic.KEY_1, last = magic.KEY_9,
			name = "1 - 9", what = "Pick a hotbar slot"},
	{action = "chat", key = magic.KEY_T, name = "T",
			what = "Say something - a line starting with / is a command"},
	{action = "inventory", key = magic.KEY_I, name = "I", what = "Inventory"},
	{action = "drop", key = magic.KEY_Q, name = "Q",
			what = "Drop what is held - with Ctrl, one of it"},
	{action = "mouse", key = magic.KEY_TAB, name = "Tab",
			what = "The mouse in the world or on the screen"},
	{action = "hud", key = magic.KEY_F1, name = "F1",
			what = "The HUD on and off"},
	{action = "chatlog", key = magic.KEY_F2, name = "F2",
			what = "The chat log on and off"},
	{action = "detail", key = magic.KEY_F5, name = "F5",
			what = "The line of detail on and off"},
	{action = "menu", key = magic.KEY_ESCAPE, name = "Escape",
			what = "The pause menu, or close what is open"},
	-- Listed for the player's sake; the code for these is the mouse
	-- handling rather than a key lookup, and they are not bindable
	{action = "dig", name = "Left mouse", what = "Dig"},
	{action = "place", name = "Right mouse", what = "Place, or use"},
	{action = "wield", name = "Mouse wheel", what = "Pick a hotbar slot"},
}

M.BIND = {}
for _, b in ipairs(M.BINDINGS) do
	M.BIND[b.action] = b
	b.default_key = b.key
	b.default_name = b.name
end

local function bindable(b)
	return b.default_key ~= nil
end

-- The settings list as last sent by the server, so that the editor sends
-- the whole of it back with its rows changed
M.settings = {}

-- The rows applied to the table: what the server's list holds for each
-- bindable action, and the default for the rest. Returns how many differ
-- from the defaults.
function M.apply(list)
	M.settings = list
	local given = {}
	for _, row in ipairs(list) do
		local action, name = row:match("^key%.([%w_]+)=(.+)$")
		if action then
			given[action] = name
		end
	end
	local changed = 0
	for _, b in ipairs(M.BINDINGS) do
		if bindable(b) then
			local name = given[b.action]
			local key = name and magic.input:GetKeyFromName(name) or 0
			if name and key ~= 0 then
				b.key, b.name = key, name
				changed = changed + 1
			else
				b.key, b.name = b.default_key, b.default_name
			end
		end
	end
	if changed > 0 then
		log:info(changed .. " key bindings from the settings")
	end
	return changed
end

-- The list with the key rows as the table stands: the other rows kept, a
-- key row for every binding that is not its default
local function list_with_keys()
	local out = {}
	for _, row in ipairs(M.settings) do
		if not row:match("^key%.") then
			out[#out + 1] = row
		end
	end
	for _, b in ipairs(M.BINDINGS) do
		if bindable(b) and b.key ~= b.default_key then
			out[#out + 1] = "key." .. b.action .. "=" .. b.name
		end
	end
	return out
end

local function save()
	buildat.send_packet("main:set_settings",
			cereal.binary_output(list_with_keys(), {"array", "string"}))
end

-- The editor: a row per action with its key's name and what it does; a row
-- picked (click, or arrows and Enter) says "Press a key...", and the next
-- key down binds it -- Escape leaves it, Backspace puts the default back.
-- A key bound on two rows shows red on both, and the later bind stands.
-- "Defaults" puts every default back. Every change is saved at once.
-- on_back is what the back row does: the settings screen, or the pause
-- menu.
function M.draw(on_back)
	local root = uistack.main:push({desc = "vanilla keys"})
	local menu = ui_utils.vertical_menu(root, {min_width = 520})
	menu.window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local title = menu.window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("Key bindings")
	local hint = menu.window:CreateChild("Text")
	hint:SetStyleAuto()
	hint:SetText("Pick a row and press a key. Escape leaves it, Backspace puts the default back.")
	local rows = {}
	local listening = nil
	local function label_of(b)
		return string.format("%-8s  %s", b.name, b.what)
	end
	local function refresh()
		local seen = {}
		for _, b in ipairs(M.BINDINGS) do
			if bindable(b) then
				seen[b.key] = (seen[b.key] or 0) + 1
			end
		end
		for _, r in ipairs(rows) do
			local text = r.button:GetChild("ButtonText")
			if text then
				if listening == r.b then
					text.text = "Press a key...   " .. r.b.what
				else
					text.text = label_of(r.b)
				end
				local twice = bindable(r.b) and seen[r.b.key] and seen[r.b.key] > 1
				text.color = twice and magic.Color(1, 0.35, 0.35) or magic.Color(1, 1, 1)
			end
		end
	end
	for _, b in ipairs(M.BINDINGS) do
		local button = menu:add(label_of(b), function()
			if bindable(b) then
				listening = b
				refresh()
			end
		end)
		rows[#rows + 1] = {b = b, button = button}
	end
	menu:add("Defaults", function()
		for _, b in ipairs(M.BINDINGS) do
			if bindable(b) then
				b.key, b.name = b.default_key, b.default_name
			end
		end
		listening = nil
		refresh()
		save()
	end)
	menu:add("< back", function()
		uistack.main:pop(root)
		on_back()
	end)
	-- The key while a row listens, before the menu's own navigation gets it
	root:SubscribeToStackEvent("KeyDown", function(event_type, event_data)
		if listening == nil then
			return
		end
		local key = event_data:GetInt("Key")
		local b = listening
		listening = nil
		if key == magic.KEY_ESCAPE then
			-- Leaves the row as it was
		elseif key == magic.KEY_BACKSPACE then
			b.key, b.name = b.default_key, b.default_name
			save()
		else
			local name = magic.input:GetKeyName(key)
			if name ~= nil and name ~= "" then
				b.key, b.name = key, name
				save()
			end
		end
		refresh()
	end)
	refresh()
	magic.input:SetMouseVisible(true, "the key bindings")
	return root
end

return M
