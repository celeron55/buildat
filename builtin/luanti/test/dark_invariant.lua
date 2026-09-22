-- [DARK_INVARIANT]: a room carved deep inside stone with no opening at all.
-- No ray from any surface in it reaches the sky, so nothing the sky does may
-- reach it: the picture at 02:00 and the picture at 13:00 have to be the
-- same one.
--
-- Dug into real terrain at a fixed place in a world of a fixed seed, so the
-- rock around it is the same every run.
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

local function build()
	local top = solid_top(BASE.x, BASE.z)
	if not top then
		return false
	end
	-- Deep enough that the rock above is many nodes of it, and the room
	-- itself sealed: every voxel around it stays as the mapgen left it
	room = {x = BASE.x, y = top - 25, z = BASE.z}
	for dx = -3, 3 do
		for dz = -2, 2 do
			for dy = 0, 2 do
				core.set_node({x = room.x + dx, y = room.y + dy,
						z = room.z + dz}, {name = "air"})
			end
		end
	end
	return true
end

local HOURS = {{"0200", 0.0833}, {"1300", 0.5417}}

local function at(i)
	local h = HOURS[i]
	if not h then
		core.chat_send_all("dark: done")
		return
	end
	core.set_timeofday(h[2])
	-- The hour is the sky's; the room's own light is what must not follow
	-- it, so the light is read out and said with it
	local n = core.get_node({x = room.x, y = room.y + 1, z = room.z})
	core.chat_send_all("dark: hour " .. h[1] .. " light " ..
			math.floor((n.param1 or 0) % 16) .. "/" ..
			math.floor((n.param1 or 0) / 16) % 16)
	core.after(8, function() at(i + 1) end)
end

core.register_on_joinplayer(function(player)
	core.settings:set("time_speed", "0")
	core.after(6, function()
		if not build() then
			core.chat_send_all("dark: done")
			return
		end
		player:set_pos({x = room.x + 0.5, y = room.y + 0.1,
				z = room.z + 0.5})
		player:set_look_horizontal(0)
		player:set_look_vertical(0)
		core.log("action", "dark: the room is at " .. room.x .. "," ..
				room.y .. "," .. room.z)
		-- Not before the light has settled: a section's relight is
		-- deferred, and a room read while it runs is a room half lit
		local last = nil
		local function settle()
			local n = core.get_node({x = room.x, y = room.y + 1,
					z = room.z})
			local sky = math.floor((n.param1 or 0) % 16)
			if last == sky then
				core.after(1, function() at(1) end)
				return
			end
			last = sky
			core.after(4, settle)
		end
		core.after(6, settle)
	end)
end)
