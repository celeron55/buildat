-- Buildat: builtin/luanti/lua/misc.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
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

-- Whether a string means yes. Luanti's own rule, from is_yes() in
-- util/string.h: trimmed and lowercased, "y", "yes", "true", or a number
-- that is not zero. Mods read their settings through it constantly.
function core.is_yes(arg)
	local s = tostring(arg):lower():match("^%s*(.-)%s*$")
	return s == "y" or s == "yes" or s == "true" or (tonumber(s) or 0) ~= 0
end

-- Luanti's translation and colour markup taken out of a string: an escape
-- character and then either (something) or one letter. The same code is in
-- the module's client half, client_lua/formspec.lua, where a client that
-- does not translate uses it -- keep the two together.
function core.strip_escapes(s)
	if type(s) ~= "string" then
		return s
	end
	s = s:gsub("\27%b()", "")
	s = s:gsub("\27.", "")
	return s
end

-- Whether a name could be a player's, from is_valid_player_name() in
-- Luanti's player.cpp: not empty, at most PLAYERNAME_SIZE characters, and
-- nothing outside PLAYERNAME_ALLOWED_CHARS.
local PLAYERNAME_SIZE = 20

function core.is_valid_player_name(name)
	if type(name) ~= "string" or name == "" or #name > PLAYERNAME_SIZE then
		return false
	end
	return name:match("^[a-zA-Z0-9%-_]+$") ~= nil
end

-- Luanti's day/night ratio at a time of day, for a mod doing its own light
-- arithmetic. The table and the two ends are time_to_daynight_ratio() in
-- daynightratio.h, with smooth on, which is what the Lua call uses --
-- **transcribed from Luanti's own source rather than reimplemented, so
-- the table below is Luanti's and LGPL-2.1-or-later** ([LICENSE_DUAL]); the
-- argument is the 0...1 time core.get_timeofday() returns and what comes
-- back is the 0...1 ObjectRef:override_day_night_ratio() takes.
local DAYNIGHT_RAMP = {
	{4375, 175}, {4625, 175}, {4875, 250}, {5125, 350},
	{5375, 500}, {5625, 675}, {5875, 875}, {6125, 1000}, {6375, 1000},
}

function core.time_to_day_night_ratio(time_of_day)
	local t = (tonumber(time_of_day) or 0) * 24000 % 24000
	if t > 12000 then
		t = 24000 - t
	end
	if t <= DAYNIGHT_RAMP[2][1] then
		return DAYNIGHT_RAMP[1][2] / 1000
	end
	if t >= DAYNIGHT_RAMP[8][1] then
		return 1.0
	end
	for i = 2, #DAYNIGHT_RAMP do
		if DAYNIGHT_RAMP[i][1] > t then
			local a, b = DAYNIGHT_RAMP[i - 1], DAYNIGHT_RAMP[i]
			local f = (t - a[1]) / (b[1] - a[1])
			return (a[2] + f * (b[2] - a[2])) / 1000
		end
	end
	return 1.0
end

-- The two light nibbles blended by a day-night ratio, which is what a node's
-- light *is* at an hour: blend_light() in Luanti's light.h, over
-- getLightBlend(). The ratio is carried 0...1000 the way the C++ carries it,
-- so this is Luanti's arithmetic rather than a rounding of it.
function core.blend_light(dnr, day, night)
	local l = math.floor((dnr * day + (1000 - dnr) * night) / 1000)
	if l > 15 then
		return 15
	end
	return l
end

-- What these have to come out as, checked at load against Luanti's own
-- numbers rather than against each other
do
	assert(core.is_yes("YES") and core.is_yes(" true ") and core.is_yes(1))
	assert(not core.is_yes("no") and not core.is_yes(0) and
			not core.is_yes(nil))
	assert(core.strip_escapes("a\27(T@x)b\27Fc") == "abc")
	assert(core.is_valid_player_name("nakki-_1"))
	assert(not core.is_valid_player_name("") and
			not core.is_valid_player_name("has space") and
			not core.is_valid_player_name(("x"):rep(21)))
	-- Noon takes the day nibble whole and midnight takes 175 thousandths of
	-- it, which is why a sunlit node reads 2 at night and not 15: that is
	-- what makes get_node_light(pos, 0) mean "light other than the sun"
	assert(core.blend_light(1000, 15, 0) == 15)
	assert(core.blend_light(175, 15, 0) == 2)
	assert(core.blend_light(0, 15, 0) == 0)
	assert(core.blend_light(1000, 0, 10) == 0)
	assert(core.blend_light(500, 15, 5) == 10)
	-- A lamp is in the night nibble, so it survives the hour
	assert(core.blend_light(175, 0, 14) == 11)
	-- Midnight is the floor, noon is full, and the ramp is between
	assert(core.time_to_day_night_ratio(0) == 0.175)
	assert(core.time_to_day_night_ratio(0.5) == 1.0)
	assert(core.time_to_day_night_ratio(6125 / 24000) == 1.0)
	local dawn = core.time_to_day_night_ratio(5125 / 24000)
	assert(dawn == 0.350, "the ramp is Luanti's own table: " .. dawn)
	-- And it is still climbing a hundred and twenty-five units before the
	-- top, which is what makes it a ramp and not a step
	local nearly = core.time_to_day_night_ratio(6000 / 24000)
	assert(nearly == 0.9375, "midway up the last step: " .. nearly)
end

-- vim: set noet ts=4 sw=4:
