-- [THIRD_PERSON]: the stage for camera.sh -- the player on a stone floor
-- with a wall two nodes behind them, so the third-person camera from
-- behind has something to be pulled in by, and open ground ahead for the
-- front view
core.register_on_joinplayer(function(player)
	core.after(6, function()
		local p = player:get_pos()
		local base = {x = math.floor(p.x), y = math.floor(p.y) + 30, z = math.floor(p.z)}
		for dz = -6, 6 do
			for dx = -6, 6 do
				for dy = -1, 4 do
					core.set_node({x = base.x + dx, y = base.y + dy, z = base.z + dz},
							{name = dy == -1 and "mcl_core:stone" or "air"})
				end
			end
		end
		-- The wall, two nodes behind a player looking along +z
		for dx = -6, 6 do
			for dy = 0, 3 do
				core.set_node({x = base.x + dx, y = base.y + dy, z = base.z - 2},
						{name = "mcl_core:stone"})
			end
		end
		player:set_pos({x = base.x, y = base.y + 0.5, z = base.z})
		player:set_look_horizontal(0)
		player:set_look_vertical(0)
		-- The zoom key wants a zoom_fov ([VIEW_KEYS]); official's creative
		-- default
		player:set_properties({zoom_fov = 15})
		core.log("action", "camera: the floor and the wall are placed")
	end)
end)
