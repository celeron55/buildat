-- Buildat: games/vanilla/main/client_lua/pause.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The pause menu, a window of the client's own ([VANILLA_PUBLIC] 2): the
-- game is told nothing about it. Escape used to disconnect, which is a key
-- nobody was told about doing the one thing that cannot be undone.
--
-- On a public server it has the account pages, builtin/accounts' as the
-- floorplanner has them, and an admin's world menu, which is main/menu.lua
-- over the world. While any of it is up, luanti.hold() makes the world
-- keep its hands off the keys and the mouse, as a form does.
--
--   local open = run_script_file("main/pause.lua")(o)
-- o.keys: keys.lua's table, whose editor is the key bindings page.
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local luanti = require("buildat/module/luanti")

local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("vanilla: could not load accounts.lua: " .. tostring(err))
end
-- This instance has every accounts packet from here on: the join was
-- main/join.lua's, before the world
accounts.logged_in = true
accounts.on_kicked = function()
	buildat.disconnect()
end
-- The chat console ([CHAT_CONSOLE]): Luanti's chat, what came before this
-- script and all that comes after
for _, line in ipairs(luanti.chat_lines or {}) do
	accounts.chat_add(line)
end
luanti.sub_chat(function(line)
	accounts.chat_add(line)
end)
accounts.chat_send = function(text)
	buildat.send_packet("main:chat",
			cereal.binary_output({text}, {"array", "string"}))
end

-- What the server said in main:account
local account = {public = false, admin = false, world = "", is_local = false}
local window = nil
local o = nil
local open

buildat.sub_packet("main:account", function(data)
	local v = cereal.binary_input(data, {"array", "string"})
	account = {public = v[1] == "1", admin = v[2] == "1", world = v[3] or "",
			is_local = v[4] == "1"}
	o.keys.public = account.public
	-- A menu up before this came (the web starts paused) is missing what
	-- the account adds to it
	if window then
		open()
	end
end)

local function close()
	if window then
		window:Remove()
		window = nil
	end
	accounts.close_page()
	luanti.hold(nil)
end

