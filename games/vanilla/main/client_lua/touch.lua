-- Buildat: games/vanilla/main/client_lua/touch.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Touch controls** (user, 2026-09-30), official Luanti's
-- (src/gui/touchcontrols.cpp) with its crosshair mode (touch_use_crosshair):
-- - a finger put down at the lower left is a stick where it landed, and
--   walks;
-- - any other finger turns the view;
-- - a tap places or uses, and a finger held still digs, at the crosshair;
-- - Jump and Sneak at the lower right are held;
-- - Menu, Inventory, Chat and More along the top, More opening the rest:
--   drop, fly, fast, noclip, the camera and the minimap;
-- - a tap on the hotbar picks the slot.
-- init.lua reads what this holds: held[action] is key_down()'s, dig is the
-- left button's, and yaw and pitch are degrees to turn, taken each frame.
--
-- simplified: the stick is digital (the four walk keys), where Luanti's is
-- analog; the dig and place are at the crosshair rather than at the tapped
-- point; a hotbar of more than one row is tapped as one.
--
--   keys.touch = run_script_file("main/touch.lua")(o)
-- o: on_key(key), BIND, pause(), place(), set_wield(i), inventory(),
--    chat(), hotbar() -> count, slot_size, margin
local magic = require("buildat/extension/urho3d")
local luanti = require("buildat/module/luanti")
local log = buildat.Logger("vanilla/touch")

-- How long a finger is held still before it digs, and how far it may move
-- and still be a tap: Luanti's touch_long_tap_delay and its tap slop
local LONG_TAP_US = 400000
local SLOP = 12
-- Degrees the view turns for a drag across the screen's width
local TURN = 180
local STYLE = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")

return function(o)
	local T = {held = {}, dig = false, yaw = 0, pitch = 0}
	local fingers = {}
	local buttons = {}
	local more = nil

	local function screen()
		local sc = magic.ui.scale
		return magic.ui.root.width, magic.ui.root.height, sc
	end

	-- A button of the controls: a label at a corner, `at` its offset from
	-- it in UI pixels; `hold` makes it an action held while pressed
	local function button(text, ha, va, x, y, w, h, on_tap, hold)
		local b = magic.ui.root:CreateChild("Button")
		b.defaultStyle = STYLE
		b:SetStyleAuto()
		b:SetAlignment(ha, va)
		b:SetPosition(x, y)
		b:SetFixedSize(w, h)
		b.opacity = 0.7
		-- Under the pause menu and the pages (100), over the HUD
		b.priority = 50
		local t = b:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(text)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		if hold then
			magic.SubscribeToEvent(b, "Pressed", function()
				T.held[hold] = true
			end)
			magic.SubscribeToEvent(b, "Released", function()
				T.held[hold] = nil
			end)
		else
			magic.SubscribeToEvent(b, "Released", function()
				log:info("touch: " .. text)
				on_tap()
			end)
		end
		buttons[#buttons + 1] = b
		return b
	end

	local function key(action)
		return function()
			local b = o.BIND[action]
			if b and b.key then
				o.on_key(b.key)
			end
		end
	end

	local S = 64
	-- Under the status line and the chat's first lines
	local TOP = 72
	button("Jump", magic.HA_RIGHT, magic.VA_BOTTOM, -16, -96, S * 1.5, S,
			nil, "jump")
	button("Sneak", magic.HA_RIGHT, magic.VA_BOTTOM, -16 - S * 1.5 - 12, -96,
			S * 1.5, S, nil, "sneak")
	local top = {{"Menu", o.pause}, {"Inventory", o.inventory},
		{"Chat", o.chat}}
	local x = -16
	button("More", magic.HA_RIGHT, magic.VA_TOP, x, TOP, 90, 44,
			function()
		if more then
			for _, b in ipairs(more) do
				b.visible = not b.visible
			end
		end
	end)
	x = x - 90 - 8
	for i = #top, 1, -1 do
		local w = #top[i][1] * 10 + 30
		button(top[i][1], magic.HA_RIGHT, magic.VA_TOP, x, TOP, w, 44,
				top[i][2])
		x = x - w - 8
	end
	-- More's column, under it
	more = {}
	local rest = {{"Drop", "drop"}, {"Fly", "fly"}, {"Fast", "fast"},
		{"Noclip", "noclip"}, {"Camera", "camera"}, {"Minimap", "minimap"}}
	for i, r in ipairs(rest) do
		local b = button(r[1], magic.HA_RIGHT, magic.VA_TOP, -16,
				TOP + i * 52, 90, 44, key(r[2]))
		b.visible = false
		more[#more + 1] = b
	end

	-- The stick's base and knob, where the finger landed
	local base = magic.ui.root:CreateChild("BorderImage")
	base:SetFixedSize(120, 120)
	base.color = magic.Color(1, 1, 1, 0.15)
	base.priority = 49
	base.visible = false
	local knob = magic.ui.root:CreateChild("BorderImage")
	knob:SetFixedSize(48, 48)
	knob.color = magic.Color(1, 1, 1, 0.35)
	knob.priority = 49
	knob.visible = false

	local function over_buttons(ux, uy)
		for _, b in ipairs(buttons) do
			if b.visible then
				local p, s = b.screenPosition, b.size
				if ux >= p.x and uy >= p.y and ux < p.x + s.x and
						uy < p.y + s.y then
					return true
				end
			end
		end
		return false
	end

	-- The hotbar's slot under a point, or nil
	local function hotbar_slot(ux, uy)
		local count, slot, margin = o.hotbar()
		local w, h = screen()
		if uy < h - margin - slot or uy > h then
			return nil
		end
		local left = (w - count * slot) / 2
		local i = math.floor((ux - left) / slot) + 1
		if i >= 1 and i <= count then
			return i
		end
		return nil
	end

	local function stick_to(f, ux, uy)
		local r = 50
		local dx = math.max(-1, math.min(1, (ux - f.ux0) / r))
		local dy = math.max(-1, math.min(1, (uy - f.uy0) / r))
		T.held.forward = dy < -0.3 or nil
		T.held.back = dy > 0.3 or nil
		T.held.left = dx < -0.3 or nil
		T.held.right = dx > 0.3 or nil
		knob:SetPosition(math.floor(f.ux0 + dx * r - 24),
				math.floor(f.uy0 + dy * r - 24))
	end

	local function ui_point(x, y)
		local _, _, sc = screen()
		local rp = magic.ui.root.position
		return x / sc - rp.x, y / sc - rp.y
	end

	magic.SubscribeToEvent("TouchBegin", function(_, data)
		local id = data:GetInt("TouchID")
		local ux, uy = ui_point(data:GetInt("X"), data:GetInt("Y"))
		local f = {ux0 = ux, uy0 = uy, t0 = buildat.get_time_us()}
		fingers[id] = f
		if luanti.form_open() or over_buttons(ux, uy) then
			f.ui = true
			return
		end
		local slot = hotbar_slot(ux, uy)
		if slot then
			f.ui = true
			o.set_wield(slot)
			return
		end
		local w, h = screen()
		local stick_taken = false
		for _, g in pairs(fingers) do
			stick_taken = stick_taken or g.stick
		end
		if not stick_taken and ux < w * 0.45 and uy > h * 0.5 then
			f.stick = true
			base:SetPosition(math.floor(ux - 60), math.floor(uy - 60))
			base.visible, knob.visible = true, true
			stick_to(f, ux, uy)
			return
		end
		f.look = true
	end)

	magic.SubscribeToEvent("TouchMove", function(_, data)
		local f = fingers[data:GetInt("TouchID")]
		if not f or f.ui then
			return
		end
		local ux, uy = ui_point(data:GetInt("X"), data:GetInt("Y"))
		if f.stick then
			stick_to(f, ux, uy)
			return
		end
		local w, _, sc = screen()
		T.yaw = T.yaw + data:GetInt("DX") / sc / w * TURN
		T.pitch = T.pitch + data:GetInt("DY") / sc / w * TURN
		if math.abs(ux - f.ux0) > SLOP or math.abs(uy - f.uy0) > SLOP then
			f.moved = true
		end
	end)

	magic.SubscribeToEvent("TouchEnd", function(_, data)
		local id = data:GetInt("TouchID")
		local f = fingers[id]
		fingers[id] = nil
		if not f then
			return
		end
		if f.stick then
			T.held.forward, T.held.back = nil, nil
			T.held.left, T.held.right = nil, nil
			base.visible, knob.visible = false, false
		elseif f.look then
			if f.digging then
				T.dig = false
			elseif not f.moved and not luanti.form_open() then
				o.place()
			end
		end
		-- A held button whose release was never seen (the finger slid
		-- off it) is let go with the last finger
		if next(fingers) == nil then
			T.held.jump, T.held.sneak = nil, nil
			T.dig = false
		end
	end)

	-- A finger held still digs, and goes on digging when it then moves;
	-- the controls hide while a form or the pause menu is up
	local shown = true
	magic.SubscribeToEvent("Update", function()
		local now = buildat.get_time_us()
		for _, f in pairs(fingers) do
			if f.look and not f.moved and not f.digging and
					now - f.t0 > LONG_TAP_US then
				f.digging = true
				T.dig = true
			end
		end
		local want = not luanti.form_open()
		if want ~= shown then
			shown = want
			for _, b in ipairs(buttons) do
				b.visible = want
			end
			-- More's column starts closed again
			for _, b in ipairs(more) do
				b.visible = false
			end
		end
	end)

	return T
end
-- vim: set noet ts=4 sw=4:
