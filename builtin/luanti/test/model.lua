-- Is a formspec's model[] element drawn?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=model_form_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/model.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- A form comes up four seconds after joining with three models in it: the
-- spider unturned, the snowman turned a quarter around, and a frog in a tall
-- box rather than a square one, which is what says the camera is put back
-- far enough for the narrow way of the element. A mesh nothing shipped is
-- the fourth, and what it leaves is an empty place rather than a black
-- square or a crash.
--
-- What the log says on the way is which models the client asked for:
--
--   C1: model "gltf_spider.gltf": 500 quads
--   luanti:model: gltf_spider.gltf, 500 quads
core.register_on_joinplayer(function(player)
	core.after(4, function()
		if not (player and player:is_player()) then
			return
		end
		core.show_formspec(player:get_player_name(), "model:check",
				"formspec_version[4]" ..
				"size[14,7]" ..
				"label[0.4,0.5;A mesh, a turn, and a tall box]" ..
				"model[0.4,1;4,4;spider;gltf_spider.gltf;gltf_spider.png;" ..
						"0,0;false;false;0,0;0]" ..
				"model[5,1;4,4;snowman;gltf_snow_man.gltf;" ..
						"gltf_snow_man.png;0,90;false;false;0,0;0]" ..
				"model[9.5,1;1.5,5;frog;gltf_frog.gltf;gltf_frog.png;" ..
						"0,180;false;false;0,0;0]" ..
				"model[11.5,1;2,2;nothing;no_such_model.gltf;none.png;" ..
						"0,0;false;false;0,0;0]" ..
				"button_exit[5,5.6;4,1;close;Close]")
		core.log("action", "model check: the form is up")
	end)
end)
