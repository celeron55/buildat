-- Buildat: extension/luanti_client/engine_test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Checks the engine primitives this extension leans on, against the engine's
-- own other way of doing the same thing where there is one. init.lua runs it at
-- boot, so a broken binding shows up before the connection does.

local M = {}

local function check_compress()
	-- Something with enough structure to actually compress
	local data = string.rep("mapblock ", 200)..string.char(0, 1, 2, 253, 254, 255)
	for _, format in ipairs({"zlib", "zstd"}) do
		local packed = buildat.compress(data, format)
		assert(#packed < #data, format.." did not compress")
		local out, consumed = buildat.decompress(packed, format)
		assert(out == data, format.." did not survive a round trip")
		assert(consumed == #packed,
				format.." consumed "..consumed.." of "..#packed.." bytes")
		-- Two streams in a row: consumed is what says where the second begins,
		-- which is how a Luanti mapblock at serialization version 28 is read
		local out2, consumed2 = buildat.decompress(packed..packed, format)
		assert(out2 == data and consumed2 == #packed,
				format.." did not stop at the end of the first stream")
	end
	-- An empty string is a stream too, and levels are optional
	assert(buildat.decompress(buildat.compress("", "zstd"), "zstd") == "")
	assert(buildat.decompress(buildat.compress(data, "zstd", 1), "zstd") == data)
	assert(buildat.decompress(buildat.compress(data, "zlib", 9), "zlib") == data)
	-- The default format is zlib, which is what buildat's own data uses
	assert(buildat.decompress(buildat.compress(data, "zlib")) == data)
end

-- A volume packed by pack_voxel_volume() has to hold what the same data set
-- one voxel at a time through Volume holds. Volume:serialize() and
-- deserialize_volume() are the engine's other way round the same trip, so the
-- two answers are independent.
local function check_pack_voxel_volume()
	local safe = buildat.safe
	-- Samples that need every byte order and both fields: a 4x3x2 box of ids,
	-- and the same box's light. The numbers are made up but the layout is
	-- Luanti's: x fastest, then y, then z.
	local sx, sy, sz = 4, 3, 2
	local ids, lights = {}, {}
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local i = x + y * sx + z * sx * sy
				ids[i] = (x * 100 + y * 10 + z) % 65536
				lights[i] = (x + y + z) % 16
			end
		end
	end
	local id_bytes, light_bytes = {}, {}
	for i = 0, sx * sy * sz - 1 do
		id_bytes[#id_bytes + 1] = string.char(math.floor(ids[i] / 256),
				ids[i] % 256)
		light_bytes[#light_bytes + 1] = string.char(lights[i] * 16 + lights[i])
	end
	id_bytes = table.concat(id_bytes)
	light_bytes = table.concat(light_bytes)

	-- A region one voxel bigger than the box on every side, so that the fill
	-- and the offset both get checked
	local FILL = 7
	local packed = buildat.pack_voxel_volume{
		region = {-1, -1, -1, sx, sy, sz},
		fill = FILL,
		sources = {
			{
				data = id_bytes, format = "u16be",
				source_size = {sx, sy, sz},
				at = {0, 0, 0}, order = "xyz", field = "id",
			},
			{
				-- Luanti's param1 keeps the day light in the low nibble
				data = light_bytes, format = "u8",
				source_size = {sx, sy, sz},
				at = {0, 0, 0}, order = "xyz", field = "skylight",
				mask = 0x0f,
			},
		},
	}

	-- The same thing the slow way
	local volume = safe.Volume(safe.Region(-1, -1, -1, sx, sy, sz))
	for z = -1, sz do
		for y = -1, sy do
			for x = -1, sx do
				volume:set_voxel_at(x, y, z, safe.VoxelInstance(FILL))
			end
		end
	end
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local i = x + y * sx + z * sx * sy
				local v = safe.VoxelInstance(ids[i] + lights[i] * 0x1000000)
				volume:set_voxel_at(x, y, z, v)
			end
		end
	end
	assert(volume:serialize() == packed,
			"pack_voxel_volume() and Volume:serialize() disagree")

	-- And read back through the other door, to check that what came out is
	-- what the mesher would see
	local back = safe.deserialize_volume(packed)
	for z = -1, sz do
		for y = -1, sy do
			for x = -1, sx do
				local v = back:get_voxel_at(x, y, z)
				local inside = x >= 0 and x < sx and y >= 0 and y < sy and
						z >= 0 and z < sz
				local i = x + y * sx + z * sx * sy
				assert(v:get_id() == (inside and ids[i] or FILL),
						"id at "..x..","..y..","..z.." is "..v:get_id())
				assert(v:get_skylight() == (inside and lights[i] or 0),
						"skylight at "..x..","..y..","..z.." is "..
						v:get_skylight())
			end
		end
	end

	-- order and map: the same ids the other way round in memory, mapped
	local zyx = {}
	for x = 0, sx - 1 do
		for y = 0, sy - 1 do
			for z = 0, sz - 1 do
				local id = ids[x + y * sx + z * sx * sy]
				zyx[#zyx + 1] = string.char(math.floor(id / 256), id % 256)
			end
		end
	end
	local map = {}
	for i = 0, sx * sy * sz - 1 do
		map[ids[i]] = 1000 + ids[i]
	end
	map[ids[0]] = nil -- One sample nothing maps, which leaves the fill alone
	local mapped = buildat.pack_voxel_volume{
		region = {0, 0, 0, sx - 1, sy - 1, sz - 1},
		fill = FILL,
		sources = {{
			data = table.concat(zyx), format = "u16be",
			source_size = {sx, sy, sz}, order = "zyx", map = map,
		}},
	}
	local mapped_volume = safe.deserialize_volume(mapped)
	for z = 0, sz - 1 do
		for y = 0, sy - 1 do
			for x = 0, sx - 1 do
				local id = ids[x + y * sx + z * sx * sy]
				local expect = map[id] or FILL
				assert(mapped_volume:get_voxel_at(x, y, z):get_id() == expect,
						"mapped id at "..x..","..y..","..z.." is "..
						mapped_volume:get_voxel_at(x, y, z):get_id())
			end
		end
	end

	-- A source box that hangs over the edge of the region is clipped, not an
	-- error: that is how a neighbouring block's border slice arrives
	local clipped = buildat.pack_voxel_volume{
		region = {0, 0, 0, 0, 0, 0},
		fill = FILL,
		sources = {{
			data = id_bytes, format = "u16be",
			source_size = {sx, sy, sz}, at = {-1, -1, -1},
		}},
	}
	assert(safe.deserialize_volume(clipped):get_voxel_at(0, 0, 0):get_id() ==
			ids[1 + 1 * sx + 1 * sx * sy], "clipping put the wrong voxel at 0")
end

function M.self_test()
	check_compress()
	check_pack_voxel_volume()
end

return M
-- vim: set noet ts=4 sw=4:
