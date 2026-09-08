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
