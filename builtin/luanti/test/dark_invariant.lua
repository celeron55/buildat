-- SPDX-License-Identifier: Apache-2.0 OR MIT
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
-- Far enough that the shaft's daylight reaches nothing of the sealed room
-- -- forty nodes of rock, against a flood that dies in fifteen and a ray
-- walk of at most thirty-two -- and at the sealed room's own depth, which
-- is rock the fixture has measured dark. Twenty-five nodes under its own
-- column put it in cave country and its wall read daylight 10 from a
-- neighbouring cave, which is the one thing this probe may not have.
-- East of the sealed room: west and north of it is seabed at seed 5, and
-- a shaft wants dry ground over it
local MOUTH_BASE = {x = 280, z = 200}
local room = nil
local mouth = nil
local shaft_z = nil
-- Which way the corridor runs: the camera looks the other way, so the
-- wall it reads is the one the corridor's rays come back along
local mouth_dir = -1

-- Water is not ground: a column whose top node is a pond reads its
-- surface as rock otherwise, and the shaft cut under it comes up inside
-- the water rather than in the open
local function liquid(name)
	local d = core.registered_nodes[name]
	return d and d.liquidtype and d.liquidtype ~= "none"
end

local function solid_top(x, z)
	for y = 120, -40, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" then
			return y
		end
	end
	return nil
end

