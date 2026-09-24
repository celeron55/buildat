-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Is the dig held rather than clicked, and does the crack grow over it?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=dig_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/dig.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- Connect a client, take the third hotbar slot -- which is empty, so the
-- hand digs -- point at the ground and hold the left button. What the log
-- says is a punch when the button goes down and a dig about as long after
-- it as the hand takes on that node; devtest's hand is 0.70 s on
-- dirt_with_grass, which is what the client works out for itself out of
-- core.__dig_props(). A screenshot between the two has the crack on the
-- node under the selection box, and a second one further into the dig has
-- more of it.
--
-- The first two slots are a pick and a shovel, for the other half of it: a
-- pick digs no dirt at all, so holding the button on it punches once and
-- nothing else ever happens.
core.register_on_joinplayer(function(player)
	local inv = player:get_inventory()
	inv:set_stack("main", 1, "basetools:pick_steel")
	inv:set_stack("main", 2, "basetools:shovel_steel")
	core.log("action", "dig check: a pick in slot 1, a shovel in 2, the " ..
			"hand in 3")
end)

core.register_on_punchnode(function(pos, node, puncher)
	core.log("action", "dig check: punched " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)

core.register_on_dignode(function(pos, node, digger)
	core.log("action", "dig check: dug " .. node.name .. " at " ..
			core.pos_to_string(pos))
end)
