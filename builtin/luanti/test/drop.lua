-- Does the drop key put what is held into the world?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=drop_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/drop.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- The player joins holding ten dirt. Press Q and the whole stack goes;
-- press Ctrl-Q and one of it does. The line this logs every second says
-- what is in hand and how many item entities are around the player, so the
-- two numbers move together:
--
--   drop check: holding "basenodes:dirt 10", 0 items nearby
--   drop check: holding "basenodes:dirt 9", 1 items nearby
--   drop check: holding "", 2 items nearby
core.register_on_joinplayer(function(player)
	player:get_inventory():set_stack("main", 1, "basenodes:dirt 10")
	core.log("action", "drop check: ten dirt in the first slot")
end)

local function watch()
	core.after(1, watch)
	for _, player in ipairs(core.get_connected_players()) do
		local items = 0
		for _, obj in ipairs(core.get_objects_inside_radius(
				player:get_pos(), 8)) do
			local le = obj:get_luaentity()
			if le and le.name == "__builtin:item" then
				items = items + 1
			end
		end
		core.log("action", "drop check: holding \"" ..
				player:get_wielded_item():to_string() .. "\", " .. items ..
				" items nearby")
	end
end
core.after(1, watch)
