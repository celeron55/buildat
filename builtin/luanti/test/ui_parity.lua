-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [UI_PARITY] 1 and 2: boxes and a list's slots at known units, in
-- legacy and in real coordinates; 3 to 5 the stacks; 7 a tooltip; 8 the
-- form's and the screen's colours and an auto_clip background9; 9 two HUD
-- texts of two lines, one centred on its point and one left of it
local FORMS = {
	legacy = "size[8,6]" ..
		"box[0,0;1,1;#ff0000]box[7,5;1,1;#00ff00]box[2,1;3,2;#0000ff]" ..
		"listcolors[#ff00ff;#ff00ff]list[current_player;main;0,3.5;8,1;]",
	real = "formspec_version[6]size[10.75,7.5]" ..
		"box[0,0;1,1;#ff0000]box[9.75,6.5;1,1;#00ff00]box[2,1;3,2;#0000ff]" ..
		"listcolors[#ff00ff;#ff00ff]list[current_player;main;0.375,4;8,1;]",
	-- 3 to 5: a node's cube, a count of one and of five and ninety-nine, a
	-- tool's wear bar, a craftitem's flat picture
	items = "formspec_version[6]size[10.75,3]" ..
		"box[0,0;1,1;#ff0000]box[9.75,2;1,1;#00ff00]" ..
		"listcolors[#ff00ff;#ff00ff]list[current_player;main;0.375,1;6,1;]",
	-- 7: a tooltip[] over the whole form in colours of its own, the
	-- cursor put in the middle of the screen
	tips = "formspec_version[6]size[10.75,3]" ..
		"box[0,0;1,1;#ff0000]box[9.75,2;1,1;#00ff00]" ..
		"tooltip[0,0;10.75,3;Tip text;#0000ff;#ffff00]",
	-- 8: bgcolor[] for the form and the screen, and a background9 half a
	-- unit inside the form by auto_clip
	bg = "formspec_version[6]size[10.75,3]" ..
		"bgcolor[#0000ff;both;#ffff00]" ..
		"background9[0.5,0.5;0,0;testformspec_bg_9slice.png;true;4,6]" ..
		"box[0,0;1,1;#ff0000ff]box[9.75,2;1,1;#00ff00ff]",
}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:get_inventory():set_list("main", {})
	player:hud_add({type = "text", position = {x = 0.3, y = 0.2},
			text = "II\nIIIIIIIIII", number = 0xFF00FF,
			alignment = {x = 0, y = 0}})
	player:hud_add({type = "text", position = {x = 0.8, y = 0.2},
			text = "II\nIIIIIIIIII", number = 0xFF00FF,
			alignment = {x = -1, y = 0}})
	core.after(4, function()
		core.show_formspec(name, "uip", FORMS.legacy)
		core.log("action", "UIP legacy")
	end)
	core.after(12, function()
		core.show_formspec(name, "uip", FORMS.real)
		core.log("action", "UIP real")
	end)
	core.after(20, function()
		local pick = ItemStack("basetools:pick_wood")
		pick:set_wear(32768)
		player:get_inventory():set_list("main", {"basenodes:dirt",
				"basenodes:dirt 5", "basenodes:dirt 99", pick,
				"testfood:good1", ""})
		core.show_formspec(name, "uip", FORMS.items)
		core.log("action", "UIP items")
	end)
	core.after(28, function()
		core.show_formspec(name, "uip", FORMS.tips)
		core.log("action", "UIP tips")
	end)
	core.after(36, function()
		core.show_formspec(name, "uip", FORMS.bg)
		core.log("action", "UIP bg")
	end)
end)
