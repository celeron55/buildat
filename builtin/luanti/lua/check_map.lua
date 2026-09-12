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
local check_name = nil

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
	core.set_node(CHECK_POS, {name = "air"})
	core.log("verbose", "check_map: " .. check_name .. " survived the flush")
end

-- vim: set noet ts=4 sw=4:
