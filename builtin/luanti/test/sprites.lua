-- [FEATURE_SWEEP] set_sprite: an XP orb (VoxeLibre's sheet of fourteen,
-- one frame shown) and a sheet entity of this fixture's own at frame 2 of
-- 4 -- the same stage as connected.lua, the shot local/sprites/mobs.png
core.register_entity(":sprites:sheet", {
	initial_properties = {
		visual = "sprite", visual_size = {x = 1, y = 1},
		textures = {"mcl_experience_orb.png"}, spritediv = {x = 1, y = 14},
		physical = false, pointable = false,
	},
	on_activate = function(self)
		-- The eighth frame: green, where the first is yellow
		self.object:set_sprite({x = 0, y = 7})
	end,
})

core.register_on_joinplayer(function(player)
	core.after(6, function()
		local p = player:get_pos()
		local base = {x = math.floor(p.x), y = math.floor(p.y) + 4, z = math.floor(p.z)}
		for y = base.y, base.y + 60 do
			local clear = true
			for dz = -6, 6 do
				for dx = -8, 6 do
					for dy = -1, 3 do
						if core.get_node({x = base.x + dx, y = y + dy,
								z = base.z + dz}).name ~= "air" then
							clear = false
						end
					end
				end
			end
			if clear then
				base.y = y
				break
			end
		end
		for dz = -6, 6 do
			for dx = -8, 6 do
				core.set_node({x = base.x + dx, y = base.y - 1, z = base.z + dz},
						{name = "mcl_core:stone"})
			end
		end
		core.add_entity({x = base.x, y = base.y + 1, z = base.z}, "sprites:sheet")
		core.add_entity({x = base.x + 2, y = base.y + 1, z = base.z}, "mcl_experience:orb",
				core.serialize({xp = 5}))
		player:set_pos({x = base.x - 4, y = base.y + 0.5, z = base.z})
		core.log("action", "sprites: the sheet and the orb are placed")
	end)
end)
