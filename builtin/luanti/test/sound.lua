-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- **Does a sound the server asks for reach the speakers** ([NO_SOUND]):
-- the room was silent because it placed no listener, and devtest is
-- silent for a reason nobody has found yet. Digging and placing are no
-- probe -- official Luanti plays those client-side off the player's own
-- action and this tree does not implement them at all -- so this asks
-- for the one thing that is unambiguously a packet: core.sound_play().
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=sound_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/sound.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- devtest's soundstuff mod ships soundstuff_mono.ogg, which is what is
-- asked for: one at the player, one positional beside them, one looped.
-- The client's own line for each is "luanti:sound: <name> ..." at log
-- level 4.
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	-- Every four seconds, not once: a run that has to catch a single
	-- one-second sound is a run that mostly misses it
	local function ask()
		local at = player:get_pos()
		core.sound_play({name = "soundstuff_mono"}, {to_player = name})
		core.sound_play({name = "soundstuff_mono"},
				{pos = {x = at.x, y = at.y, z = at.z}, max_hear_distance = 32})
		local h = core.sound_play({name = "soundstuff_mono"},
				{to_player = name, loop = true})
		core.log("action", "sound check: three asked for, handle " ..
				tostring(h))
		core.after(3, function()
			core.sound_stop(h)
			core.log("action", "sound check: the looped one stopped")
		end)
		core.after(4, ask)
	end
	core.after(2, ask)
end)
