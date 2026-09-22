-- [DARK_INVARIANT]'s two probe pairs, both carved into real terrain at
-- fixed places in a world of a fixed seed, so the rock around them is the
-- same every run.
--
-- **sealed**: a room deep inside stone with no opening at all. No ray from
-- any surface in it reaches the sky, so nothing the sky does may reach it:
-- the picture at 02:00 and the picture at 13:00 have to be the same one.
--
-- **mouth**: the same room, but with a corridor out of its far side and a
-- shaft from the corridor's end up to daylight. The camera looks the other
-- way, at a wall with no sky in sight and both nibbles nought, whose rays
-- still reach the mouth around a corner -- and that wall *must* follow the
-- hour. A fix that passes the sealed pair by killing the ray term fails
-- this one, which is the whole reason the pair is a pair.
core.settings:set("fixed_map_seed", "5")

local BASE = {x = 200, z = 200}
-- Far enough that the shaft's daylight reaches nothing of the sealed room:
-- different chunks, and sixty nodes of rock between them
local MOUTH_BASE = {x = 260, z = 200}
local room = nil
local mouth = nil

local function solid_top(x, z)
	for y = 120, -40, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" then
			return y
		end
	end
	return nil
end

local function carve_room(at)
	for dx = -3, 3 do
		for dz = -2, 2 do
			for dy = 0, 2 do
				core.set_node({x = at.x + dx, y = at.y + dy,
						z = at.z + dz}, {name = "air"})
			end
		end
	end
end

local function build()
	local top = solid_top(BASE.x, BASE.z)
	if not top then
		return false
	end
	-- Deep enough that the rock above is many nodes of it, and the room
	-- itself sealed: every voxel around it stays as the mapgen left it
	room = {x = BASE.x, y = top - 25, z = BASE.z}
	carve_room(room)

	local mtop = solid_top(MOUTH_BASE.x, MOUTH_BASE.z)
	if not mtop then
		return false
	end
	mouth = {x = MOUTH_BASE.x, y = mtop - 25, z = MOUTH_BASE.z}
	carve_room(mouth)
	-- Out of the room's -x side, then straight up to the sky. The camera
	-- in the room looks +z, so the corridor is behind it and the wall it
	-- reads has the mouth around a corner rather than in sight.
	local sx = mouth.x - 10
	for x = mouth.x - 4, sx, -1 do
		for dy = 0, 1 do
			core.set_node({x = x, y = mouth.y + dy, z = mouth.z},
					{name = "air"})
		end
	end
	for y = mouth.y, mtop + 1 do
		core.set_node({x = sx, y = y, z = mouth.z}, {name = "air"})
	end
	return true
end

-- Every hour at every spot: four pictures, two pairs
-- Grouped by place, not by hour: the pbr path's auto-exposure meter takes
-- a while to settle, and a pair whose two shots straddle a walk from a
-- daylit room to a sealed one reads the meter's travel rather than the
-- light (194 against 85 on a wall that cannot see the sun, 2026-09-22).
-- Within a pair only the hour changes and the camera does not move.
local STOPS = {
	{"0200", 0.0833, "sealed"}, {"1300", 0.5417, "sealed"},
	{"0200", 0.0833, "mouth"}, {"1300", 0.5417, "mouth"},
}

local function place(player, spot)
	local at = (spot == "mouth") and mouth or room
	player:set_pos({x = at.x + 0.5, y = at.y + 0.1, z = at.z + 0.5})
	player:set_look_horizontal(0)
	player:set_look_vertical(0)
end

local function at(i, player)
	local s = STOPS[i]
	if not s then
		core.chat_send_all("dark: done")
		return
	end
	core.set_timeofday(s[2])
	place(player, s[3])
	local spot = (s[3] == "mouth") and mouth or room
	-- The hour is the sky's; what the place's own light does with it is
	-- the reading, so the nibbles are said with the picture
	local n = core.get_node({x = spot.x, y = spot.y + 1, z = spot.z})
	-- Long enough that the walk to the other room has been loaded, meshed
	-- and relit before the picture is asked for: a room read while its
	-- relight runs is a room half lit, and the first reading of this pair
	-- was one of those
	core.after(10, function()
		core.chat_send_all("dark: " .. s[3] .. " hour " .. s[1] ..
				" light " .. math.floor((n.param1 or 0) % 16) .. "/" ..
				math.floor((n.param1 or 0) / 16) % 16)
		core.after(6, function() at(i + 1, player) end)
	end)
end

core.register_on_joinplayer(function(player)
	core.settings:set("time_speed", "0")
	core.after(6, function()
		if not build() then
			core.chat_send_all("dark: done")
			return
		end
		place(player, "sealed")
		core.log("action", "dark: the sealed room is at " .. room.x ..
				"," .. room.y .. "," .. room.z .. ", the mouthed one at " ..
				mouth.x .. "," .. mouth.y .. "," .. mouth.z)
		-- Not before the light has settled: a section's relight is
		-- deferred, and a room read while it runs is a room half lit
		local last = nil
		local function settle()
			local n = core.get_node({x = room.x, y = room.y + 1,
					z = room.z})
			local sky = math.floor((n.param1 or 0) % 16)
			if last == sky then
				core.after(1, function() at(1, player) end)
				return
			end
			last = sky
			core.after(4, settle)
		end
		core.after(6, settle)
	end)
end)
