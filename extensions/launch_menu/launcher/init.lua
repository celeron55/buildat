-- Buildat: extensions/launch_menu/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launch menu's own two actions on the launch grid: the local-game
-- screen and the connect-to-server screen, which are trusted UI that ends
-- in the same launch as any other tile. Runs in the sandbox like every
-- launcher file ([LAUNCH_GRID]); what it reaches is launch_menu's .safe.
local launch_menu = require("buildat/extension/launch_menu")
return function(ctx)
	return {
		{id = "local", label = "Local game", icon = "local.png",
			description = "Start a game on this machine", order = 1,
			run = launch_menu.show_local_game},
		{id = "connect", label = "Connect to server", icon = "network.png",
			description = "Join a buildat server", order = 2,
			run = launch_menu.show_connect_to_server},
	}
end
