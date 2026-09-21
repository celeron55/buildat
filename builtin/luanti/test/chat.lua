-- Colours in what is said: a mod colours a chat line and each piece is drawn
-- in the colour it asks for.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=chat_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/chat.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- Connect a client: four lines arrive at the bottom left, three of them
-- coloured and the last one plain.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		local name = player:get_player_name()
		core.chat_send_player(name,
				core.colorize("#ff4040", "red ") ..
				core.colorize("#40ff40", "green ") ..
				core.colorize("#8080ff", "blue"))
		core.chat_send_player(name,
				core.colorize("yellow", "a colour by name"))
		core.chat_send_player(name,
				core.colorize("#f0f", "three digits") ..
				" and then the line's own colour")
		core.chat_send_player(name, "no markup at all")
		core.log("action", "chat check: four lines said")
	end)
end)
