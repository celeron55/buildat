-- Buildat: games/vanilla_voxel_physics/launcher/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- One tile for the sample ([GAME_BASE], [VOXEL_PHYSICS_SAMPLE]): the
-- variant started on VoxeLibre when it is installed, else on the first
-- Luanti game there is, at its world screen; its worlds are its own.
-- One tile rather than one per game, so the sample does not crowd the
-- grid the games' own tiles are on.
return function(ctx)
	local games = buildat.list_installed_games("luanti")
	local game = nil
	for _, name in ipairs(games) do
		if not name:find("%.old") and (game == nil or name == "mineclone2") then
			game = name
		end
	end
	if game == nil then
		return {}
	end
	return {{id = "voxel_physics", label = "Voxel physics sample",
		icon = "luanti.png", order = 150,
		description = "vanilla with undermine's voxel physics, on " .. game,
		run = function()
			ctx.launch{game = "vanilla_voxel_physics",
					params = {luanti_game = game, menu = "worlds"}}
		end}}
end
