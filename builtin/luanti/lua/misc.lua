-- Buildat: builtin/luanti/lua/misc.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The small pure functions of Luanti's API: the ones that are arithmetic on a
-- string and belong nowhere else. Lua 5.1 has no bit operators, so the
-- shifting here is done with multiplication and modulo, which is exact for
-- the sizes involved.

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function core.encode_base64(data)
	if type(data) ~= "string" then
		return nil
	end
	local out = {}
	local n = #data
	local i = 1
	while i + 2 <= n do
		local a, b, c = data:byte(i, i + 2)
		local v = a * 65536 + b * 256 + c
		out[#out + 1] = B64:sub(math.floor(v / 262144) + 1,
						math.floor(v / 262144) + 1) ..
				B64:sub(math.floor(v / 4096) % 64 + 1,
						math.floor(v / 4096) % 64 + 1) ..
				B64:sub(math.floor(v / 64) % 64 + 1,
						math.floor(v / 64) % 64 + 1) ..
				B64:sub(v % 64 + 1, v % 64 + 1)
		i = i + 3
	end
	local left = n - i + 1
	if left == 1 then
		local a = data:byte(i)
		local v = a * 16
		out[#out + 1] = B64:sub(math.floor(v / 64) + 1,
						math.floor(v / 64) + 1) ..
				B64:sub(v % 64 + 1, v % 64 + 1) .. "=="
	elseif left == 2 then
		local a, b = data:byte(i, i + 1)
		local v = (a * 256 + b) * 4
		out[#out + 1] = B64:sub(math.floor(v / 4096) + 1,
						math.floor(v / 4096) + 1) ..
				B64:sub(math.floor(v / 64) % 64 + 1,
						math.floor(v / 64) % 64 + 1) ..
				B64:sub(v % 64 + 1, v % 64 + 1) .. "="
	end
	return table.concat(out)
end

local B64_INDEX = {}
for i = 1, #B64 do
	B64_INDEX[B64:sub(i, i)] = i - 1
end

-- nil for anything that is not base64, which is what Luanti returns
function core.decode_base64(text)
	if type(text) ~= "string" then
		return nil
	end
	local clean = text:gsub("[\r\n]", "")
	local body = clean:gsub("=+$", "")
	local out = {}
	local acc, bits = 0, 0
	for i = 1, #body do
		local d = B64_INDEX[body:sub(i, i)]
		if d == nil then
			return nil
		end
		acc = acc * 64 + d
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local shift = 2 ^ bits
			out[#out + 1] = string.char(math.floor(acc / shift) % 256)
			acc = acc % shift
		end
	end
	return table.concat(out)
end

-- Luanti packs a node position into one number; mods use it as a table key
local function hash_component(v)
	return math.floor(v) + 32768
end

function core.hash_node_position(pos)
	return (hash_component(pos.z) * 65536 + hash_component(pos.y)) * 65536 +
			hash_component(pos.x)
end

function core.get_position_from_hash(hash)
	local x = hash % 65536 - 32768
	hash = math.floor(hash / 65536)
	local y = hash % 65536 - 32768
	hash = math.floor(hash / 65536)
	local z = hash % 65536 - 32768
	return {x = x, y = y, z = z}
end

-- vim: set noet ts=4 sw=4:
