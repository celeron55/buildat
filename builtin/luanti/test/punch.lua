-- Is an object hit rather than dug?
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=punch_check \
--   BUILDAT_LUANTI_LUA=../builtin/luanti/test/punch.lua \
--   bin/buildat_server -m ../games/luanti_launcher -D ../user
--
-- Five targets in a row three nodes in front of the player, and a steel
-- sword in the first slot. Point at one and hold the left button: what the log
-- says is one punch every fifth of a second -- Luanti's own object_hit_delay
-- -- with the hit points going down by what the sword does to its armour
-- group, and "died" when they run out:
--
--   punch check: target punched by client1, 16 hp left
--   punch check: target punched by client1, 12 hp left
--   punch check: the target died
--
-- The node behind it is not dug meanwhile, which is the other half of it:
-- what the ray runs into first is what the button is about.
--
-- The middle one, straight ahead, is the same thing drawn as a model rather
-- than as a cube -- a frog the size of a thumb in a box a node across. It is there because a model is drawn at its own size and that is
-- not what it collides with: aiming by the drawn size missed every mob
-- VoxeLibre has, and a frog in a node-sized box is the smallest thing that
-- says so.
core.register_entity(":punch_check:target", {
	initial_properties = {
		visual = "cube",
		textures = {"heart.png", "heart.png", "heart.png", "heart.png",
				"heart.png", "heart.png"},
		collisionbox = {-0.5, 0, -0.5, 0.5, 1, 0.5},
		hp_max = 20,
		physical = false,
	},
	on_activate = function(self)
		self.object:set_armor_groups({fleshy = 100})
	end,
	on_punch = function(self, puncher, time_from_last_punch, caps, dir)
		core.log("action", "punch check: " .. self.name .. " punched by " ..
				(puncher and puncher:get_player_name() or "nobody") ..
				", " .. self.object:get_hp() .. " hp left, " ..
				string.format("%.2f", time_from_last_punch or 0) ..
				" s since the last")
	end,
	on_death = function(self)
		core.log("action", "punch check: " .. self.name .. " died")
	end,
})

-- The same target drawn as a model, and a small one: what is aimed at is
-- the box it collides with and not the size it is drawn at
local mesh_target = table.copy(core.registered_entities["punch_check:target"])
mesh_target.initial_properties = table.copy(
		mesh_target.initial_properties)
mesh_target.initial_properties.visual = "mesh"
mesh_target.initial_properties.mesh = "gltf_frog.gltf"
mesh_target.initial_properties.textures = {"gltf_frog.png"}
core.register_entity(":punch_check:model_target", mesh_target)

core.register_on_joinplayer(function(player)
	player:get_inventory():set_stack("main", 1, "basetools:sword_steel")
	core.after(4, function()
		local p = player:get_pos()
		-- The model is the one straight ahead, so that a look along +X
		-- with a little dip in it is aimed at it and at nothing else
		core.add_entity({x = p.x + 3, y = p.y, z = p.z},
				"punch_check:model_target")
		for _, dz in ipairs({-4, -2, 2, 4}) do
			core.add_entity({x = p.x + 3, y = p.y, z = p.z + dz},
					"punch_check:target")
		end
		core.log("action",
				"punch check: four targets, a frog and a steel sword")
	end)
end)
