-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [MENU_MUSIC]: one looped sound to the player, as a game's music is, and
-- never stopped by the game -- what is left playing after a leave is the
-- client's to stop. devtest's soundstuff_mono.ogg; see menu_music.sh.
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	core.after(2, function()
		local h = core.sound_play({name = "soundstuff_mono"},
				{to_player = name, loop = true})
		core.log("action", "menu music: looping, handle " .. tostring(h))
	end)
end)
