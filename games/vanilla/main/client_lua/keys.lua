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
	-- Official's three modes and its special key ([FLY_MODES]): fast mode
	-- is a toggle, and on the ground the special key is what moves fast
	-- while it is on
	{action = "aux1", key = magic.KEY_E, name = "E",
			what = "Special - move fast in fast mode"},
	{action = "fly", key = magic.KEY_K, name = "K", what = "Fly mode on and off"},
	{action = "fast", key = magic.KEY_J, name = "J", what = "Fast mode on and off"},
	{action = "noclip", key = magic.KEY_H, name = "H",
			what = "Noclip on and off (while flying)"},
	{action = "hotbar", first = magic.KEY_1, last = magic.KEY_9,
			name = "1 - 9", what = "Pick a hotbar slot"},
	{action = "chat", key = magic.KEY_T, name = "T",
			what = "Chat - a / line is a command"},
	{action = "inventory", key = magic.KEY_I, name = "I", what = "Inventory"},
	{action = "drop", key = magic.KEY_Q, name = "Q",
			what = "Drop what is held (Ctrl: one)"},
	{action = "mouse", key = magic.KEY_TAB, name = "Tab",
			what = "The mouse: in the world, on the screen"},
	{action = "mute", key = magic.KEY_M, name = "M",
			what = "Sound muted or not"},
	{action = "camera", key = magic.KEY_C, name = "C",
			what = "Camera: first person, behind, in front"},
	{action = "zoom", key = magic.KEY_Z, name = "Z",
			what = "Zoom while held (the zoom privilege)"},
	{action = "fog", key = magic.KEY_F3, name = "F3",
			what = "Fog on and off"},
	-- The engine's own, listed for the player and not rebindable here
	{action = "screenshot", key = magic.KEY_F12, name = "F12", engine = true,
			what = "A screenshot (the engine's)"},
	{action = "profiler", key = magic.KEY_F6, name = "F6", engine = true,
			what = "The engine's profiler on and off"},
	{action = "fullscreen", key = magic.KEY_F11, name = "F11", engine = true,
			what = "Fullscreen on and off (the engine's)"},
	{action = "hud", key = magic.KEY_F1, name = "F1",
			what = "The HUD on and off"},
	{action = "chatlog", key = magic.KEY_F2, name = "F2",
			what = "The chat log on and off"},
	{action = "detail", key = magic.KEY_F5, name = "F5",
			what = "The line of detail on and off"},
	{action = "menu", key = magic.KEY_ESCAPE, name = "Escape",
			what = "Pause menu, or close what is open"},
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
	return b.default_key ~= nil and not b.engine
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
	root.defaultStyle = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
	local window = root:CreateChild("Window")
	window:SetStyleAuto()
	window:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(10, 10, 10, 10))
	window:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local title = window:CreateChild("Text")
	title:SetStyleAuto()
	title:SetText("Key bindings")
	local hint = window:CreateChild("Text")
	hint:SetStyleAuto()
	hint:SetText("Pick a row and press a key. Escape leaves it, Backspace puts the default back.")
	-- Two columns, so that the rows fit a 720 window ([BOX_FIXES] a): the
	-- buttons interleave left, right, left... which is the order the
	-- grid nav walks with two columns
	local columns = window:CreateChild("UIElement")
	columns:SetLayout(magic.LM_HORIZONTAL, 12, magic.IntRect(0, 0, 0, 0))
	local col = {}
	for c = 1, 2 do
		col[c] = columns:CreateChild("UIElement")
		col[c]:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	end
	local function make_button(parent, label)
		local button = parent:CreateChild("Button")
		button:SetStyleAuto()
		button:SetName("Button")
		button:SetLayout(magic.LM_VERTICAL, 10, magic.IntRect(0, 0, 0, 0))
		button.minHeight = 24
		button.minWidth = 380
		local text = button:CreateChild("Text")
		text:SetName("ButtonText")
		text:SetStyleAuto()
		text.text = label
		text:SetTextAlignment(magic.HA_LEFT)
		return button
	end
	local rows = {}
	local items = {}
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
	for i, b in ipairs(M.BINDINGS) do
		local button = make_button(col[(i - 1) % 2 + 1], label_of(b))
		rows[#rows + 1] = {b = b, button = button}
		items[#items + 1] = {button, function()
			if bindable(b) then
				listening = b
				refresh()
			end
		end}
	end
	-- An odd count leaves the right column a row short; the two rows
	-- under the columns are a row of their own each, so the nav's index
	-- arithmetic stays on the grid: a blank fills the gap
	if #M.BINDINGS % 2 == 1 then
		local blank = col[2]:CreateChild("UIElement")
		blank.minHeight = 24
	end
	local bottom = window:CreateChild("UIElement")
	bottom:SetLayout(magic.LM_HORIZONTAL, 12, magic.IntRect(0, 0, 0, 0))
	local defaults = make_button(bottom, "Defaults")
	items[#items + 1] = {defaults, function()
		for _, b in ipairs(M.BINDINGS) do
			if bindable(b) then
				b.key, b.name = b.default_key, b.default_name
			end
		end
		listening = nil
		refresh()
		save()
	end}
	local back = make_button(bottom, "< back")
	items[#items + 1] = {back, function()
		uistack.main:pop(root)
		on_back()
	end}
	local nav = ui_utils.bind_button_menu(root, items)
	nav:set_columns(2)
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
