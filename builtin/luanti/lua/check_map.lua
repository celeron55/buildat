-- Buildat: builtin/luanti/lua/check_map.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The one runnable check the map seam leaves behind: a node written, flushed
-- into voxelworld by the module between the two halves, and read back out of
-- it. The write-behind buffer makes a round trip that never leaves the buffer
-- prove nothing, which is why this is two functions and not one.
--
-- Run once at the end of run_game(); see create_world() in luanti.cpp.

local CHECK_POS = {x = 1, y = 2, z = 3}
local EMPTY_POS = {x = 5, y = 6, z = 7}
local AREA_MIN = {x = 10, y = 10, z = 10}
local AREA_MAX = {x = 14, y = 14, z = 14}
local check_name = nil

-- The clock is pure Lua and needs no flush, so it is checked here rather than
-- in a file of its own.
--
-- Everything here is relative to where the clock stands and the whole of it
-- is put back afterwards, because the clock comes out of the save now: a
-- check that started from zero would fail on the second run, and one that
-- left the day it rolled behind would age a world by a day every start.
local function check_clock()
	local t0, g0, d0 = core.__get_clock()
	core.set_timeofday(0.25)
	if math.abs(core.get_timeofday() - 0.25) > 1e-6 then
		error("check_map: set_timeofday did not take")
	end
	-- A day is 24*60*60 game seconds, and time_speed is how many of them a
	-- real second is, so this is a whole day whatever the speed
	local speed = tonumber(core.settings:get("time_speed")) or 72
	core.__step(24 * 60 * 60 / speed)
	if math.abs(core.get_timeofday() - 0.25) > 1e-3 then
		error("check_map: a whole day did not come back to the same hour: " ..
				tostring(core.get_timeofday()))
	end
	if core.get_day_count() ~= d0 + 1 then
		error("check_map: the day did not roll: " ..
				tostring(core.get_day_count()) .. " from " .. tostring(d0))
	end
	if core.get_gametime() <= g0 then
		error("check_map: game time did not advance")
	end
	core.__set_clock(t0, g0, d0)
	if core.get_day_count() ~= d0 then
		error("check_map: the clock did not go back where it was")
	end
end

-- A node that is really in the world rather than a hole in it, so that what
-- comes back can be told apart from what an unwritten voxel reads as
local function pick_node()
	local names = {}
	for name, def in pairs(core.registered_nodes) do
		if name ~= "air" and name ~= "ignore" and name ~= "unknown" and
				(def.drawtype == nil or def.drawtype == "normal") then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return names[1]
end

function core.__check_map_write()
	check_name = pick_node()
	if not check_name then
		return false
	end
	-- Ignore is what voxelworld says for a voxel nothing has written, and
	-- Luanti says the same word for the same thing
	local before = core.get_node(EMPTY_POS)
	if before.name ~= "ignore" then
		error("check_map: an unwritten voxel reads as " .. before.name)
	end
	core.set_node(CHECK_POS, {name = check_name, param2 = 3})
	-- Visible immediately, out of the buffer: the on_placenode callbacks in
	-- the same step will look
	local now = core.get_node(CHECK_POS)
	if now.name ~= check_name then
		error("check_map: the buffer did not answer with " .. check_name)
	end
	if now.param2 ~= 3 then
		error("check_map: param2 came back as " .. tostring(now.param2))
	end
	-- A 2x1x2 patch for the region reads to find, one voxel above the floor
	-- of the box they are asked about, so that a read that ignores its
	-- bounds shows up as the wrong count
	for x = AREA_MIN.x + 1, AREA_MIN.x + 2 do
		for z = AREA_MIN.z + 1, AREA_MIN.z + 2 do
			core.set_node({x = x, y = AREA_MIN.y + 1, z = z},
					{name = check_name})
			-- Air above it, so that find_nodes_in_area_under_air has
			-- something to be right about. The void reads as ignore, not as
			-- air, so without this it would be right by finding nothing.
			core.set_node({x = x, y = AREA_MIN.y + 2, z = z}, {name = "air"})
		end
	end
	check_clock()
	return true
end

function core.__check_map_read()
	local node = core.get_node(CHECK_POS)
	if node.name ~= check_name then
		error("check_map: voxelworld answered with " .. node.name ..
				" instead of " .. check_name)
	end
	if node.param2 ~= 3 then
		error("check_map: param2 was lost in the flush: " ..
				tostring(node.param2))
	end
	-- The id is the VoxelRegistry id, and the registry was built from the
	-- same numbering, so these have to agree or nothing else here is true
	local id = core.get_content_id(check_name)
	local raw_id = core.get_node_raw(CHECK_POS.x, CHECK_POS.y, CHECK_POS.z)
	if raw_id ~= id then
		error("check_map: content id " .. id .. " came back as " .. raw_id)
	end

	-- The region reads, over what the write half put there
	local found, counts = core.find_nodes_in_area(AREA_MIN, AREA_MAX,
			{check_name})
	if #found ~= 4 then
		error("check_map: find_nodes_in_area found " .. #found ..
				" of a patch of 4")
	end
	if counts[check_name] ~= 4 then
		error("check_map: the counts say " .. tostring(counts[check_name]))
	end
	for _, p in ipairs(found) do
		if p.y ~= AREA_MIN.y + 1 then
			error("check_map: a position came back at y=" .. p.y)
		end
	end
	local near = core.find_node_near(AREA_MIN, 4, {check_name})
	if not near then
		error("check_map: find_node_near found nothing")
	end
	if math.abs(near.x - (AREA_MIN.x + 1)) > 1 or
			math.abs(near.z - (AREA_MIN.z + 1)) > 1 then
		error("check_map: find_node_near came back with a far one")
	end
	-- Nothing matches a name that is not there
	local none = core.find_nodes_in_area(AREA_MIN, AREA_MAX,
			{"check_map:nothing"})
	if #none ~= 0 then
		error("check_map: found " .. #none .. " of a node that does not exist")
	end
	-- Every one of the patch is under one of the air voxels above it, and
	-- this is the read whose indexing runs down a column rather than along
	-- the array
	local under = core.find_nodes_in_area_under_air(AREA_MIN, AREA_MAX,
			{check_name})
	if #under ~= 4 then
		error("check_map: find_nodes_in_area_under_air found " .. #under ..
				" of a patch of 4")
	end
	for _, p in ipairs(under) do
		if p.y ~= AREA_MIN.y + 1 then
			error("check_map: under_air came back at y=" .. p.y)
		end
	end
	-- The air above it is not under air itself
	local air_under = core.find_nodes_in_area_under_air(AREA_MIN, AREA_MAX,
			{"air"})
	if #air_under ~= 0 then
		error("check_map: " .. #air_under .. " air voxels are under air")
	end

	core.set_node(CHECK_POS, {name = "air"})
	for x = AREA_MIN.x + 1, AREA_MIN.x + 2 do
		for z = AREA_MIN.z + 1, AREA_MIN.z + 2 do
			core.set_node({x = x, y = AREA_MIN.y + 1, z = z}, {name = "air"})
		end
	end
	core.log("verbose", "check_map: " .. check_name ..
			" survived the flush, and the region reads found it")
end

-- vim: set noet ts=4 sw=4:
