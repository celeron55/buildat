-- [DIG_PARITY]: a server-only reading of an item dropped into a one-node
-- hole in a dirt platform at y 120, its y logged four times a second for
-- three seconds; no player, so objects are made active everywhere.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_LUA=builtin/luanti/test/fall.lua \
--       bin/buildat_server -m ../games/vanilla -D ../user -P 29791
core.register_on_mods_loaded(function()
	core.after(4, function()
		local O = {x = 0, y = 120, z = 0}
		core.forceload_block(O); core.__active_everywhere = true
		for x = -3, 3 do for z = -3, 3 do
			core.set_node({x = O.x + x, y = O.y, z = O.z + z}, {name = "mcl_core:dirt"})
		end end
		core.set_node(O, {name = "air"})
		local obj = core.add_item({x = 0, y = 120.5, z = 0}, "mcl_core:dirt")
		local t = 0
		local function watch()
			t = t + 0.25
			local p = obj and obj:get_pos()
			local seen = {}
			for _, o in ipairs(core.get_objects_inside_radius(O, 200)) do
				local q = o:get_pos()
				seen[#seen + 1] = string.format("%s@%.1f", (o:get_luaentity() or {}).name or "?", q.y)
			end
			core.log("warning", string.format("fallcheck: t=%.2f y=%s at_item=%s active=%s loaded=%d objs=%s", t,
					p and string.format("%.2f", p.y) or "gone",
					p and core.get_node(p).name or "-", p and tostring(core.__is_active(p)) or "-",
					#core.get_loaded_blocks(), table.concat(seen, " "),
					core.get_node({x = 0, y = 119, z = 0}).name, core.get_node(O).name, ""))
			if t < 3 then core.after(0.25, watch) end
		end
		watch()
	end)
end)
