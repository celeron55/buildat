-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- [MAPGEN_DENSITY]: what a box holds once generated, per node name, the
-- same in official Luanti (a world mod) and in buildat (BUILDAT_LUANTI_LUA);
-- builtin/luanti/test/density.sh runs both and prints the two side by side.
-- DENSITY_BOX="x1,y1,z1,x2,y2,z2" picks the box (default: Luanti's 2x2
-- mapchunks around the origin, y -64..63). Each 16^3 block is counted when
-- its emerge callback says it is there: a section here is not kept loaded
-- after, with no player, and a VoxelManip read of an unloaded one gives
-- ignore. Lines "DENSITY <name> <count>", then "DENSITY done".
local box = {}
for v in (os.getenv("DENSITY_BOX") or "-112,-64,-112,47,63,47"):gmatch("-?%d+") do
	box[#box + 1] = tonumber(v)
end
local P1 = {x = box[1], y = box[2], z = box[3]}
local P2 = {x = box[4], y = box[5], z = box[6]}
local n = {}
-- DENSITY_BY_Y=1: also per row of blocks, lines "DENSITY y<bp.y> <name> <count>";
-- DENSITY_BY_Y=block: per block, "DENSITY yx,y,z <name> <count>"
local by_block = os.getenv("DENSITY_BY_Y") == "block"
local by_y = (os.getenv("DENSITY_BY_Y") == "1" or by_block) and {} or nil
local blocks = 0
local function count_block(bp)
	local lo = {x = bp.x * 16, y = bp.y * 16, z = bp.z * 16}
	local hi = {x = lo.x + 15, y = lo.y + 15, z = lo.z + 15}
	local vm = core.get_voxel_manip()
	local e1, e2 = vm:read_from_map(lo, hi)
	local area = VoxelArea:new({MinEdge = e1, MaxEdge = e2})
	local data = vm:get_data()
	for z = lo.z, hi.z do
		for y = lo.y, hi.y do
			for x = lo.x, hi.x do
				local c = data[area:index(x, y, z)]
				n[c] = (n[c] or 0) + 1
				if by_y then
					local key = by_block and bp.x .. "," .. bp.y .. "," .. bp.z or bp.y
					local r = by_y[key] or {}
					by_y[key] = r
					r[c] = (r[c] or 0) + 1
				end
			end
		end
	end
	blocks = blocks + 1
end
local function report()
	local names = {}
	for c, k in pairs(n) do
		names[#names + 1] = {core.get_name_from_content_id(c), k}
	end
	table.sort(names, function(a, b) return a[1] < b[1] end)
	for _, p in ipairs(names) do
		core.log("action", "DENSITY " .. p[1] .. " " .. p[2])
	end
	for y, r in pairs(by_y or {}) do
		for c, k in pairs(r) do
			core.log("action", "DENSITY y" .. y .. " " ..
					core.get_name_from_content_id(c) .. " " .. k)
		end
	end
	core.log("action", "DENSITY " .. blocks .. " blocks counted")
	core.log("action", "DENSITY done")
end
-- DENSITY_NO_ONGEN=1: no game's on_generated runs, the C++ mapgen alone
-- -- which says whether a difference is made there or by the game's Lua
if os.getenv("DENSITY_NO_ONGEN") == "1" then
	core.register_on_mods_loaded(function()
		for i = #core.registered_on_generateds, 1, -1 do
			table.remove(core.registered_on_generateds, i)
		end
		core.log("action", "DENSITY no on_generated")
	end)
end
core.register_on_mods_loaded(function()
	core.after(2, function()
		local t0 = core.get_us_time()
		core.emerge_area(P1, P2, function(bp, _, left)
			count_block(bp)
			if left % 50 == 0 then
				core.log("action", "DENSITY emerging, " .. left .. " blocks left")
			end
			if left == 0 then
				core.log("action", string.format("DENSITY emerged in %.0f s",
						(core.get_us_time() - t0) / 1e6))
				report()
			end
		end)
	end)
end)
