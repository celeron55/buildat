-- Plantlike shapes ([PLANT_SIZE]): a row of plants on the mobmesh stage,
-- a flower (the x), a crop at each meshoptions shape and the 1.4x bit,
-- for a shot against official's drawPlantlike.
--
--   FIXTURE=plants builtin/luanti/test/mobmesh.sh
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
						{name = "mcl_core:dirt"})
			end
		end
		-- The x, then the crop at shapes 0..4, then the crop at 16 + 3
		core.set_node({x = base.x, y = base.y, z = base.z - 4}, {name = "mcl_flowers:poppy"})
		for i = 0, 4 do
			core.set_node({x = base.x, y = base.y, z = base.z - 3 + i},
					{name = "mcl_farming:beetroot_2", param2 = i})
		end
		core.set_node({x = base.x, y = base.y, z = base.z + 3},
				{name = "mcl_farming:beetroot_2", param2 = 16 + 3})
		player:set_pos({x = base.x - 5, y = base.y + 1.5, z = base.z})
		core.log("action", "plants: the row is placed")
	end)
end)
