-- Buildat: games/vanilla_voxel_physics/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- One tile per installed Luanti game, as builtin/luanti's, starting this
-- variant instead of vanilla ([GAME_BASE]): its worlds are its own.
local PRETTY = {mineclone2 = "VoxeLibre", minetest_game = "Minetest Game"}
return function(ctx)
	local out = {}
	for i, name in ipairs(buildat.list_installed_games("luanti")) do
		if not name:find("%.old") then
			out[#out + 1] = {
				id = name, label = (PRETTY[name] or name) .. " + voxel physics",
				icon = "luanti.png", order = 150 + i,
				description = "Luanti game " .. name .. " with voxel physics (a sample)",
				run = function()
					ctx.launch{game = "vanilla_voxel_physics",
							params = {luanti_game = name, menu = "worlds"}}
				end,
			}
		end
	end
	return out
end
