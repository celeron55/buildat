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
-- A box that crosses a chunk boundary (every 32 voxels) and a section
-- boundary (every 64), because a region read is one read per chunk stitched
-- together and the stitching is the part that can be wrong. Four corners of
-- it get a node and the read has to find exactly those four.
local SEAM_MIN = {x = 30, y = 2, z = 62}
local SEAM_MAX = {x = 34, y = 2, z = 66}
local SEAM_CORNERS = {
	{x = 31, y = 2, z = 63},
	{x = 32, y = 2, z = 63},
	{x = 31, y = 2, z = 64},
	{x = 32, y = 2, z = 64},
}
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

-- core.after, which is a mod's way of doing something later and is the thing
-- every timer in a game is built on. It is a globalstep of the vendored
-- builtin's own, so what this checks is the whole path: a step runs the
-- registered globalsteps, after.lua's queue is one of them, and the callback
-- comes back with the arguments it was given.
--
-- Nothing is registered here that outlives the check: after.lua's globalstep
-- is already there and this only puts one job in its queue.
local function check_after()
	local fired, got = false, nil
	core.after(0.05, function(a) fired, got = true, a end, "argument")
	if fired then
		error("check_map: core.after fired before a step")
	end
	core.__step(0.1)
	if not fired then
		error("check_map: core.after did not fire in a step")
	end
	if got ~= "argument" then
		error("check_map: core.after lost its argument: " .. tostring(got))
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
	-- Singlenode is a node everywhere, which is what Luanti's own
	-- MapgenSinglenode does: a voxel nobody has built in is air, and only
	-- what is outside the world altogether is ignore.
	local before = core.get_node(EMPTY_POS)
	if before.name ~= "air" then
		error("check_map: an unbuilt voxel reads as " .. before.name)
	end
	local outside = core.get_node({x = 0, y = 30000, z = 0})
	if outside.name ~= "ignore" then
		error("check_map: a voxel outside the world reads as " ..
				outside.name)
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
	for _, p in ipairs(SEAM_CORNERS) do
		core.set_node(p, {name = check_name})
	end
	check_clock()
	check_after()
	return true
end

-- The mapgen seam's map half: a VoxelManip round trip. What can be wrong
-- here and nowhere else is the indexing -- the arrays are x fastest and then
-- y and then z, which is what VoxelArea does its arithmetic in -- so the
-- nodes written are at positions that are all different in every axis and a
-- transposed index puts them somewhere this notices.
local VM_MIN = {x = 20, y = 2, z = 24}
local VM_MAX = {x = 25, y = 6, z = 27}
local VM_AT = {x = 21, y = 3, z = 26}

local function check_vmanip()
	local vm = VoxelManip()
	local emin, emax = vm:read_from_map(VM_MIN, VM_MAX)
	if emin.x ~= VM_MIN.x or emax.z ~= VM_MAX.z then
		error("check_map: the VoxelManip emerged (" .. emin.x .. "," ..
				emin.y .. "," .. emin.z .. ")-(" .. emax.x .. "," ..
				emax.y .. "," .. emax.z .. ")")
	end
	local data = vm:get_data()
	local area = VoxelArea:new{MinEdge = emin, MaxEdge = emax}
	local id = core.get_content_id(check_name)
	data[area:index(VM_AT.x, VM_AT.y, VM_AT.z)] = id
	vm:set_data(data)
	local param2 = vm:get_param2_data()
	param2[area:index(VM_AT.x, VM_AT.y, VM_AT.z)] = 3
	vm:set_param2_data(param2)
	vm:write_to_map()

	local node = core.get_node(VM_AT)
	if node.name ~= check_name then
		error("check_map: the VoxelManip wrote " .. node.name .. " where " ..
				check_name .. " was meant to go")
	end
	if node.param2 ~= 3 then
		error("check_map: the VoxelManip lost param2: " ..
				tostring(node.param2))
	end
	-- The same index read the other way round would land here
	local swapped = core.get_node({x = VM_AT.z, y = VM_AT.y, z = VM_AT.x})
	if swapped.name == check_name then
		error("check_map: the VoxelManip index is transposed")
	end

	-- And back out through a second one, which is the read half
	local vm2 = VoxelManip(VM_MIN, VM_MAX)
	local d2 = vm2:get_data()
	local a2 = VoxelArea:new{MinEdge = VM_MIN, MaxEdge = VM_MAX}
	if d2[a2:index(VM_AT.x, VM_AT.y, VM_AT.z)] ~= id then
		error("check_map: the VoxelManip read back " ..
				tostring(d2[a2:index(VM_AT.x, VM_AT.y, VM_AT.z)]) ..
				" instead of " .. id)
	end
	if vm2:get_node_at(VM_AT).name ~= check_name then
		error("check_map: get_node_at answered " ..
				vm2:get_node_at(VM_AT).name)
	end
	-- set_node_at and the write that carries it
	vm2:set_node_at(VM_AT, {name = "air"})
	vm2:write_to_map()
	if core.get_node(VM_AT).name ~= "air" then
		error("check_map: set_node_at left " .. core.get_node(VM_AT).name)
	end
end

-- The mapgen's other half: the noise a Lua mapgen shapes its world with.
-- What can be wrong here is that it answers a constant -- which is what the
-- stub did before there was one -- or that the map and the single value
-- disagree, which would make a mod's heightmap and its checks two different
-- worlds.
local function check_noise()
	local np = {offset = 0, scale = 1, seed = 71, octaves = 3,
			persistence = 0.6, spread = {x = 40, y = 40, z = 40}}
	local n = PerlinNoise(np)
	local a, b = n:get_2d({x = 0, y = 0}), n:get_2d({x = 137, y = -91})
	if a == b then
		error("check_map: the noise answers " .. tostring(a) ..
				" everywhere")
	end
	if a ~= a or math.abs(a) > 1000 then
		error("check_map: the noise answered " .. tostring(a))
	end
	-- The map is the same noise over a box, and its first value is the one
	-- at the corner it starts from
	local map = PerlinNoiseMap(np, {x = 4, y = 3, z = 1})
	local flat = map:get_2d_map_flat({x = 0, y = 0})
	if #flat ~= 12 then
		error("check_map: a 4x3 noise map has " .. #flat .. " values")
	end
	if math.abs(flat[1] - a) > 0.05 then
		error("check_map: the map says " .. tostring(flat[1]) ..
				" where the value says " .. tostring(a))
	end
	-- And the nested form is the flat one in rows of x
	local rows = map:get_2d_map({x = 0, y = 0})
	if #rows ~= 3 or #rows[1] ~= 4 then
		error("check_map: the nested noise map is " .. #rows .. " rows of " ..
				tostring(#(rows[1] or {})))
	end
	if rows[1][1] ~= flat[1] or rows[2][1] ~= flat[5] then
		error("check_map: the nested noise map is not the flat one")
	end
	-- Two seeds are two worlds
	local other = PerlinNoise({offset = 0, scale = 1, seed = 72,
			octaves = 3, persistence = 0.6,
			spread = {x = 40, y = 40, z = 40}})
	if other:get_2d({x = 0, y = 0}) == a then
		error("check_map: the seed changes nothing")
	end
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
	-- Digging and placing, which are the builtin's own node_dig and
	-- item_place with nobody doing them. What is checked here is what they
	-- do to the map; that the callbacks around them run is checked in
	-- builtin/luanti/minimal_game, because a registered definition refuses
	-- new keys -- register.lua sets __newindex to ignore them, on purpose --
	-- so a callback has to be declared where the node is registered.
	do
		local p = {x = CHECK_POS.x + 4, y = CHECK_POS.y, z = CHECK_POS.z}
		-- The node under it is what item_place_node places against, and it
		-- has to be something rather than the void
		core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = check_name})
		core.set_node(p, {name = "air"})

		if not core.place_node(p, {name = check_name}) then
			error("check_map: place_node said no")
		end
		if core.get_node(p).name ~= check_name then
			error("check_map: place_node left " .. core.get_node(p).name)
		end

		if not core.dig_node(p) then
			error("check_map: dig_node said no")
		end
		if core.get_node(p).name ~= "air" then
			error("check_map: dig_node left " .. core.get_node(p).name)
		end

		core.swap_node(p, {name = check_name})
		if core.get_node(p).name ~= check_name then
			error("check_map: swap_node left " .. core.get_node(p).name)
		end

		core.set_node(p, {name = "air"})
		core.set_node({x = p.x, y = p.y - 1, z = p.z}, {name = "air"})
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
	-- Nothing is said here about air under air: singlenode fills the world
	-- with it, so most of the box is exactly that. What the count above is
	-- for -- that the read keeps to the box it was given -- is what the
	-- patch of four proves.

	-- The four either side of a chunk and a section boundary, out of one
	-- read that spans both
	local seam = core.find_nodes_in_area(SEAM_MIN, SEAM_MAX, {check_name})
	if #seam ~= #SEAM_CORNERS then
		error("check_map: the read across a chunk and a section boundary " ..
				"found " .. #seam .. " of " .. #SEAM_CORNERS)
	end
	for _, want in ipairs(SEAM_CORNERS) do
		local got = false
		for _, p in ipairs(seam) do
			if p.x == want.x and p.y == want.y and p.z == want.z then
				got = true
			end
		end
		if not got then
			error("check_map: the read across the boundaries lost (" ..
					want.x .. "," .. want.y .. "," .. want.z .. ")")
		end
	end

	core.set_node(CHECK_POS, {name = "air"})
	for x = AREA_MIN.x + 1, AREA_MIN.x + 2 do
		for z = AREA_MIN.z + 1, AREA_MIN.z + 2 do
			core.set_node({x = x, y = AREA_MIN.y + 1, z = z}, {name = "air"})
		end
	end
	for _, p in ipairs(SEAM_CORNERS) do
		core.set_node(p, {name = "air"})
	end
	check_vmanip()
	check_noise()

	core.log("verbose", "check_map: " .. check_name ..
			" survived the flush, and the region reads found it")

	-- What only the game can check: anything that has to be registered while
	-- the mods load, since the registries freeze once they have. A game that
	-- defines this gets called here, with the map flushed and readable.
	if core.__game_check then
		core.__game_check()
	end
end

-- vim: set noet ts=4 sw=4:
