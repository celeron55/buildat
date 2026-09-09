-- Buildat: extension/luanti_client/texmod.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's texture modifier language, turned into buildat.compose_image()
-- operations.
--
-- A texture name in a node definition is an expression:
--
--   default_dirt.png^mcl_dirt_grass_shadow.png
--   default_grass.png^[colorize:#5f9^[transformR90
--   [combine:32x16:0,0=a.png:16,0=(b.png^[multiply:red)
--
-- "^" chains: what is on the left is the image, what is on the right is done
-- to it. Parentheses group an expression into one image. Anything starting
-- with "[" is a modifier. The whole thing is read right to left, because the
-- last "^" separates the base from the last thing done to it, which is how
-- Luanti's own generateImage() reads it too.
--
-- parse() gives the parts of one chain; build() turns them into operations.
-- A part that is itself an expression -- a group, or one of [combine's pieces
-- -- becomes its own composition, and what refers to it is the name that one
-- was written under. ctx.compose() is what does that, so this file never
-- touches a file or an image.
--
-- An expression using something not implemented here comes back as nil, and
-- the caller draws whatever it draws for a texture it does not have. That is
-- the whole error handling: a texture is not worth failing a world over.

local M = {}

-- The named colours Luanti has that a texture expression is likely to use,
-- from its util/string.cpp. Everything else has to be written as #rgb, #rgba,
-- #rrggbb or #rrggbbaa.
--
-- simplified: sixteen of Luanti's hundred and forty. These are the ones this
-- game's node definitions use, which is the wool and dye palette; the upgrade
-- path is the rest of that table.
local NAMED_COLORS = {
	black = 0x000000, blue = 0x0000ff, brown = 0xa52a2a, cyan = 0x00ffff,
	green = 0x008000, grey = 0x808080, gray = 0x808080,
	lightblue = 0xadd8e6, lime = 0x00ff00, magenta = 0xff00ff,
	orange = 0xffa500, pink = 0xffc0cb, purple = 0x800080, red = 0xff0000,
	silver = 0xc0c0c0, white = 0xffffff, yellow = 0xffff00,
}

-- A Luanti ColorString: "#rgb", "#rgba", "#rrggbb", "#rrggbbaa" or a name.
-- Returns {r, g, b, a}, or nil.
function M.parse_color(s)
	if s == nil or s == "" then
		return nil
	end
	local named = NAMED_COLORS[s:lower()]
	if named then
		return {math.floor(named / 65536) % 256,
				math.floor(named / 256) % 256, named % 256, 255}
	end
	local hex = s:match("^#(%x+)$")
	if not hex then
		return nil
	end
	local function nib(i)
		return tonumber(hex:sub(i, i), 16) * 17
	end
	local function byte(i)
		return tonumber(hex:sub(i, i + 1), 16)
	end
	if #hex == 3 then
		return {nib(1), nib(2), nib(3), 255}
	elseif #hex == 4 then
		return {nib(1), nib(2), nib(3), nib(4)}
	elseif #hex == 6 then
		return {byte(1), byte(3), byte(5), 255}
	elseif #hex == 8 then
		return {byte(1), byte(3), byte(5), byte(7)}
	end
	return nil
end

-- Luanti escapes a character that would otherwise be a separator with a
-- backslash, so that a nested expression can hold a ":" or a "^"
local function unescape(s)
	return (s:gsub("\\(.)", "%1"))
end

-- Splits on an unescaped separator, at paren depth zero. Returns the pieces
-- with their escapes still in place, or nil for unbalanced parentheses.
local function split_top(expr, sep)
	local parts = {}
	local depth = 0
	local start = 1
	local i = 1
	while i <= #expr do
		local c = expr:sub(i, i)
		if c == "\\" then
			i = i + 1
		elseif c == "(" then
			depth = depth + 1
		elseif c == ")" then
			depth = depth - 1
			if depth < 0 then
				return nil
			end
		elseif c == sep and depth == 0 then
			parts[#parts + 1] = expr:sub(start, i - 1)
			start = i + 1
		end
		i = i + 1
	end
	if depth ~= 0 then
		return nil
	end
	parts[#parts + 1] = expr:sub(start)
	return parts
end

M.split_top = split_top

-- The eight symmetries of a square, as Luanti writes them: a name or a digit,
-- and several of them in a row multiply in the group. "R90" is 1, "FX" is 4,
-- "46" is a flip x and then a flip y, which is a rotation by 180.
local TRANSFORM_NAMES = {
	i = 0, r90 = 1, r180 = 2, r270 = 3, fx = 4, fy = 6,
}

function M.parse_transform(s)
	local total = 0
	local pos = 1
	while pos <= #s do
		local t = nil
		local digit = s:sub(pos, pos):match("^[0-7]$")
		if digit then
			t = tonumber(digit)
			pos = pos + 1
		else
			for name, value in pairs(TRANSFORM_NAMES) do
				if s:sub(pos, pos + #name - 1):lower() == name then
					t = value
					pos = pos + #name
					break
				end
			end
		end
		if not t then
			break
		end
		-- Multiplication in the dihedral group of the square
		local new_total
		if t < 4 then
			new_total = (t + total) % 4
		else
			new_total = (t - total + 8) % 4
		end
		if (t >= 4) ~= (total >= 4) then
			new_total = new_total + 4
		end
		total = new_total
	end
	return total
end

-- parse(expr) -> parts
--
-- parts is the chain in the order it is applied: a plain file name, a group,
-- or a modifier with its arguments as written. nil for unbalanced parentheses.
function M.parse(expr)
	local pieces = split_top(expr, "^")
	if not pieces then
		return nil
	end
	local parts = {}
	for _, piece in ipairs(pieces) do
		if piece == "" then
			-- "a.png^^b.png" and a trailing "^" are nothing at all, which is
			-- also what Luanti makes of them
		elseif piece:sub(1, 1) == "(" and piece:sub(-1) == ")" then
			parts[#parts + 1] = {kind = "group",
					expr = piece:sub(2, -2)}
		elseif piece:sub(1, 1) == "[" then
			local args = split_top(piece:sub(2), ":")
			if not args then
				return nil
			end
			local name = table.remove(args, 1)
			parts[#parts + 1] = {kind = "mod", name = name, args = args}
		else
			parts[#parts + 1] = {kind = "file", name = unescape(piece)}
		end
	end
	return parts
end

-- Which modifier arguments are themselves texture expressions, and so are
-- media names the server has to be asked for
local function each_sub_expression(part, cb)
	local name, args = part.name, part.args
	if name == "combine" then
		for i = 2, #args do
			local sub = args[i]:match("^[-%d]+,[-%d]+=(.*)$")
			if sub then
				cb(unescape(sub))
			end
		end
	elseif name == "mask" then
		cb(unescape(args[1] or ""))
	end
end

-- sources(expr, out) -> ok
--
-- Adds every plain file name the expression reaches to the set out. Returns
-- false for an expression that cannot be parsed at all; a modifier this does
-- not implement is still walked for its file names, because build() is what
-- decides whether the expression is usable.
function M.sources(expr, out)
	local parts = M.parse(expr)
	if not parts then
		return false
	end
	local ok = true
	for _, part in ipairs(parts) do
		if part.kind == "file" then
			if part.name ~= "" then
				out[part.name] = true
			end
		elseif part.kind == "group" then
			ok = M.sources(part.expr, out) and ok
		else
			each_sub_expression(part, function(sub)
				ok = M.sources(sub, out) and ok
			end)
		end
	end
	return ok
end

-- resolve(expr, ctx, extra) -> the resource name to draw with, or nil
--
-- ctx.resource(media_name) -> the resource name of a file the server sent, or
--   nil for one that is not here
-- ctx.compose(expr, ops, size) -> the resource name an expression's operations
--   were composed and saved under, or nil if that did not work
--
-- extra is {key = , ops = {...}}: compose_image operations to do after the
-- expression's own, with a key that tells the two results apart. What wants
-- it is a tile that is a strip of animation frames, which is not something
-- the expression says -- it is a property of the tile -- and which has to be
-- cropped to one frame before it goes in an atlas.
function M.resolve(expr, ctx, extra)
	-- A plain file name is already a texture; composing a copy of it would
	-- only cost a file
	if not extra and not expr:find("[%^%[%(]") then
		return ctx.resource(expr)
	end
	local ops, size = M.build(expr, {
		resource = ctx.resource,
		compose = function(sub) return M.resolve(sub, ctx) end,
	})
	if not ops then
		return nil
	end
	if extra then
		for _, op in ipairs(extra.ops) do
			ops[#ops + 1] = op
		end
		return ctx.compose(expr.."\0"..extra.key, ops, size)
	end
	return ctx.compose(expr, ops, size)
end

-- WxH, as [combine, [fill, [resize and [sheet write a size
local function parse_size(s)
	local w, h = tostring(s or ""):match("^(%d+)x(%d+)$")
	if not w then
		return nil
	end
	return {tonumber(w), tonumber(h)}
end

local function parse_pos(s)
	local x, y = tostring(s or ""):match("^(-?%d+),(-?%d+)$")
	if not x then
		return nil
	end
	return {tonumber(x), tonumber(y)}
end

-- build(expr, ctx) -> ops, size
--
-- ctx.resource(media_name) -> the resource name of a file the server sent, or
--   nil for one that is not here
-- ctx.compose(expr) -> the resource name of an expression composed on its own,
--   or nil if it could not be
--
-- Returns nil for an expression this cannot build. size is the canvas size
-- when the expression says what it is and nil when it comes from the first
-- image, which is what compose_image() works out for itself.
function M.build(expr, ctx)
	local parts = M.parse(expr)
	if not parts or #parts == 0 then
		return nil
	end
	local ops = {}
	local size = nil

	-- A file or a group in the middle of a chain is drawn over what is
	-- already there; the first one is what the canvas starts as. Luanti
	-- scales an overlay to the base image's size.
	--
	-- simplified: it scales the base to the overlay's when the overlay is
	-- the bigger one, which this does the other way round. The upgrade path
	-- is a resize of the canvas first, once something needs it.
	local function blit(resource)
		if #ops == 0 then
			ops[#ops + 1] = {op = "blit", src = resource}
		else
			ops[#ops + 1] = {op = "blit", src = resource, fill = true}
		end
	end

	for _, part in ipairs(parts) do
		if part.kind == "file" then
			local resource = ctx.resource(part.name)
			if not resource then
				return nil
			end
			blit(resource)
		elseif part.kind == "group" then
			local resource = ctx.compose(part.expr)
			if not resource then
				return nil
			end
			blit(resource)
		else
			local name, args = part.name, part.args
			if name == "combine" then
				local wh = parse_size(args[1])
				if not wh then
					return nil
				end
				if #ops == 0 then
					size = wh
				end
				for i = 2, #args do
					local x, y, sub = args[i]:match("^(-?%d+),(-?%d+)=(.*)$")
					if not sub then
						return nil
					end
					local resource = ctx.compose(unescape(sub))
					if not resource then
						return nil
					end
					ops[#ops + 1] = {op = "blit", src = resource,
							at = {tonumber(x), tonumber(y)}}
				end
			elseif name == "fill" then
				local wh = parse_size(args[1])
				if not wh then
					return nil
				end
				local at = parse_pos(args[2])
				local color = M.parse_color(at and args[3] or args[2])
				if not color then
					return nil
				end
				if #ops == 0 then
					size = wh
					ops[#ops + 1] = {op = "fill", color = color,
							at = at or {0, 0}, size = wh, blend = "set"}
				else
					ops[#ops + 1] = {op = "fill", color = color,
							at = at or {0, 0}, size = wh}
				end
			elseif name == "colorize" then
				local color = M.parse_color(args[1])
				if not color then
					return nil
				end
				-- No ratio, or "alpha", means the colour's own alpha is it
				local ratio = tonumber(args[2])
				if not ratio then
					ratio = color[4]
				end
				ops[#ops + 1] = {op = "colorize", color = color,
						ratio = ratio}
			elseif name == "multiply" or name == "screen" then
				local color = M.parse_color(args[1])
				if not color then
					return nil
				end
				if name == "multiply" then
					ops[#ops + 1] = {op = "multiply",
							color = {color[1], color[2], color[3], 255}}
				else
					ops[#ops + 1] = {op = "fill", color = color,
							blend = "screen"}
				end
			elseif name == "opacity" then
				local ratio = tonumber(args[1])
				if not ratio then
					return nil
				end
				ops[#ops + 1] = {op = "multiply",
						color = {255, 255, 255, ratio}}
			elseif name == "brighten" then
				-- Halfway to white, which is what Luanti's is
				ops[#ops + 1] = {op = "colorize",
						color = {255, 255, 255, 255}, ratio = 128}
			elseif name == "noalpha" then
				ops[#ops + 1] = {op = "alpha", value = 255}
			elseif name == "hsl" then
				ops[#ops + 1] = {op = "hsl",
						hue = tonumber(args[1]) or 0,
						saturation = tonumber(args[2]) or 0,
						lightness = tonumber(args[3]) or 0}
			elseif name:sub(1, 9) == "transform" then
				ops[#ops + 1] = {op = "transform",
						transform = M.parse_transform(name:sub(10))}
			elseif name == "resize" then
				local wh = parse_size(args[1])
				if not wh then
					return nil
				end
				ops[#ops + 1] = {op = "resize", size = wh}
			elseif name == "mask" then
				local resource = ctx.compose(unescape(args[1] or ""))
				if not resource then
					return nil
				end
				ops[#ops + 1] = {op = "blit", src = resource,
						fill = true, blend = "and"}
			elseif name == "verticalframe" then
				local count = tonumber(args[1])
				local index = tonumber(args[2])
				if not count or not index or count < 1 then
					return nil
				end
				if index >= count then
					index = count - 1
				end
				ops[#ops + 1] = {op = "crop", grid = {1, count},
						cell = {0, index}}
			elseif name == "sheet" then
				local wh = parse_size(args[1])
				local at = parse_pos(args[2])
				if not wh or not at then
					return nil
				end
				ops[#ops + 1] = {op = "crop", grid = wh, cell = at}
			else
				-- [crack, [inventorycube, [png, [invert, [contrast,
				-- [colorizehsl, [overlay, [hardlight, [lowpart, [makealpha,
				-- [applyfiltersformesh. This game's node definitions use one
				-- [lowpart and none of the rest.
				return nil
			end
		end
	end
	return ops, size
end

return M
-- vim: set noet ts=4 sw=4:
