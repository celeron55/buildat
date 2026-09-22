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
-- user/luanti/settings.json and sends whole as main:settings; the client
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
	{action = "minimap", key = magic.KEY_V, name = "V",
			what = "Minimap: off, surface, radar, three sizes each"},
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

-- The editor is the one both clients share, luanti_client/res/key_editor.lua,
-- served by the module as luanti/key_editor.lua; on_back is what the back
-- row does: the settings screen, or the pause menu
function M.draw(on_back)
	local ok, err, editor = buildat.run_script_file("luanti/key_editor.lua")
	if not ok or type(editor) ~= "table" then
		log:warning("key_editor.lua: " .. tostring(err))
		return nil
	end
	return editor.draw{magic = magic, uistack = uistack, ui_utils = ui_utils,
			bindings = M.BINDINGS, bindable = bindable, save = save,
			on_back = on_back}
end

return M
