-- Buildat: games/vanilla/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The launcher game's own tile ([LAUNCH_GRID]): its settings -- where the
-- import screens look, and the render mode a session draws in -- on its
-- settings screen, opened by the menu= param. The games' tiles and the
-- import tiles are builtin/luanti's, one per installed game.
return function(ctx)
	return {{id = "settings", label = "Luanti settings", icon = "luanti.png",
		order = 192,
		description = "Import search paths, the render mode",
		run = function()
			ctx.launch{game = "vanilla", params = {menu = "settings"}}
		end},
	-- ContentDB's games, fetched and installed by the server ([CONTENTDB])
	{id = "contentdb", label = "ContentDB", icon = "luanti.png", order = 193,
		description = "Browse and install games from content.luanti.org",
		run = function()
			ctx.launch{game = "vanilla", params = {menu = "contentdb"}}
		end}}
end