-- Each click: muted -> 0 dB, then down the ladder in 6 dB steps, then
-- muted again. Six clicks round rather than eleven, a pause menu being
-- somewhere a player passes through; the settings screen has every step.
-- buildat.set_sound is the one preference a game may write ("Client
-- preferences" in doc/client_api.txt). **In decibels, as every volume in
-- the tree is** ([VOLUME_LAW])
local function cycle_sound()
	local mute, db = buildat.get_sound()
	if mute then
		buildat.set_sound(false, 0)
	elseif db > -30 then
		buildat.set_sound(false, math.max(-30, db - 6))
	else
		buildat.set_sound(true, 0)
	end
end

local function sound_text()
	local mute, db = buildat.get_sound()
	return mute and "Sound: muted" or (db <= -33 and "Sound: off" or
			string.format("Sound: %d dB", db))
end

-- Held while a screen that takes Escape as its own Back is up (the key
-- editor, the world menu): the hold swallows the key
local function swallow()
	luanti.hold(swallow)
end

-- What such a screen's Back does, a frame later: the Escape that pressed
-- it is still going round, and the world's key handler would take it for
-- the pause menu's
local pending = nil
local function later(fn)
	pending = fn
end
magic.SubscribeToEvent("Update", function()
	if pending then
		local fn = pending
		pending = nil
		fn()
	end
end)

-- The pause window makes way for a page; Escape on an account page is its
-- Back, to the pause menu
local function page(show, escape)
	if window then
		window:Remove()
		window = nil
	end
	luanti.hold(escape or swallow)
	show()
end

-- The admin's world menu over the world: the world list, a new world and
-- ContentDB, as at the boot
local function worlds()
	page(function()
		local _, err2, menu = buildat.run_script_file("main/menu.lua")
		if type(menu) ~= "table" then
			luanti.hold(nil)
			error("vanilla: could not load menu.lua: " .. tostring(err2))
		end
		menu.back = function()
			later(function() luanti.hold(nil) end)
		end
	end)
end

open = function()
	close()
	local w = accounts.page_window(360)
	window = w
	-- **On the web Escape does not close it** (user, 2026-09-30): the
	-- world takes the mouse back as it closes, and a browser grants no
	-- pointer lock for an Escape -- Firefox took it and let it go, and
	-- the view spun with a mouse the game thought was its own. A click
	-- is what a lock can be asked for from: Continue, or anywhere off
	-- the menu.
	luanti.hold(close, w, buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil)
	accounts.page_text(w, "Paused")
	if account.world ~= "" then
		accounts.page_text(w, "World: " .. account.world)
	end
	-- Continuing is the first thing on it and the first thing a player
	-- wants: escape (natively) and a click off the menu do the same, but a
	-- menu whose only way back is a key nobody was told about is a menu
	-- that traps people
	accounts.page_button(w, "Continue playing", close)
	accounts.page_button(w, "Key bindings", function()
		page(function()
			o.keys.draw(function() later(open) end)
		end)
	end)
	accounts.page_button(w, "Chat...", function()
		page(function() accounts.chat_page(open) end, open)
	end)
	local s
	s = accounts.page_button(w, sound_text(), function()
		cycle_sound()
		s:GetChild(0):SetText(sound_text())
	end)
	-- **The viewing range, the player's own** (user, 2026-09-30), kept on
	-- this client for this server: each press the next step, round to the
	-- nearest again, never over what the server allows (keys.view in
	-- init.lua). A web client starts lower, and a fast one can go up.
	local view = o.keys.view
	if view then
		local STEPS = {40, 60, 80, 120, 160, 240, 360, 500, 800}
		local function view_text()
			return "View range: " .. view.current() ..
					((buildat.storage_read("view_range") or "") == "" and
					" (default)" or "")
		end
		local vb
		vb = accounts.page_button(w, view_text(), function()
			local now, nxt = view.current(), nil
			for _, n in ipairs(STEPS) do
				if n > now and n <= view.ceiling then
					nxt = n
					break
				end
			end
			-- The server's own number is the last step when it is not one
			if not nxt and now < view.ceiling then
				nxt = view.ceiling
			end
			view.choose(nxt or math.min(STEPS[1], view.ceiling))
			vb:GetChild(0):SetText(view_text())
		end)
	end
	if account.public then
		if not account.is_local then
			accounts.page_button(w, "Change password...", function()
				page(function() accounts.password_page(open) end, open)
			end)
		end
		if account.admin then
			accounts.page_button(w, "Users...", function()
				page(function() accounts.users_page(open) end, open)
			end)
			accounts.page_button(w, "Worlds...", worlds)
		end
	end
	-- A browser tab has no launcher to leave to, and is closed as a tab
	-- (only the web page sets BUILDAT_PAGE_HTTPS)
	if buildat.get_env("BUILDAT_PAGE_HTTPS") == nil then
		accounts.page_button(w, "Leave the game", function() buildat.leave() end)
	elseif account.public and not account.is_local then
		-- The tab's way out, which also ends a kept login ([ACC_KEEP])
		accounts.page_button(w, "Log out", accounts.logout)
	end
end

-- A click off the menu is Continue; not on a page it made way for. On the
-- release, so that the world does not take the mouse with a button held
-- down and start digging with it.
local pressed_off = false
local function off_menu()
	if not window then
		return false
	end
	local sc = magic.ui.scale
	local m = magic.input:GetMousePosition()
	local ux, uy = m.x / sc, m.y / sc
	local p, s = window.screenPosition, window.size
	return ux < p.x or uy < p.y or ux >= p.x + s.x or uy >= p.y + s.y
end
magic.SubscribeToEvent("MouseButtonDown", function()
	pressed_off = off_menu()
end)
magic.SubscribeToEvent("MouseButtonUp", function()
	if pressed_off and off_menu() then
		close()
	end
	pressed_off = false
end)

return function(options)
	o = options
	-- The chat console straight from the world, for the touch controls'
	-- Chat; its Back goes back to the world
	o.keys.open_chat = function()
		close()
		page(function() accounts.chat_page(close) end, close)
	end
	return open
end
-- vim: set noet ts=4 sw=4:
