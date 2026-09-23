-- Buildat: extensions/serverlist/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The fetched serverlist's tiles ([LAUNCH_WORLD] step 5). Sandboxed, as
-- every launcher file is: the rows are plain data from the extension's
-- safe side, and a launch hands the address to `luanti_client` through
-- ctx.launch -- the same door its own tile uses.
return function(ctx)
	local sl = require("buildat/extension/serverlist")
	local out = {}
	for i, s in ipairs(sl.servers()) do
		out[#out + 1] = {
			id = "s" .. i,
			label = s.name,
			-- **A server, and how much it matters** ([LAUNCH_SIGNIFY]):
			-- the player count, which a launch UI ranks and scales by
			-- without having to know what a server is
			category = "server",
			significance = s.players,
			order = 300 + i,
			description = s.address .. "   " .. s.players .. " playing",
			run = function()
				ctx.launch{extension = "luanti_client",
					params = {address = s.address}}
			end,
		}
	end
	return out
end
-- vim: set noet ts=4 sw=4:
