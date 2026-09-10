-- Buildat: extension/luanti_client/hud.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The HUD the server describes: HUDADD, HUDRM, HUDCHANGE, HUD_SET_FLAGS and
-- HUD_SET_PARAM.
--
-- A game puts its own things on the screen through these -- this one's hearts,
-- its bubbles, its armour bar, its experience bar and the number on it, about
-- a hundred elements in all -- and until they are drawn the player sees a
-- health bar this client made up instead. The flags are the other half of it:
-- they are how a game turns the client's own hotbar, health bar, crosshair
-- and chat off, which a game that draws its own has every reason to do.
--
-- What is here is the reading and the arithmetic, which is what can be
-- checked without a screen. Where the elements go on the screen is Luanti's
-- own drawLuaElements; formspec_ui.lua turns what comes out into Urho3D
-- elements.

local M = {}

-- Luanti's HudElementType
M.ELEM = {
	IMAGE = 0,
	TEXT = 1,
	STATBAR = 2,
	INVENTORY = 3,
	WAYPOINT = 4,
	IMAGE_WAYPOINT = 5,
	COMPASS = 6,
	MINIMAP = 7,
	HOTBAR = 8,
}

-- Luanti's HUD_FLAG_*, and what they are all set to before a server says
-- otherwise
M.FLAG = {
	hotbar = 1,
	healthbar = 2,
	crosshair = 4,
	wielditem = 8,
	breathbar = 16,
	minimap = 32,
	minimap_radar = 64,
	basic_debug = 128,
	chat = 256,
}
M.FLAGS_DEFAULT = 511

-- Luanti's HUD_PARAM_*
M.PARAM_HOTBAR_ITEMCOUNT = 1
M.PARAM_HOTBAR_IMAGE = 2
M.PARAM_HOTBAR_SELECTED_IMAGE = 3
M.HOTBAR_ITEMCOUNT_MAX = 32

-- Which field of an element HUDCHANGE's stat number names, in Luanti's
-- HudElementStat order, and what type it carries
local STAT = {
	[0] = {"pos", "v2f"},
	[1] = {"name", "string"},
	[2] = {"scale", "v2f"},
	[3] = {"text", "string"},
	[4] = {"number", "u32"},
	[5] = {"item", "u32"},
	[6] = {"dir", "u32"},
	[7] = {"align", "v2f"},
	[8] = {"offset", "v2f"},
	[9] = {"world_pos", "v3f"},
	[10] = {"size", "size"},
	[11] = {"z_index", "u32"},
	[12] = {"text2", "string"},
	[13] = {"style", "u32"},
	[14] = {"hideable", "u32"},
}

-- Lua 5.1 has no bitwise operators, and these are nine bits of one number
local function bit_of(v, mask)
	return math.floor(v / mask) % 2 == 1
end

function M.has_flag(flags, flag)
	return bit_of(flags, flag)
end

-- What HUD_SET_FLAGS does: the bits in the mask take the value the packet
-- gives and the rest stay as they were
function M.apply_flags(current, flags, mask)
	local out = 0
	local bit = 1
	for _ = 1, 16 do
		local take = bit_of(mask, bit) and flags or current
		if bit_of(take, bit) then
			out = out + bit
		end
		bit = bit * 2
	end
	return out
end

local function read_v2f(r)
	local x = r:f32()
	local y = r:f32()
	return {x, y}
end

-- A size is a pair of floats from protocol 52 and a pair of ints below it,
-- which is the one version split in these packets
local function read_size(r, proto)
	if proto and proto >= 52 then
		return read_v2f(r)
	end
	local x = r:s32()
	local y = r:s32()
	return {x, y}
end

-- HUDADD: one element, and its id. The last four fields were each added in a
-- later 5.x, so a server that predates one of them simply stops sending and
-- what is left keeps its default.
function M.read_add(r, proto)
	local id = r:u32()
	local e = {}
	e.type = r:u8()
	e.pos = read_v2f(r)
	e.name = r:string()
	e.scale = read_v2f(r)
	e.text = r:string()
	e.number = r:u32()
	e.item = r:u32()
	e.dir = r:u32()
	e.align = read_v2f(r)
	e.offset = read_v2f(r)
	e.world_pos = {r:v3f()}
	e.size = read_size(r, proto)
	e.z_index = 0
	e.text2 = ""
	e.style = 0
	e.hideable = 1
	if r:remaining() >= 2 then
		e.z_index = r:s16()
	end
	if r:remaining() >= 2 then
		e.text2 = r:string()
	end
	if r:remaining() >= 4 then
		e.style = r:u32()
	end
	if r:remaining() >= 1 then
		e.hideable = r:u8()
	end
	return id, e
end

-- HUDCHANGE: one field of one element. What comes back is the id, the field's
-- name and its new value, or nil for a stat number this does not know -- which
-- is what Luanti does with one too, because the rest of the packet cannot be
-- read without knowing which type it holds.
function M.read_change(r, proto)
	local id = r:u32()
	local stat = STAT[r:u8()]
	if not stat then
		return id, nil, nil
	end
	local name, kind = stat[1], stat[2]
	if kind == "v2f" then
		return id, name, read_v2f(r)
	elseif kind == "v3f" then
		return id, name, {r:v3f()}
	elseif kind == "string" then
		return id, name, r:string()
	elseif kind == "size" then
		return id, name, read_size(r, proto)
	end
	return id, name, r:u32()
end

-- HUD_SET_PARAM carries its value as a string whatever it means; the item
-- count is a big-endian s32 in it.
function M.read_param(r)
	local param = r:u16()
	local value = r:string()
	if param == M.PARAM_HOTBAR_ITEMCOUNT then
		if #value ~= 4 then
			return param, nil
		end
		local b1, b2, b3, b4 = string.byte(value, 1, 4)
		local n = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
		if n >= 0x80000000 then
			n = n - 0x100000000
		end
		if n < 1 or n > M.HOTBAR_ITEMCOUNT_MAX then
			return param, nil
		end
		return param, n
	end
	return param, value
end

-- The colour in an element's number field: 0xRRGGBB with the alpha in the top
-- byte, and an alpha of zero means opaque rather than invisible, which is
-- what Luanti does for the servers that never set it.
function M.color_of(number)
	local a = math.floor(number / 0x1000000) % 256
	if a == 0 then
		a = 255
	end
	return math.floor(number / 0x10000) % 256,
			math.floor(number / 0x100) % 256,
			number % 256, a
end

-- How big an image element is drawn: a positive scale multiplies the image's
-- own size and a negative one is a percentage of the screen. Luanti's
-- drawLuaElements does the same.
function M.image_size(e, screen_w, screen_h, image_w, image_h)
	local w = e.scale[1] >= 0 and image_w * e.scale[1] or
			screen_w * (-e.scale[1] / 100)
	local h = e.scale[2] >= 0 and image_h * e.scale[2] or
			screen_h * (-e.scale[2] / 100)
	return math.floor(w), math.floor(h)
end

-- Where an element's top left corner goes, in pixels. pos is a fraction of
-- the screen and align says which side of that the element sits on: -1 puts
-- the whole of it left of and above the point, 1 right of and below it, 0
-- centres it on the point. offset is pixels on top of that.
function M.place(e, screen_w, screen_h, w, h)
	local x = math.floor(e.pos[1] * screen_w) +
			(e.align[1] - 1) * w / 2 + e.offset[1]
	local y = math.floor(e.pos[2] * screen_h) +
			(e.align[2] - 1) * h / 2 + e.offset[2]
	return math.floor(x), math.floor(y)
end

-- Which way a statbar's icons march, per HUD_DIR_*: left to right, right to
-- left, top to bottom, bottom to top
local STATBAR_STEP = {
	[0] = {1, 0},
	[1] = {-1, 0},
	[2] = {0, 1},
	[3] = {0, -1},
}

-- A statbar's icons in the order they are drawn, each
-- {x, y, w, h, src, bg}: the background ones for its maximum first, marked
-- bg, and then the ones that are on over them. src is the part of the texture
-- the icon shows, as fractions of it, which is the whole of it except for the
-- half icon an odd count ends in.
--
-- Luanti counts a statbar in halves -- number is twice the value and item
-- twice the maximum -- so an odd count ends in half an icon, cut on the side
-- the icons come from. size is the size to draw one at, or {0, 0} for the
-- image's own, and has_bg says whether the element named a background
-- texture, without which Luanti draws no maximum at all.
function M.statbar_icons(e, screen_w, screen_h, image_w, image_h, has_bg)
	local w = e.size[1] > 0 and e.size[1] or image_w
	local h = e.size[2] > 0 and e.size[2] or image_h
	local step = STATBAR_STEP[e.dir] or STATBAR_STEP[0]
	local x0, y0 = M.place(e, screen_w, screen_h, 0, 0)
	local out = {}

	-- Half an icon is the half of it the icons come from, so a bar that
	-- grows to the right keeps the left half of the image: dest is half as
	-- wide and src is the half of the texture that half shows, as fractions
	-- of it.
	local half_src = {0, 0, 1, 1}
	if step[1] > 0 then
		half_src = {0, 0, 0.5, 1}
	elseif step[1] < 0 then
		half_src = {0.5, 0, 1, 1}
	elseif step[2] > 0 then
		half_src = {0, 0, 1, 0.5}
	elseif step[2] < 0 then
		half_src = {0, 0.5, 1, 1}
	end

	local function icons(count)
		for i = 0, math.floor(count / 2) - 1 do
			out[#out + 1] = {x = x0 + step[1] * w * i, y = y0 + step[2] * h * i,
					w = w, h = h, src = {0, 0, 1, 1}}
		end
		if count % 2 == 1 then
			local i = math.floor(count / 2)
			out[#out + 1] = {
				x = x0 + step[1] * w * i + (step[1] < 0 and w / 2 or 0),
				y = y0 + step[2] * h * i + (step[2] < 0 and h / 2 or 0),
				w = step[1] ~= 0 and w / 2 or w,
				h = step[2] ~= 0 and h / 2 or h,
				src = half_src,
			}
		end
	end

	-- The background is the maximum, drawn first so the value covers it
	if has_bg then
		icons(e.item)
		for _, icon in ipairs(out) do
			icon.bg = true
		end
	end
	icons(e.number)
	return out
end

return M
-- vim: set noet ts=4 sw=4:
