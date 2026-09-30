-- Buildat: games/vanilla/main/client_lua/join.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A public server's first script ([VANILLA_PUBLIC] 2): the join, through
-- builtin/accounts. What comes after is the server's to send: the world,
-- the world menu for an admin while there is none, or else a wait until an
-- admin has chosen one.
local cereal = require("buildat/extension/cereal")

local _, err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("vanilla: could not load accounts.lua: " .. tostring(err))
end

local wait = nil
local function close_wait()
	if wait then
		wait:Remove()
		wait = nil
	end
end

accounts.on_kicked = function()
	buildat.disconnect()
end

buildat.sub_packet("main:join_wait", function(data)
	close_wait()
	wait = accounts.page_window(420)
	accounts.page_text(wait, cereal.binary_input(data, {"array", "string"})[1])
end)

-- The world is here; the world menu, when it loads, takes this over
buildat.sub_packet("main:menu_done", close_wait)

-- The title is the Luanti game the server runs, which the server says
-- right after starting this script
buildat.sub_packet("main:join_title", function(data)
	local title = cereal.binary_input(data, {"array", "string"})[1] or ""
	accounts.start({title = title ~= "" and title or "Luanti"})
end)
-- vim: set noet ts=4 sw=4:
