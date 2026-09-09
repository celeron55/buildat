-- Buildat: extension/luanti_client/serialize.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti puts everything on the wire big-endian, strings with a u16 length in
-- front of them (u32 for the long ones). Arithmetic instead of bit operations,
-- so this works on plain Lua as well as LuaJIT.
--
-- Checked by test.lua in this directory.

local M = {}

function M.writer()
	local parts = {}
	local w = {}

	function w:raw(s)
		parts[#parts + 1] = s
		return self
	end

	function w:u8(v)
		return self:raw(string.char(v % 0x100))
	end

	function w:u16(v)
		v = v % 0x10000
		return self:raw(string.char(math.floor(v / 0x100), v % 0x100))
	end

	function w:u32(v)
		v = v % 0x100000000
		return self:raw(string.char(
				math.floor(v / 0x1000000) % 0x100,
				math.floor(v / 0x10000) % 0x100,
				math.floor(v / 0x100) % 0x100,
				v % 0x100))
	end

	function w:s16(v)
		return self:u16(v < 0 and v + 0x10000 or v)
	end

	function w:s32(v)
		return self:u32(v < 0 and v + 0x100000000 or v)
	end

	-- v3s16 and v3s32, which is how Luanti writes positions
	function w:v3s16(x, y, z)
		return self:s16(x):s16(y):s16(z)
	end

	function w:v3s32(x, y, z)
		return self:s32(x):s32(y):s32(z)
	end

	-- u16 length and the bytes
	function w:string(s)
		return self:u16(#s):raw(s)
	end

	-- u32 length and the bytes
	function w:longstring(s)
		return self:u32(#s):raw(s)
	end

	function w:data()
		return table.concat(parts)
	end

	return w
end

function M.reader(data)
	local pos = 1
	local r = {}

	function r:raw(n)
		if pos + n - 1 > #data then
			error("luanti_client/serialize: read past the end of the packet")
		end
		local s = data:sub(pos, pos + n - 1)
		pos = pos + n
		return s
	end

	function r:u8()
		return string.byte(self:raw(1))
	end

	function r:u16()
		local a, b = string.byte(self:raw(2), 1, 2)
		return a * 0x100 + b
	end

	function r:u32()
		local a, b, c, d = string.byte(self:raw(4), 1, 4)
		return ((a * 0x100 + b) * 0x100 + c) * 0x100 + d
	end

	function r:s16()
		local v = self:u16()
		return v >= 0x8000 and v - 0x10000 or v
	end

	function r:s32()
		local v = self:u32()
		return v >= 0x80000000 and v - 0x100000000 or v
	end

	-- IEEE 754 single precision, big-endian, which is what Luanti sends for
	-- floats from protocol 37 onwards
	function r:f32()
		local b1, b2, b3, b4 = string.byte(self:raw(4), 1, 4)
		local sign = b1 >= 0x80 and -1 or 1
		local exponent = (b1 % 0x80) * 2 + math.floor(b2 / 0x80)
		local mantissa = ((b2 % 0x80) * 0x100 + b3) * 0x100 + b4
		if exponent == 0xff then
			if mantissa == 0 then
				return sign * math.huge
			end
			return 0 / 0 -- NaN
		end
		-- 2^n rather than math.ldexp(), which Lua 5.4 no longer has and
		-- test.lua wants to run under whatever lua is around
		if exponent == 0 then
			-- Zero, or subnormal: no implicit leading one
			return sign * (mantissa / 0x800000) * 2 ^ -126
		end
		return sign * (1 + mantissa / 0x800000) * 2 ^ (exponent - 127)
	end

	-- The reads are in locals because the order in which Lua evaluates a
	-- return list is not something to rely on
	function r:v3s16()
		local x = self:s16()
		local y = self:s16()
		local z = self:s16()
		return x, y, z
	end

	function r:v3f()
		local x = self:f32()
		local y = self:f32()
		local z = self:f32()
		return x, y, z
	end

	function r:string()
		return self:raw(self:u16())
	end

	function r:longstring()
		return self:raw(self:u32())
	end

	function r:skip(n)
		self:raw(n)
		return self
	end

	function r:rest()
		return self:raw(#data - pos + 1)
	end

	function r:remaining()
		return #data - pos + 1
	end

	return r
end

return M
-- vim: set noet ts=4 sw=4:
