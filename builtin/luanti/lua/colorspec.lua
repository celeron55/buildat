-- Buildat: builtin/luanti/lua/colorspec.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's ColorSpec: "#rgb", "#rgba", "#rrggbb", "#rrggbbaa", one of the
-- 148 CSS colour names, a {r, g, b, a} table, or a packed ARGB number. The
-- names are the list from Luanti's src/util/string.cpp, copied rather than
-- guessed, because a mod that asks for "peachpuff" means that colour.

local NAMED = {
	aliceblue = 0xf0f8ff,
	antiquewhite = 0xfaebd7,
	aqua = 0x00ffff,
	aquamarine = 0x7fffd4,
	azure = 0xf0ffff,
	beige = 0xf5f5dc,
	bisque = 0xffe4c4,
	black = 0x000000,
	blanchedalmond = 0xffebcd,
	blue = 0x0000ff,
	blueviolet = 0x8a2be2,
	brown = 0xa52a2a,
	burlywood = 0xdeb887,
	cadetblue = 0x5f9ea0,
	chartreuse = 0x7fff00,
	chocolate = 0xd2691e,
	coral = 0xff7f50,
	cornflowerblue = 0x6495ed,
	cornsilk = 0xfff8dc,
	crimson = 0xdc143c,
	cyan = 0x00ffff,
	darkblue = 0x00008b,
	darkcyan = 0x008b8b,
	darkgoldenrod = 0xb8860b,
	darkgray = 0xa9a9a9,
	darkgreen = 0x006400,
	darkgrey = 0xa9a9a9,
	darkkhaki = 0xbdb76b,
	darkmagenta = 0x8b008b,
	darkolivegreen = 0x556b2f,
	darkorange = 0xff8c00,
	darkorchid = 0x9932cc,
	darkred = 0x8b0000,
	darksalmon = 0xe9967a,
	darkseagreen = 0x8fbc8f,
	darkslateblue = 0x483d8b,
	darkslategray = 0x2f4f4f,
	darkslategrey = 0x2f4f4f,
	darkturquoise = 0x00ced1,
	darkviolet = 0x9400d3,
	deeppink = 0xff1493,
	deepskyblue = 0x00bfff,
	dimgray = 0x696969,
	dimgrey = 0x696969,
	dodgerblue = 0x1e90ff,
	firebrick = 0xb22222,
	floralwhite = 0xfffaf0,
	forestgreen = 0x228b22,
	fuchsia = 0xff00ff,
	gainsboro = 0xdcdcdc,
	ghostwhite = 0xf8f8ff,
	gold = 0xffd700,
	goldenrod = 0xdaa520,
	gray = 0x808080,
	green = 0x008000,
	greenyellow = 0xadff2f,
	grey = 0x808080,
	honeydew = 0xf0fff0,
	hotpink = 0xff69b4,
	indianred = 0xcd5c5c,
	indigo = 0x4b0082,
	ivory = 0xfffff0,
	khaki = 0xf0e68c,
	lavender = 0xe6e6fa,
	lavenderblush = 0xfff0f5,
	lawngreen = 0x7cfc00,
	lemonchiffon = 0xfffacd,
	lightblue = 0xadd8e6,
	lightcoral = 0xf08080,
	lightcyan = 0xe0ffff,
	lightgoldenrodyellow = 0xfafad2,
	lightgray = 0xd3d3d3,
	lightgreen = 0x90ee90,
	lightgrey = 0xd3d3d3,
	lightpink = 0xffb6c1,
	lightsalmon = 0xffa07a,
	lightseagreen = 0x20b2aa,
	lightskyblue = 0x87cefa,
	lightslategray = 0x778899,
	lightslategrey = 0x778899,
	lightsteelblue = 0xb0c4de,
	lightyellow = 0xffffe0,
	lime = 0x00ff00,
	limegreen = 0x32cd32,
	linen = 0xfaf0e6,
	magenta = 0xff00ff,
	maroon = 0x800000,
	mediumaquamarine = 0x66cdaa,
	mediumblue = 0x0000cd,
	mediumorchid = 0xba55d3,
	mediumpurple = 0x9370db,
	mediumseagreen = 0x3cb371,
	mediumslateblue = 0x7b68ee,
	mediumspringgreen = 0x00fa9a,
	mediumturquoise = 0x48d1cc,
	mediumvioletred = 0xc71585,
	midnightblue = 0x191970,
	mintcream = 0xf5fffa,
	mistyrose = 0xffe4e1,
	moccasin = 0xffe4b5,
	navajowhite = 0xffdead,
	navy = 0x000080,
	oldlace = 0xfdf5e6,
	olive = 0x808000,
	olivedrab = 0x6b8e23,
	orange = 0xffa500,
	orangered = 0xff4500,
	orchid = 0xda70d6,
	palegoldenrod = 0xeee8aa,
	palegreen = 0x98fb98,
	paleturquoise = 0xafeeee,
	palevioletred = 0xdb7093,
	papayawhip = 0xffefd5,
	peachpuff = 0xffdab9,
	peru = 0xcd853f,
	pink = 0xffc0cb,
	plum = 0xdda0dd,
	powderblue = 0xb0e0e6,
	purple = 0x800080,
	rebeccapurple = 0x663399,
	red = 0xff0000,
	rosybrown = 0xbc8f8f,
	royalblue = 0x4169e1,
	saddlebrown = 0x8b4513,
	salmon = 0xfa8072,
	sandybrown = 0xf4a460,
	seagreen = 0x2e8b57,
	seashell = 0xfff5ee,
	sienna = 0xa0522d,
	silver = 0xc0c0c0,
	skyblue = 0x87ceeb,
	slateblue = 0x6a5acd,
	slategray = 0x708090,
	slategrey = 0x708090,
	snow = 0xfffafa,
	springgreen = 0x00ff7f,
	steelblue = 0x4682b4,
	tan = 0xd2b48c,
	teal = 0x008080,
	thistle = 0xd8bfd8,
	tomato = 0xff6347,
	turquoise = 0x40e0d0,
	violet = 0xee82ee,
	wheat = 0xf5deb3,
	white = 0xffffff,
	whitesmoke = 0xf5f5f5,
	yellow = 0xffff00,
	yellowgreen = 0x9acd32,
}

