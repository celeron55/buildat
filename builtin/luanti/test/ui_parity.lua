-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [UI_PARITY] 1 and 2: boxes and a list's slots at known units, in
-- legacy and in real coordinates
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
}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	player:get_inventory():set_list("main", {})
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
end)
