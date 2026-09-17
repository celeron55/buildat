-- Does a .mts schematic read and place? read_schematic() parses the file,
-- serialize_schematic(.., "lua") is what mcl_structures sizes a structure
-- by, and place_schematic() puts it in the world with its centering flag.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=schematic \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/schematic.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
--   schematic: desert well 5x7x5, 175 nodes read, 77 placed of 175
core.register_on_mods_loaded(function()
	-- After the mods, since the fixture itself runs before them
	local path = core.get_modpath("mcl_structures") ..
			"/schematics/mcl_structures_desert_well.mts"
	core.after(4, function()
		local t = core.read_schematic(path)
		assert(t and t.size and #t.data == t.size.x * t.size.y * t.size.z,
				"schematic: read")
		local lua = core.serialize_schematic(path, "lua")
		local s = (rawget(_G, "loadstring") or load)(lua .. " return schematic")()
		assert(s.size.x == t.size.x, "schematic: serialize")
		local pos = {x = 0, y = 200, z = 0}
		assert(core.place_schematic(pos, path, "0", nil, true,
				"place_center_x,place_center_z"), "schematic: place")
		local half = math.floor((t.size.x - 1) / 2)
		local _, counts = core.find_nodes_in_area(
				{x = -half, y = 200, z = -half},
				{x = -half + t.size.x - 1, y = 200 + t.size.y - 1,
				z = -half + t.size.z - 1}, {"mcl_core:sandstone"})
		local placed = 0
		for _, n in pairs(counts) do
			placed = placed + n
		end
		assert(placed > 0, "schematic: nothing solid was placed")
		core.log("action", string.format(
				"schematic: desert well %dx%dx%d, %d nodes read, %d placed of %d",
				t.size.x, t.size.y, t.size.z, #t.data, placed, #t.data))
		core.request_shutdown("schematic: done")
	end)
end)
