-- Luanti's compass element, both ways it is drawn: a picture that turns with
-- the player and a strip that scrolls past.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=compass_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/compass.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Connect a client and turn: the picture at the top left turns the other
-- way, and the strip under it scrolls. devtest ships no compass of its own,
-- so both are the engine's own heart, which is lopsided enough to see
-- turning and repeats across the strip as a row.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		player:hud_add({
			hud_elem_type = "compass",
			position = {x = 0.15, y = 0.15},
			alignment = {x = 0, y = 0},
			size = {x = 128, y = 128},
			text = "heart.png",
			direction = 0,
			number = 0,
		})
		player:hud_add({
			hud_elem_type = "compass",
			position = {x = 0.15, y = 0.35},
			alignment = {x = 0, y = 0},
			size = {x = 256, y = 48},
			text = "heart.png",
			direction = 2,
			number = 0,
		})
		core.log("action", "compass check: one that turns and one that scrolls")
	end)
end)
