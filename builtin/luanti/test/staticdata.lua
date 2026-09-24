-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Is an active object asked for its static data?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=static_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/staticdata.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- Luanti asks every active object for its static data every couple of
-- seconds, because that is what it writes into the block the object is in.
-- Nothing here writes it anywhere yet, and the asking still matters: a mod
-- is entitled to do its own bookkeeping in get_staticdata(), and VoxeLibre's
-- mobs stand still for ever without it -- a fresh mcl_mobs mob has no state
-- until get_staticdata() gives it one.
--
-- This asserts and says so in the log; nothing to look at.
core.register_entity(":staticdata_check:thing", {
	initial_properties = {
		visual = "cube",
		textures = {"heart.png", "heart.png", "heart.png", "heart.png",
				"heart.png", "heart.png"},
		physical = false,
		static_save = true,
	},
	get_staticdata = function(self)
		self.asked = (self.asked or 0) + 1
		return "asked " .. self.asked
	end,
})

core.register_on_joinplayer(function(player)
	core.after(2, function()
		if not (player and player:is_player()) then
			return
		end
		local obj = core.add_entity(player:get_pos(), "staticdata_check:thing")
		assert(obj, "the check's own entity would not spawn")
		core.after(7, function()
			local le = obj:get_luaentity()
			assert(le, "the check's own entity is gone")
			local asked = le.asked or 0
			assert(asked >= 2, "get_staticdata() was asked for " .. asked ..
					" times in seven seconds, which is not every couple")
			core.log("action", "staticdata check: asked " .. asked ..
					" times in seven seconds")
			obj:remove()
		end)
	end)
end)
