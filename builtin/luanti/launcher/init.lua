-- Buildat: builtin/luanti/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- One tile per Luanti game installed under user/luanti/games -- devtest,
-- VoxeLibre, whatever is there -- which is why the launch grid asks every
-- time it is shown ([LAUNCH_GRID]). What a tile starts is the game's
-- server through games/luanti_launcher with the game's name as the one
-- param, which that module reads as it would a packet; when the launcher
-- game folds into this module the target becomes {module = "luanti"}.
-- The player sees the game's name, never the module's.
local PRETTY = {mineclone2 = "VoxeLibre", minetest_game = "Minetest Game"}
return function(ctx)
	local out = {}
	for i, name in ipairs(buildat.list_installed_games("luanti")) do
		if not name:find("%.old") then
			out[#out + 1] = {
				id = name, label = PRETTY[name] or name, icon = "luanti.png",
				description = "Luanti game " .. name, order = 100 + i,
				run = function()
					ctx.launch{game = "luanti_launcher",
							params = {luanti_game = name}}
				end,
			}
		end
	end
	-- And the two ways in: the launcher game's own import screens, whose
	-- lists are the server's, so the game opens them on a menu= param
	out[#out + 1] = {id = "import_game", label = "Import a game",
		icon = "luanti.png", order = 190,
		description = "Copy a game from a Luanti installation",
		run = function()
			ctx.launch{game = "luanti_launcher", params = {menu = "import_game"}}
		end}
	out[#out + 1] = {id = "import_world", label = "Import a world",
		icon = "luanti.png", order = 191,
		description = "Copy a world from a Luanti installation",
		run = function()
			ctx.launch{game = "luanti_launcher", params = {menu = "import_world"}}
		end}
	out[#out + 1] = {id = "settings", label = "Luanti settings",
		icon = "luanti.png", order = 192,
		description = "Where the import screens look, and more later",
		run = function()
			ctx.launch{game = "luanti_launcher", params = {menu = "settings"}}
		end}
	return out
end
