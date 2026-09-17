-- Does VoxeLibre get its trees? They are schematic decorations placed on
-- "group:grass_block", and a chunk with grass and no trees is the fault
-- [NO_TREES] found.
--
--   BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=vltree \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/vltree.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- The spawn chunks generate without a client; a line per chunk says:
--
--   vltree: chunk (64,0,0) tree=8 grass=452
core.register_on_generated(function(minp, maxp)
	local _, c = core.find_nodes_in_area(minp, maxp,
			{"mcl_core:tree", "mcl_core:dirt_with_grass"})
	core.log("action", "vltree: chunk " .. core.pos_to_string(minp) ..
			" tree=" .. (c["mcl_core:tree"] or 0) ..
			" grass=" .. (c["mcl_core:dirt_with_grass"] or 0))
end)
