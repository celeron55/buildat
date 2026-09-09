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

-- One code point as UTF-8
function M.utf8_encode(c)
	if c < 0x80 then
		return string.char(c)
	elseif c < 0x800 then
		return string.char(0xc0 + math.floor(c / 0x40), 0x80 + c % 0x40)
	elseif c < 0x10000 then
		return string.char(0xe0 + math.floor(c / 0x1000),
				0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
	end
	return string.char(0xf0 + math.floor(c / 0x40000),
			0x80 + math.floor(c / 0x1000) % 0x40,
			0x80 + math.floor(c / 0x40) % 0x40, 0x80 + c % 0x40)
end

-- The code points of a UTF-8 string as UTF-16 units, so that what is not in
-- the basic plane comes out as a surrogate pair. A byte that is not valid
-- UTF-8 becomes the replacement character rather than stopping anything.
function M.utf16_units(s)
	local units = {}
	local i = 1
	while i <= #s do
		local b = s:byte(i)
		local c, len
		if b < 0x80 then
			c, len = b, 1
		elseif b >= 0xc0 and b < 0xe0 then
			c, len = b - 0xc0, 2
		elseif b >= 0xe0 and b < 0xf0 then
			c, len = b - 0xe0, 3
		elseif b >= 0xf0 and b < 0xf8 then
			c, len = b - 0xf0, 4
		else
			c, len = 0xfffd, 1
		end
		if c ~= 0xfffd then
			for k = 1, len - 1 do
				local cont = s:byte(i + k)
				if not cont or cont < 0x80 or cont >= 0xc0 then
					c, len = 0xfffd, 1
					break
				end
				c = c * 0x40 + (cont - 0x80)
			end
		end
		i = i + len
		if c < 0x10000 then
			units[#units + 1] = c
		else
			c = c - 0x10000
			units[#units + 1] = 0xd800 + math.floor(c / 0x400)
			units[#units + 1] = 0xdc00 + c % 0x400
		end
	end
	return units
end

-- Luanti's base64, which is what a server older than protocol 48 announces
-- media hashes in. Standard alphabet, and the padding may be left off.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_VALUE = (function()
	local out = {}
	for i = 1, #B64 do
		out[B64:sub(i, i)] = i - 1
	end
	return out
end)()

function M.base64_decode(s)
	local out = {}
	local acc, bits = 0, 0
	for i = 1, #s do
		local v = B64_VALUE[s:sub(i, i)]
		if v then
			acc = acc * 64 + v
			bits = bits + 6
			if bits >= 8 then
				bits = bits - 8
				local byte = math.floor(acc / 2 ^ bits)
				out[#out + 1] = string.char(byte)
				acc = acc - byte * 2 ^ bits
			end
		end
	end
	return table.concat(out)
end

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
	-- A 32-bit IEEE-754 float, big-endian, the same way r:f32() reads one.
	-- Written out by hand because Lua's own bit-level float handling is
	-- either missing (5.1's math.frexp went away in 5.4) or needs a library.
	function w:f32(v)
		if v ~= v then -- NaN
			return self:u32(0x7fc00000)
		end
		local sign = 0
		if v < 0 or (v == 0 and 1 / v < 0) then
			sign = 0x80000000
			v = -v
		end
		if v == 0 then
			return self:u32(sign)
		end
		if v == math.huge then
			return self:u32(sign + 0x7f800000)
		end
		local exponent = math.floor(math.log(v) / math.log(2))
		-- The logarithm can land a step either side of the right exponent
		local mantissa = v / 2 ^ exponent
		if mantissa >= 2 then
			mantissa = mantissa / 2
			exponent = exponent + 1
		elseif mantissa < 1 then
			mantissa = mantissa * 2
			exponent = exponent - 1
		end
		local biased = exponent + 127
		if biased < 1 then
			return self:u32(sign) -- Smaller than a normal float holds
		end
		if biased > 254 then
			return self:u32(sign + 0x7f800000)
		end
		local frac = math.floor((mantissa - 1) * 0x800000 + 0.5)
		if frac >= 0x800000 then
			frac = 0
			biased = biased + 1
		end
		return self:u32(sign + biased * 0x800000 + frac)
	end

	function w:v3f(x, y, z)
		return self:f32(x):f32(y):f32(z)
	end

	function w:wstring(s)
		local units = M.utf16_units(s)
		self:u16(#units)
		for _, u in ipairs(units) do
			self:u16(u)
		end
		return self
	end

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

	-- Luanti's TileAnimationParams, which is in both a tile definition and an
	-- item's images. What follows the type is what the type says.
	function r:animation()
		local animation_type = self:u8()
		if animation_type == 1 then -- Vertical frames
			return {type = animation_type, aspect_w = self:u16(),
					aspect_h = self:u16(), length = self:f32()}
		elseif animation_type == 2 then -- A 2D sheet
			return {type = animation_type, frames_w = self:u8(),
					frames_h = self:u8(), length = self:f32()}
		end
		return {type = animation_type}
	end

	-- A wide string: a count of UTF-16 units and then that many, big-endian.
	-- Chat is the only thing that uses them. What comes out is UTF-8, which
	-- is what everything else here and in Urho3D wants.
	function r:wstring()
		local count = self:u16()
		local out = {}
		local i = 1
		while i <= count do
			local c = self:u16()
			if c >= 0xd800 and c < 0xdc00 and i < count then
				-- A surrogate pair is one code point in two units
				local low = self:u16()
				i = i + 1
				if low >= 0xdc00 and low < 0xe000 then
					c = 0x10000 + (c - 0xd800) * 0x400 + (low - 0xdc00)
				else
					c = 0xfffd
				end
			end
			out[#out + 1] = M.utf8_encode(c)
			i = i + 1
		end
		return table.concat(out)
	end

	-- One line of a part of a packet that is text rather than fields -- an
	-- inventory, node metadata -- without its newline. What is left when
	-- there is no newline is the last line.
	function r:line()
		local at = data:find("\n", pos, true)
		if not at then
			return self:rest()
		end
		local s = data:sub(pos, at - 1)
		pos = at + 1
		return s
	end

	function r:skip(n)
		self:raw(n)
		return self
	end

	-- How many bytes are left, for a packet that is a list with no count
	function r:remaining()
		return #data - pos + 1
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
