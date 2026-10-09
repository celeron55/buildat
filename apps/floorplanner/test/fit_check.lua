-- [FP_SAMPLE_FIT]'s fit: samples made from a known entry's look are fitted
-- back to it; samples no choice of the entry reaches change the species or
-- the finish; samples the entry already matches change nothing.
--   luajit apps/floorplanner/test/fit_check.lua
local dir = arg[0]:match("^(.*)/test/") or "."
package.path = dir .. "/main/client_lua/?.lua;" .. package.path
local F = require("fit")

local woods = {}
for line in io.lines(dir .. "/main/client_data/colors.txt") do
	local name, hex = line:match("^wood|([^|]+)|(%x+)")
	if name then
		woods[#woods + 1] = {name = name, rgb = tonumber(hex, 16)}
		woods[name] = tonumber(hex, 16)
	end
end
local function entry(o)
	local p = {kind = 1, base = woods.Oak, color = 0xffffff, finish = 0,
		opacity = 500, contrast = 1000, color2 = 0x404040}
	for k, v in pairs(o) do p[k] = v end
	return p
end
local function samples_of(p)
	local l = F.look(p)
	return {l[1], l[2], l[3]}
end
local function near(a, b, units)
	for s = 0, 16, 8 do
		if math.abs(math.floor(a / 2 ^ s) % 256 - math.floor(b / 2 ^ s) % 256) >
				units then
			return false
		end
	end
	return true
end
local function value(r, p, k)
	if r.ints[k] ~= nil then return r.ints[k] end
	return p[k]
end

-- Over its colour: the paint and the contrast come back
local want = entry({color = 0xe0c8b0, contrast = 1500})
local from = entry({})
local r = F.fit(from, samples_of(want), woods)
assert(value(r, from, "base") == woods.Oak, "the species stays")
assert(near(value(r, from, "color"), 0xe0c8b0, 3),
		string.format("paint %06x", value(r, from, "color")))
assert(math.abs(value(r, from, "contrast") - 1500) <= 30,
		"contrast " .. value(r, from, "contrast"))
assert(r.err < 2, "err " .. r.err)

-- A stain whose paint has a black channel: the least opaque stain that
-- reaches it is that one
want = entry({base = woods.Pine, finish = 2, opacity = 400, color = 0x6b3a00,
	contrast = 800})
from = entry({base = woods.Pine, finish = 2, opacity = 200, color = 0x804020})
r = F.fit(from, samples_of(want), woods)
assert(value(r, from, "base") == woods.Pine and value(r, from, "finish") == 2)
assert(math.abs(value(r, from, "opacity") - 400) <= 5,
		"stain " .. value(r, from, "opacity"))
assert(near(value(r, from, "color"), 0x6b3a00, 4),
		string.format("stain paint %06x", value(r, from, "color")))
assert(math.abs(value(r, from, "contrast") - 800) <= 30)

-- Walnut's look on a spruce over its colour: a dark paint reaches it, and
-- the spruce stays
from = entry({base = woods.Spruce})
r = F.fit(from, samples_of(entry({base = woods.Walnut})), woods)
assert(value(r, from, "base") == woods.Spruce and r.err < 2, "err " .. r.err)
-- Spruce's on a walnut: lighter than any paint makes it, so the species or
-- the finish changes
from = entry({base = woods.Walnut})
r = F.fit(from, samples_of(entry({base = woods.Spruce, contrast = 700})), woods)
assert(value(r, from, "base") ~= woods.Walnut or value(r, from, "finish") ~= 0)
assert(r.err < 2, "err " .. r.err)

-- What the entry already looks like: nothing changes
for _, p in ipairs({entry({color = 0xd0c0b0}), entry({kind = 10}),
		entry({kind = 0, base = 0xe8e4dc, color = 0xf0f0f0})}) do
	r = F.fit(p, samples_of(p), woods)
	assert(next(r.ints) == nil, "changed " .. table.concat(r.changes, ", "))
	-- and one sample, its mean, keeps the contrast
	r = F.fit(p, {F.look(p)[4]}, woods)
	assert(r.ints.contrast == nil)
end

-- White undercoat: the paint is the samples' linear mean
from = entry({kind = 0, base = 0xe8e4dc, finish = 1})
r = F.fit(from, {0xff0000, 0x0000ff}, woods)
assert(r.ints.color == 0xba00ba, string.format("%06x", r.ints.color or -1))

-- Drywall over its colour, lighter than its own: the own colour is raised
from = entry({kind = 0, base = 0x808080})
r = F.fit(from, {0xe0e0d8}, woods)
assert(r.err < 1 and r.ints.base, "err " .. r.err)

-- Stone: grey samples with dark veins give the own colour and the veins
from = entry({kind = 2, base = 0x9a968e, color2 = 0x5a5650})
r = F.fit(from, {0xa0a0a0, 0xa8a8a4, 0x9c9c98, 0xa4a0a0, 0x302820, 0x282018},
		woods)
assert(near(value(r, from, "color2"), 0x2c241c, 3),
		string.format("veins %06x", value(r, from, "color2")))
assert(F.de(r.look[4], 0xa0a09e) < 2)

-- Lamp: no fit
assert(F.fit(entry({kind = 4}), {0xffffff}, woods) == nil)

-- The samples as kept
local list = F.parse(F.format({{rgb = 0x123456, name = "Oak; old"},
	{rgb = 0xabcdef, name = ""}}))
assert(#list == 2 and list[1].rgb == 0x123456 and list[1].name == "Oak, old" and
		list[2].rgb == 0xabcdef and list[2].name == "")
print("PASS: fit_check")
