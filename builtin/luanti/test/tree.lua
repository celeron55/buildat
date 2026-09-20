-- Do the L-system trees grow?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=tree_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/tree.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- Two ways in, and this checks both. core.spawn_tree() puts one in the map
-- beside the player when they join and counts what came out of it:
--
--   tree check: spawn_tree made 47 trunk and 210 leaves
--
-- and an lsystem decoration puts them in every chunk the mapgen makes, which
-- is the half that runs on the generator's thread through the vendored
-- treegen. Walk about and look; the log says how many are within sight of
-- the player every ten seconds.
--
-- The definition is devtest's own, out of its testitems mod's tree spawner.
local tree_def = {
	axiom = "Af",
	rules_a = "TT[&GB][&+GB][&++GB][&+++GB]A",
	rules_b = "[+GB]fB",
	trunk = "basenodes:tree",
	leaves = "basenodes:leaves",
	angle = 90,
	iterations = 4,
	trunk_type = "single",
	thin_branches = true,
}

core.register_on_mods_loaded(function()
	core.register_decoration({
		name = "tree_check:lsystem",
		deco_type = "lsystem",
		place_on = {"mapgen_dirt_with_grass", "mapgen_dirt", "mapgen_stone"},
		sidelen = 16,
		fill_ratio = 0.005,
		y_min = 1,
		y_max = 128,
		treedef = tree_def,
	})
	core.log("action", "tree check: an lsystem decoration is registered")
end)

local function count_around(pos, radius)
	local p1 = vector.subtract(pos, radius)
	local p2 = vector.add(pos, radius)
	local _, counts = core.find_nodes_in_area(p1, p2,
			{"basenodes:tree", "basenodes:leaves"})
	return counts["basenodes:tree"] or 0, counts["basenodes:leaves"] or 0
end

core.register_on_joinplayer(function(player)
	core.after(4, function()
		local p = vector.round(player:get_pos())
		local at = {x = p.x + 5, y = p.y, z = p.z}
		core.spawn_tree(at, tree_def)
		local trunk, leaves = count_around(at, 12)
		core.log("action", "tree check: spawn_tree made " .. trunk ..
				" trunk and " .. leaves .. " leaves")
		assert(trunk > 0 and leaves > 0, "spawn_tree grew nothing")
	end)
	local left = 12
	local function again()
		if not (player and player:is_player()) then
			return
		end
		local trunk, leaves = count_around(vector.round(player:get_pos()), 40)
		core.log("action", "tree check: " .. trunk .. " trunk and " ..
				leaves .. " leaves within forty nodes")
		left = left - 1
		if left > 0 then
			core.after(10, again)
		end
	end
	core.after(14, again)
end)
