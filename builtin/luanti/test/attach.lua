-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Does what is attached to something go where that something goes?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=attach_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/attach.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- A cube is attached to the player four and a half nodes over their head and
-- follows them as they walk; a second one is attached to the first, a node
-- and a half to one side, so the chain is followed rather than one link of
-- it. **The offsets are in Luanti's own units, ten to the node**, which is
-- why they read 45 and 15 -- and why an offset of 20 puts a cube inside the
-- player's own eyes rather than over their head.
--
-- Look up while walking: both follow. What the log says is where the player
-- is and where the rider's own position is, and those two stay the same --
-- an attached object keeps the position it was given and is *drawn* at its
-- parent's, which is what Luanti does too.
--
-- What this is not: the model bending at a bone, which is M5's other half.
-- Nothing here rotates with its parent either.
core.register_entity(":attach_check:rider", {
	initial_properties = {
		visual = "cube",
		textures = {"heart.png", "heart.png", "heart.png", "heart.png",
				"heart.png", "heart.png"},
		collisionbox = {-0.3, -0.3, -0.3, 0.3, 0.3, 0.3},
		physical = false,
		static_save = false,
	},
})

core.register_on_joinplayer(function(player)
	core.after(4, function()
		local p = player:get_pos()
		local first = core.add_entity(p, "attach_check:rider")
		local second = core.add_entity(p, "attach_check:rider")
		if first == nil or second == nil then
			return
		end
		first:set_attach(player, "", {x = 0, y = 45, z = 0})
		second:set_attach(first, "", {x = 15, y = 0, z = 0})
		core.log("action", "attach check: one on the player, one on that")
		assert(first:get_attach() == player, "the first is not attached")
		assert(second:get_attach() == first, "the second is not attached")
		local children = player:get_children()
		assert(#children == 1 and children[1] == first,
				"the player has no child")
		local left = 20
		local function say()
			if not (player and player:is_player()) then
				return
			end
			core.log("action", "attach check: player " ..
					core.pos_to_string(vector.round(player:get_pos())) ..
					", rider " .. core.pos_to_string(
					vector.round(first:get_pos())))
			left = left - 1
			if left > 0 then
				core.after(2, say)
			end
		end
		say()
	end)
end)
