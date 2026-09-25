-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [CAVE_AO]: a chamber deep underground where both nibbles are nought, with
-- the shapes the complaint is about -- a pillar, a ledge, a recess and the
-- corners between them. With no light of its own the place is one flat
-- black and the voxels have no edges; the ladder asks how much of a
-- constant floor under the ambient gives them back.
--
-- A torch in one corner is the other half: the lamp term already takes the
-- local shade, so a torch-lit corner should darken the way a sunlit one
-- does, and this is where that is looked at.
core.settings:set("fixed_map_seed", "5")

local BASE = {x = 200, z = 200}
local room = nil

local function solid_top(x, z)
	for y = 120, -40, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" then
			return y
		end
	end
	return nil
end

local function fill(from, to, name)
	for x = from.x, to.x do
		for y = from.y, to.y do
			for z = from.z, to.z do
				core.set_node({x = x, y = y, z = z}, {name = name})
			end
		end
	end
end

local function build()
	local top = solid_top(BASE.x, BASE.z)
	if not top then
		return false
	end
	-- Deep enough that no ray out of it reaches the sky and the skylight
	-- flood is nought throughout
	room = {x = BASE.x, y = top - 20, z = BASE.z}
	local r = room
	fill({x = r.x - 6, y = r.y, z = r.z - 6},
			{x = r.x + 6, y = r.y + 4, z = r.z + 6}, "air")
	-- A pillar in the middle: four faces, eight vertical edges, which is
	-- what "the voxels lose their edges" is about
	fill({x = r.x - 1, y = r.y, z = r.z - 1},
			{x = r.x, y = r.y + 4, z = r.z}, "mcl_core:stone")
	-- A ledge along the far wall, so there is a horizontal edge too
	fill({x = r.x - 6, y = r.y, z = r.z + 4},
			{x = r.x + 6, y = r.y + 1, z = r.z + 6}, "mcl_core:stone")
	-- And a recess in the near left wall: a corner that faces away from
	-- everything
	fill({x = r.x - 8, y = r.y, z = r.z - 3},
			{x = r.x - 7, y = r.y + 2, z = r.z - 1}, "air")
	return true
end

core.register_on_joinplayer(function(player)
	core.settings:set("time_speed", "0")
	core.after(6, function()
		if not build() then
			core.chat_send_all("cave_ao: done")
			return
		end
		core.set_timeofday(0.5417)
		-- At one end, looking across the pillar at the ledge
		player:set_pos({x = room.x + 0.5, y = room.y + 0.1,
				z = room.z - 5.5})
		player:set_look_horizontal(0)
		player:set_look_vertical(0)
		-- Two pictures out of one run: the chamber with no light in it at
		-- all, which is what the complaint is about, and then the same
		-- chamber with a torch, which is where the lamp term's own shading
		-- is looked at. A torch placed at the start lights the whole room
		-- and there is no dark case left to judge.
		local function settled(what, next_step)
			local last = nil
			local function settle()
				local n = core.get_node({x = room.x + 3, y = room.y + 1,
						z = room.z})
				local key = math.floor((n.param1 or 0) % 16) * 16 +
						math.floor((n.param1 or 0) / 16) % 16
				if last == key then
					core.chat_send_all("cave_ao: ready " .. what ..
							" sky " .. math.floor((n.param1 or 0) % 16) ..
							" lamp " ..
							math.floor((n.param1 or 0) / 16) % 16)
					if next_step then
						core.after(12, next_step)
					end
					return
				end
				last = key
				core.after(4, settle)
			end
			core.after(8, settle)
		end
		settled("dark", function()
			-- On the pillar's near face, which is the face the camera sees
			core.set_node({x = room.x, y = room.y + 2, z = room.z - 2},
					{name = "mcl_torches:torch"})
			settled("torch", nil)
		end)
	end)
end)
