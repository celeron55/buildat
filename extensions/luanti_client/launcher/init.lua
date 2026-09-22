-- Buildat: extensions/luanti_client/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The Luanti client's tile on the launch grid ([LAUNCH_GRID]). Sandboxed:
-- it cannot reach the extension's trusted half, so the launch goes through
-- ctx.launch and the extension's on_untrusted_launch(), which treats the
-- params as it would a packet from a server.
return function(ctx)
	return {
		{id = "connect", label = "Play on a Luanti server",
			icon = "luanti.png", order = 20,
			description = "Connect this client to a Luanti server",
			run = function() ctx.launch{extension = "luanti_client"} end},
		-- The client's own settings ([EXT_SETTINGS]): a trusted screen on
		-- the stack, no server behind it
		{id = "settings", label = "Luanti client settings",
			icon = "luanti.png", order = 191,
			description = "Render mode, view range, view bobbing, name",
			run = function()
				ctx.launch{extension = "luanti_client", params = {menu = "settings"}}
			end},
	}
end
