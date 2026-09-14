-- What a game says is in its sky: Luanti's set_sun, set_moon and set_stars,
-- and the colours of the hours in set_sky. Half of this asserts and half of
-- it is to be looked at.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=sky_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/sky.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Connect a client and look up: it is midnight, the sky is dark, and the
-- stars are red and far too many, which is what says the count and the
-- colour arrived. The moon goes out after ten seconds and comes back ten
-- seconds later.
core.register_on_joinplayer(function(player)
	core.after(3, function()
		if not (player and player:is_player()) then
			return
		end
		core.set_timeofday(0.0)

		-- What a mod reads back is what it set, over Luanti's own defaults
		local sun = player:get_sun()
		assert(sun.visible == true and sun.scale == 1 and
				sun.texture == "sun.png",
				"get_sun() is not Luanti's default")
		assert(player:get_stars().count == 1000,
				"get_stars() is not Luanti's default")
		player:set_sun({visible = true, scale = 2})
		assert(player:get_sun().scale == 2, "set_sun() did not stick")
		player:set_stars({visible = true, count = 20000,
				star_color = "#ff4040"})
		local stars = player:get_stars()
		assert(stars.count == 20000 and stars.star_color == "#ff4040",
				"set_stars() did not stick")
		core.log("action", "sky check: the getters answer what was set")

		core.after(10, function()
			player:set_moon({visible = false})
			core.log("action", "sky check: the moon is gone")
			core.after(10, function()
				player:set_moon({visible = true, scale = 3})
				core.log("action", "sky check: the moon is back, larger")
			end)
		end)
	end)
end)
