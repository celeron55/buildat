-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Do the particles a game spawns reach the player?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=particle_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/particles.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Three things to look at, all out of the engine's own textures so that
-- they are there whatever the game ships:
--
--  - a fountain a few nodes in front of the player: a spawner of hearts
--    thrown up and falling back, there until it is deleted twenty seconds
--    later;
--  - a bubble at every node that is dug, one particle each, rising;
--  - and rain attached to the player, falling out of a box six nodes over
--    their head, which follows them as they walk.
--
-- What says it worked is a screenshot -- look up for the rain, which falls
-- from over the player's head. The server logs the spawner ids, and a client
-- run at -l 5 says what texture each spawner got:
--
--   D luanti : luanti:particles: spawner 2 bubble.png ->
--       luanti_media/bubble.png, attached self
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local pos = player:get_pos()
	local id = core.add_particlespawner({
		amount = 300,
		time = 0,
		playername = name,
		minpos = {x = pos.x + 4, y = pos.y, z = pos.z - 1},
		maxpos = {x = pos.x + 6, y = pos.y, z = pos.z + 1},
		minvel = {x = -1, y = 3, z = -1},
		maxvel = {x = 1, y = 5, z = 1},
		minacc = {x = 0, y = -9, z = 0},
		maxacc = {x = 0, y = -9, z = 0},
		minexptime = 1.5,
		maxexptime = 2.5,
		minsize = 2,
		maxsize = 4,
		texture = "heart.png",
	})
	core.log("action", "particle check: a fountain, spawner " .. tostring(id))
	core.after(20, function()
		core.delete_particlespawner(id)
		core.log("action", "particle check: the fountain is gone")
	end)
	-- And one that follows the player, which is what a game's weather is
	local followed = core.add_particlespawner({
		amount = 120,
		time = 0,
		playername = name,
		attached = player,
		pos = {min = {x = -3, y = 6, z = -3}, max = {x = 3, y = 6, z = 3}},
		vel = {min = {x = 0, y = -6, z = 0}, max = {x = 0, y = -4, z = 0}},
		exptime = {min = 1.2, max = 1.8},
		size = {min = 2, max = 3},
		vertical = true,
		texture = "bubble.png",
	})
	core.log("action", "particle check: one attached to the player, spawner " ..
			tostring(followed))
end)

core.register_on_dignode(function(pos, node, digger)
	core.add_particle({
		pos = {x = pos.x, y = pos.y + 0.5, z = pos.z},
		velocity = {x = 0, y = 1.5, z = 0},
		acceleration = {x = 0, y = 0.5, z = 0},
		expirationtime = 2,
		size = 6,
		texture = "bubble.png",
	})
	core.log("action", "particle check: a bubble at " ..
			core.pos_to_string(pos))
end)
