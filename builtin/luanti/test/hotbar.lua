-- What a game says about the client's own hotbar: how many slots, the
-- picture behind them and the one that marks the slot in hand. Half of this
-- asserts and half of it is to be looked at.
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=hotbar_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/hotbar.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Connect a client and look at the bottom of the screen: there are twelve
-- slots rather than the eight a game that says nothing gets, the slot in
-- hand is marked with a heart rather than with the client's own lighter
-- box, and the keys 1-9 and the wheel move the mark. After ten seconds the
-- game asks for four slots and no mark, and the bar becomes four slots with
-- the client's own box on the one in hand.
core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	inv:set_size("main", 32)

	-- What a mod reads back is what it set, and a count is clamped to the
	-- list behind it the way Luanti clamps it
	player:hud_set_hotbar_itemcount(12)
	assert(player:hud_get_hotbar_itemcount() == 12,
			"hud_set_hotbar_itemcount() did not stick")
	player:hud_set_hotbar_itemcount(100)
	assert(player:hud_get_hotbar_itemcount() == 32,
			"a count past the list was not clamped to it")
	player:hud_set_hotbar_itemcount(12)

	player:hud_set_hotbar_image("default_dirt.png")
	assert(player:hud_get_hotbar_image() == "default_dirt.png",
			"hud_set_hotbar_image() did not stick")
	player:hud_set_hotbar_selected_image("heart.png")
	assert(player:hud_get_hotbar_selected_image() == "heart.png",
			"hud_set_hotbar_selected_image() did not stick")
	core.log("action", "hotbar check: the getters answer what was set")

	-- Something to hold, so that the mark has something to be over
	inv:set_stack("main", 1, ItemStack("basenodes:dirt 10"))
	inv:set_stack("main", 3, ItemStack("basenodes:stone 5"))

	core.after(10, function()
		if not (player and player:is_player()) then
			return
		end
		player:hud_set_hotbar_itemcount(4)
		player:hud_set_hotbar_selected_image("")
		core.log("action", "hotbar check: four slots and no mark now")
	end)
end)
