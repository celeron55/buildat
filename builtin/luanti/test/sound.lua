-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Do the sounds a game plays reach the player?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=sound_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/sound.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user \
--   -o sound_mute=0
--
-- The client mutes the sound by default, so it is worth saying so on the
-- command line: the mute is the user's own preference and neither a game
-- nor this check may write it.
--
-- Three sounds, out of the two devtest ships: one in the player's own head
-- when they join, one at the node every time one is dug -- which is the one
-- that has to get quieter as the player walks away from it -- and a looping
-- one that fades in, is faded out ten seconds later and stops itself there.
--
-- The server logs each play and the client logs a sound it has no file for.
-- A client run at -l 5 says what it started, which is what says a sound
-- arrived and played at all:
--
--   D luanti : luanti:sound: soundstuff_mono.ogg gain 1 local
--   D luanti : luanti:sound: soundstuff_sinus.ogg gain 0 local
--   D luanti : luanti:sound: soundstuff_mono.ogg gain 1 pos
--
-- The looping one starts at gain 0 because it fades in.
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.sound_play("soundstuff_mono", {to_player = name}, true)
	core.log("action", "sound check: a sound in " .. name .. "'s own head")
	local handle = core.sound_play("soundstuff_sinus", {
		to_player = name,
		loop = true,
		gain = 0.5,
		fade = 0.5,
	})
	core.log("action", "sound check: a looping sound, handle " ..
			tostring(handle))
	if handle then
		core.after(10, function()
			core.sound_fade(handle, 0.5, 0)
			core.log("action", "sound check: the looping one is fading out")
		end)
	end
end)

core.register_on_dignode(function(pos, node, digger)
	core.sound_play("soundstuff_mono", {
		pos = pos,
		gain = 1.0,
		max_hear_distance = 32,
	}, true)
	core.log("action", "sound check: a dig at " .. core.pos_to_string(pos))
end)
