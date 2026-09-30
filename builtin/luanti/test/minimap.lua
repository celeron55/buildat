-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Is a minimap HUD element drawn?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=minimap_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/minimap.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- A square in the top right corner of the screen holding the world around
-- the player seen from above, and a second one at the bottom left that is
-- half as wide as it is high, which is what says the size the element names
-- is the size it gets. Walk: what is in them moves under the player, who is
-- in the middle of both.
core.register_on_joinplayer(function(player)
	core.after(3, function()
		if not (player and player:is_player()) then
			return
		end
		player:hud_add({
			type = "minimap",
			position = {x = 1, y = 0},
			alignment = {x = 1, y = -1},
			offset = {x = -16, y = 16},
			size = {x = 192, y = 192},
		})
		player:hud_add({
			type = "minimap",
			position = {x = 0, y = 1},
			alignment = {x = -1, y = 1},
			offset = {x = 16, y = -16},
			size = {x = 96, y = 192},
		})
		core.log("action", "minimap check: two of them are up")
	end)
end)
