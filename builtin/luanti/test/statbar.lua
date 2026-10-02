-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- A row of icons on the HUD: Luanti's statbar, which is what a game's
-- health, hunger and breath are drawn as.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=statbar_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/statbar.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- Connect a client and look above the hotbar. Three things have to hold,
-- and each one was wrong at some point:
--
-- 1. **The two rows at the top line up with each other**, left edge over
--    left edge, although one asks for align -1 and the other for +1.
--    Luanti's drawStatbar() is handed the element's pos and offset and
--    nothing else, so align changes nothing -- and reading it slid a
--    VoxeLibre health bar a whole row to the left.
-- 2. **A square is 24 screen pixels across**, whatever the window is,
--    because the size a game gives is in Luanti's own screen pixels and
--    is scaled the way every other number it gives is. Ten of them are
--    240 pixels, which is the width of the row below the hearts.
-- 3. **The half squares are cut the way the row runs**: the row running
--    right keeps the left half of its last icon and the one running left
--    keeps the right half, and the dark half beside it is the other half
--    of the "lost" picture rather than a hole.
--
-- The engine's own `heart_gone.png` is one transparent pixel -- a
-- placeholder for a game to override -- so the lost squares are drawn here
-- with a darkened heart instead, which is also what says the texture
-- modifiers reach a statbar.
core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		local function bar(e)
			e.hud_elem_type = "statbar"
			e.position = {x = 0.5, y = 1}
			e.text = "heart.png"
			e.text2 = "heart.png^[colorize:#000000:200"
			e.size = {x = 24, y = 24}
			e.item = 20
			player:hud_add(e)
		end
		-- 1. The same place from two alignments: one over the other
		bar({number = 20, direction = 0, offset = {x = -256, y = -180},
				alignment = {x = -1, y = -1}})
		bar({number = 20, direction = 0, offset = {x = -256, y = -150},
				alignment = {x = 1, y = 1}})
		-- 2 and 3. The two halves of a Luanti HUD: a row running right
		-- from 256 pixels left of the middle, and one running left from
		-- 232 pixels right of it, which is where VoxeLibre puts its own
		-- two. Both hold an odd number, so both end in half an icon.
		bar({number = 13, direction = 0, offset = {x = -256, y = -120},
				alignment = {x = -1, y = -1}})
		bar({number = 13, direction = 1, offset = {x = 232, y = -120},
				alignment = {x = 1, y = -1}})
		core.log("action", "statbar check: four rows added")
	end)
end)
