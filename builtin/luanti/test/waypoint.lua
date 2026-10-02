-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- What a waypoint looks like, which is a thing to look at rather than to
-- assert: a label over a place in the world with how far away it is, and a
-- picture over the same place.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=waypoint_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/waypoint.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Connect a client and look straight ahead: the label is eight metres away
-- and the heart is a metre above it. Both follow the world as the player
-- walks, which is what says they are placed every frame and not once.
core.register_on_joinplayer(function(player)
	core.after(4, function()
		if not (player and player:is_player()) then
			return
		end
		local p = player:get_pos()
		local d = player:get_look_dir()
		local wp = {x = p.x + d.x * 8, y = p.y + 1.6 + d.y * 8,
				z = p.z + d.z * 8}
		player:hud_add({
			hud_elem_type = "waypoint",
			name = "ahead ",
			text = "m",
			number = 0xFFFF00,
			world_pos = wp,
			-- Whole metres, to say that the precision reaches the client:
			-- it travels in the item field, as Luanti's own does
			precision = 1,
		})
		player:hud_add({
			hud_elem_type = "image_waypoint",
			text = "heart.png",
			scale = {x = 3, y = 3},
			world_pos = {x = wp.x, y = wp.y + 1, z = wp.z},
		})
		core.log("action", "waypoint check: a label and a picture at " ..
				core.pos_to_string(wp))
	end)
end)