-- The same, with water counted as the sky's side of the line: the shaft
-- wants a column of dry ground over it, and a seabed read as ground put
-- the room's own depth five nodes lower and inside a cave.
local function dry_top(x, z)
	for y = 120, -40, -1 do
		local n = core.get_node({x = x, y = y, z = z})
		if n.name ~= "air" and n.name ~= "ignore" and not liquid(n.name) then
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

	mouth = {x = MOUTH_BASE.x, y = room.y, z = MOUTH_BASE.z}
	-- Straight out of the room's -z side, then up to the sky. The camera
	-- stands in the middle looking +z, so the corridor runs away behind
	-- it and the sky is around a corner -- but the wall it reads faces
	-- -z, and **that** is why the corridor goes this way: the rays a
	-- face is asked about are its own hemisphere, and a corridor off a
	-- side wall is edge-on to it and contributes nothing. Cut out of the
	-- -x side the mouthed room read as dark as the sealed one at every
	-- hour, and the pair proved nothing.
	--
	-- Twenty-two nodes of it at least. The length is what kills the
	-- flood -- daylight loses a level a node, so over twenty-seven from
	-- the shaft there is none of it left on that wall -- while a ray
	-- straight down the corridor still survives a sixteen-node walk,
	-- which is the term under test, asked on a wall the flood never
	-- reaches.
	--
	-- The shaft climbs its own column, and that column has to be dry
	-- ground: west of here is seabed, and a shaft cut under a lake fills
	-- with the water, which stopped the daylight nine nodes down and
	-- left the room at the far end dark at both hours.
	local sz, mtop = nil, nil
	local tries = {}
	for d = 22, 40, 2 do
		tries[#tries + 1] = -d
		tries[#tries + 1] = d
	end
	for _, d in ipairs(tries) do
		local z = mouth.z + d
		local t = dry_top(mouth.x, z)
		local wet = t == nil
		for y = mouth.y, (t or mouth.y) + 2 do
			if liquid(core.get_node({x = mouth.x, y = y, z = z}).name) then
				wet = true
				break
			end
		end
		core.log("action", "dark: shaft candidate " .. z .. " ground " ..
				tostring(t) .. (wet and " wet" or " dry"))
		if not wet and t > mouth.y then
			sz, mtop, mouth_dir = z, t, (d > 0) and 1 or -1
			break
		end
	end
	if not sz then
		core.log("action", "dark: no dry column for the shaft")
		return false
	end
	shaft_z = sz
	core.log("action", "dark: the shaft is at z " .. sz .. ", ground " ..
			mtop .. ", " .. (mouth.z - sz) .. " nodes of corridor")
	local air = {}
	local function want(x, y, z)
		air[#air + 1] = {x = x, y = y, z = z}
		air[x .. "," .. y .. "," .. z] = true
	end
	for dx = -3, 3 do
		for dz = -2, 2 do
			for dy = 0, 2 do
				want(mouth.x + dx, mouth.y + dy, mouth.z + dz)
			end
		end
	end
	for z = mouth.z + 3 * mouth_dir, sz, mouth_dir do
		for dy = 0, 1 do
			want(mouth.x, mouth.y + dy, z)
		end
	end
	for y = mouth.y, mtop + 1 do
		want(mouth.x, y, sz)
	end
	-- Room and corridor are walled in before they are carved, every
	-- neighbour that was air turned to stone. Twenty-five nodes down is
	-- cave country: the first three cuts of this read daylight 10 on the
	-- wall the camera reads and it was never the corridor -- it was a
	-- mapgen cave next door, and the pair was measuring ordinary
	-- sunlight rather than the ray term, which is the trap this probe
	-- exists to avoid. Above mtop nothing is walled, or the shaft would
	-- be capped and the mouth would open on nothing.
	for _, at in ipairs(air) do
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					local x, y, z = at.x + dx, at.y + dy, at.z + dz
					local nn = core.get_node({x = x, y = y, z = z}).name
					if y < mtop and not air[x .. "," .. y .. "," .. z] and
							(nn == "air" or liquid(nn)) then
						core.set_node({x = x, y = y, z = z},
								{name = "mcl_core:stone"})
					end
				end
			end
		end
	end
	for _, at in ipairs(air) do
		core.set_node(at, {name = "air"})
	end
	return true
end

-- Every hour at every spot: four pictures, two pairs
-- Grouped by place, not by hour: the pbr path's auto-exposure meter takes
-- a while to settle, and a pair whose two shots straddle a walk from a
-- daylit room to a sealed one reads the meter's travel rather than the
-- light (194 against 85 on a wall that cannot see the sun, 2026-09-22).
-- Within a pair only the hour changes and the camera does not move.
-- The first stop is a warm-up whose picture nobody reads. The client is
-- still taking delivery of the world when it comes up, and a room that
-- arrives between two pictures reads the arrival: the first sealed shot
-- was twenty-one levels away from its own second shot thirty seconds
-- later, which is more than anything this fixture measures.
local STOPS = {
	{"warm", 0.5417, "sealed"},
	{"0200", 0.0833, "sealed"}, {"1300", 0.5417, "sealed"},
	{"0200", 0.0833, "mouth"}, {"1300", 0.5417, "mouth"},
}

local function place(player, spot)
	local at = (spot == "mouth") and mouth or room
	player:set_pos({x = at.x + 0.5, y = at.y + 0.1, z = at.z + 0.5})
	-- The mouthed room is read from the wall opposite its corridor
	player:set_look_horizontal((spot == "mouth" and mouth_dir > 0) and
			math.pi or 0)
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
	-- the reading, so the nibbles are said with the picture. The node
	-- read is the air against the wall the camera looks at (+z, which is
	-- where yaw 0 points), not the room's middle: the middle of the
	-- mouthed room has the corridor's daylight in it, and the claim is
	-- about the wall in the picture.
	local face = (s[3] == "mouth") and -mouth_dir or 1
	local n = core.get_node({x = spot.x, y = spot.y + 1,
			z = spot.z + 2 * face})
	-- Long enough that the walk to the other room has been loaded, meshed
	-- and relit before the picture is asked for: a room read while its
	-- relight runs is a room half lit, and the first reading of this pair
	-- was one of those
	-- Twenty-five seconds after the hour is set, not ten: the client
	-- takes the hour over the wire and the room it draws follows a few
	-- seconds behind the server's own reading. At ten the first picture
	-- of the 02:00 stop still had the daylight value in it and its own
	-- second picture twenty seconds later was twenty-one levels darker.
	local put = player:get_pos()
	core.after(25, function()
		local now = player:get_pos()
		core.log("action", string.format(
				"dark: %s at %s put at %.1f,%.1f,%.1f, now at " ..
				"%.1f,%.1f,%.1f", s[3], s[1], put.x, put.y, put.z,
				now.x, now.y, now.z))
		if s[3] == "mouth" then
			local say = {}
			for _, d in ipairs({-2, 0, 3, 8, 13, 18, 23, 28}) do
				local q = core.get_node({x = spot.x, y = spot.y + 1,
						z = spot.z + d * mouth_dir})
				say[#say + 1] = (spot.z + d * mouth_dir) .. ":" ..
						q.name:gsub("^.*:", "") .. ":" ..
						math.floor((q.param1 or 0) % 16)
			end
			core.log("action", "dark: along the corridor at " .. s[1] ..
					" " .. table.concat(say, " "))
			local up = {}
			for _, y in ipairs({spot.y, spot.y + 10, spot.y + 20,
					spot.y + 30, spot.y + 40, spot.y + 50, spot.y + 60,
					spot.y + 70}) do
				local q = core.get_node({x = spot.x, y = y,
						z = shaft_z or spot.z})
				up[#up + 1] = y .. ":" .. q.name:gsub("^.*:", "") .. ":" ..
						math.floor((q.param1 or 0) % 16)
			end
			core.log("action", "dark: up the shaft at " .. s[1] .. " " ..
					table.concat(up, " "))
		end
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
