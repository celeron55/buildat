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

function M.self_test()
	check_compress()
end

return M
-- vim: set noet ts=4 sw=4:
