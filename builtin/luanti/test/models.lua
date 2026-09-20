-- Is an object drawn as its own model?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=model_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/models.lua \
--   bin/buildat_server -m ../games/vanilla -D ../user
--
-- Four of devtest's glTF test entities in a row four nodes in front of the
-- player, and the frog again as a node beside them. What the log says is the
-- model each one asked for and how many quads it came to:
--
--   C1: model "gltf_spider.gltf": 500 quads
--   luanti:model: gltf_spider.gltf, 500 quads
--
-- and what the screen shows is a spider, a snowman and a cube. **The sizes
-- are the models' own**: an object's mesh is authored in Luanti's units,
-- where a node is ten across, so the snowman's 24 units are 2.4 nodes and
-- the frog's 0.3 are hardly visible at all -- which is why devtest also
-- registers the frog as a node, where a unit is a node instead.
core.register_on_joinplayer(function(player)
	core.after(4, function()
		local p = player:get_pos()
		local kinds = {"gltf:frog", "gltf:snow_man", "gltf:spider",
				"gltf:blender_cube_glb"}
		for i, name in ipairs(kinds) do
			local at = {x = p.x + 4, y = p.y + 1, z = p.z + (i - 2) * 2}
			core.add_entity(at, name)
			core.log("action", "model check: " .. name .. " at " ..
					core.pos_to_string(at))
		end
		core.set_node({x = math.floor(p.x) + 4, y = math.floor(p.y),
				z = math.floor(p.z) - 4}, {name = "gltf:frog"})
		core.log("action", "model check: and a frog node")
	end)
end)