-- ColorSpec -> r, g, b, a as 0..255, or nil for one that does not parse
local function parse(spec)
	if type(spec) == "number" then
		return math.floor(spec / 65536) % 256, math.floor(spec / 256) % 256,
				spec % 256, math.floor(spec / 16777216) % 256
	end
	if type(spec) == "table" then
		return math.floor(spec.r or spec[1] or 0),
				math.floor(spec.g or spec[2] or 0),
				math.floor(spec.b or spec[3] or 0),
				math.floor(spec.a or spec[4] or 255)
	end
	if type(spec) ~= "string" then
		return nil
	end
	local s = spec:match("^%s*(.-)%s*$"):lower()
	local hex = s:match("^#(%x+)$")
	if hex then
		local function nib(i)
			local d = tonumber(hex:sub(i, i), 16)
			return d * 16 + d
		end
		local function byte(i)
			return tonumber(hex:sub(i, i + 1), 16)
		end
		if #hex == 3 then
			return nib(1), nib(2), nib(3), 255
		elseif #hex == 4 then
			return nib(1), nib(2), nib(3), nib(4)
		elseif #hex == 6 then
			return byte(1), byte(3), byte(5), 255
		elseif #hex == 8 then
			return byte(1), byte(3), byte(5), byte(7)
		end
		return nil
	end
	-- "name" or "name#alpha", which is how Luanti writes a named colour with
	-- an alpha on it
	local name, alpha = s:match("^(%a+)#?(%x*)$")
	if name and NAMED[name] then
		local v = NAMED[name]
		local a = 255
		if alpha ~= "" then
			if #alpha == 1 then
				local d = tonumber(alpha, 16)
				a = d * 16 + d
			else
				a = tonumber(alpha:sub(1, 2), 16)
			end
		end
		return math.floor(v / 65536) % 256, math.floor(v / 256) % 256,
				v % 256, a
	end
	return nil
end

core.__parse_colorspec = parse

-- Four bytes, r g b a, which is what a mod hands to core.encode_png and what
-- builtin uses to turn a colour into a texture modifier
function core.colorspec_to_bytes(spec)
	local r, g, b, a = parse(spec)
	if r == nil then
		error("Invalid ColorSpec: " .. tostring(spec))
	end
	return string.char(r, g, b, a)
end

function core.colorspec_to_colorstring(spec)
	local r, g, b, a = parse(spec)
	if r == nil then
		return nil
	end
	return string.format("#%02X%02X%02X%02X", r, g, b, a)
end

function core.colorspec_to_table(spec)
	local r, g, b, a = parse(spec)
	if r == nil then
		return nil
	end
	return {r = r, g = g, b = b, a = a}
end

-- vim: set noet ts=4 sw=4:
