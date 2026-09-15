-- The second reference world's four viewpoints, for comparing this module
-- against official Luanti.
--
--   rm -rf ../user/games/luanti_launcher/saves/refviews
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=refviews \
--   BUILDAT_LUANTI_IMPORT=~/projects/luanti/worlds/mc2_2026-09-15_0033 \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/reference_views.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Then a client with F5 on, shooting every twenty-five seconds or so: each
-- viewpoint is held for thirty, so a shot lands inside one of them whatever
-- the client's own clock says, and **the status row in the picture says
-- which one it is** -- and that the world was imported rather than
-- generated, the seed being 2845188330406634615.
--
-- The four are in doc/plan/luanti_module_plan.md, "The second reference
-- world"; see [REFERENCE_WORLD] and [TOO_BRIGHT] in
-- doc/plan/master_plan.md for what they are compared for.

-- The second reference world's four viewpoints, held thirty seconds each and
-- cycled, so that a client shooting on its own clock lands inside one of
-- them. Each picture says which it is: the status row carries the position
-- and the yaw, which is what the row is for.
--
-- The numbers are the status row's own, out of
-- doc/plan/luanti_module_plan.md. Luanti's look_h is measured the way
-- get_look_horizontal() means it, so it is the row's yaw in radians; its
-- look_v is positive downwards where the row prints positive up, so it is
-- the row's pitch negated. Setting the look first and the position second is
-- what sends both: tell_the_client() goes with set_pos().
local VIEWS = {
	{pos = {x = 319.0, y = 17.5, z = -302.0}, yaw = 273.5, pitch = -6.6},
	{pos = {x = 321.6, y = 17.5, z = -314.3}, yaw = 330.9, pitch = -1.9},
	{pos = {x = 375.1, y = 1.5, z = -351.6}, yaw = 91.1, pitch = -1.4},
	{pos = {x = 432.3, y = 54.5, z = -213.9}, yaw = 223.9, pitch = -5.8},
}

core.register_on_joinplayer(function(player)
	local function show(i)
		if not (player and player:is_player()) then
			return
		end
		local v = VIEWS[(i - 1) % #VIEWS + 1]
		player:set_look_horizontal(math.rad(v.yaw))
		player:set_look_vertical(math.rad(-v.pitch))
		player:set_pos(v.pos)
		core.log("action", "PROBE viewpoint " .. ((i - 1) % #VIEWS + 1) ..
				" at " .. v.pos.x .. "," .. v.pos.y .. "," .. v.pos.z)
		core.after(30, function() show(i + 1) end)
	end
	core.after(10, function() show(1) end)
end)
