-- The colours inside a line of HUD text: core.colorize() writes Luanti's own
-- markup into it and each piece is drawn in the colour it asks for.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=hudtext_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/hudtext.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Connect a client: four lines sit in the middle of the screen, the first
-- three coloured word by word and the last one plain, which is what says a
-- line with no markup in it still draws.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		local text =
				core.colorize("#ff4040", "red ") ..
				core.colorize("#40ff40", "green ") ..
				core.colorize("#8080ff", "blue") .. "\n" ..
				core.colorize("yellow", "a colour by name") .. "\n" ..
				core.colorize("#f0f", "three digits") ..
				" and then the line's own colour\n" ..
				"no markup at all"
		player:hud_add({
			hud_elem_type = "text",
			position = {x = 0.5, y = 0.4},
			alignment = {x = 0, y = 0},
			number = 0xC0C0C0,
			text = text,
		})
		core.log("action", "hud text check: four lines added")
	end)
end)
