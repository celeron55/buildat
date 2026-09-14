-- Buildat: builtin/luanti/client_lua/formspec.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Copied from extensions/luanti_client/formspec.lua, which is where it was written
-- and where its own history is; edit it there and copy it here, or the other
-- way round, rather than letting the two drift.
--
-- Luanti's formspecs, which are the windows a server puts on the screen: the
-- player's inventory, a chest, a furnace, whatever a mod asks for.
--
-- A formspec is a string of elements one after another, each
-- "name[field;field;...]":
--
--   size[8,7.5]list[current_player;main;0,3.5;8,4;]
--
-- A field may hold a position or a size as "x,y". A backslash escapes what
-- would otherwise end a field or an element. container[x,y] shifts everything
-- until the matching container_end[] , which is resolved here so that what
-- comes out is one flat list with absolute positions.
--
-- What is not here is the drawing; parse() only says what the elements are.
-- Nothing in this file knows about Urho3D.

local M = {}

-- Luanti's own coordinate arithmetic, from its gui/guiFormSpecMenu.cpp.
--
-- Everything is in units of one inventory slot, and how many pixels that is
-- comes out of the screen size: the form is made to fit with a twentieth of
-- the screen spare on each side, but never bigger than a fifteenth of the
-- smaller screen dimension per slot.
--
-- Before formspec version 2 the units were not slots but slots plus their
-- spacing, and an element's position had a fixed padding added to it. A form
-- says which it is by its formspec_version, or by real_coordinates[].
M.PADDING = 0.05

function M.layout(size, real_coordinates, screen_w, screen_h)
	local pw = screen_w * (1 - M.PADDING * 2)
	local ph = screen_h * (1 - M.PADDING * 2)
	local prefer = math.min(screen_w, screen_h) / 15
	local imgsize
	if real_coordinates then
		imgsize = math.min(prefer, pw / size[1], ph / size[2])
		return {
			imgsize = imgsize,
			-- Where an element's x,y lands, and how big its w,h is
			scale = {imgsize, imgsize},
			origin = {0, 0},
			-- One slot of a list, and the step from one to the next
			slot = imgsize,
			slot_step = imgsize * 1.25,
			width = size[1] * imgsize,
			height = size[2] * imgsize,
		}
	end
	imgsize = math.min(prefer,
			pw / (5 / 4 * (0.5 + size[1])),
			ph / (15 / 13 * (0.85 + size[2])))
	local sx, sy = imgsize * 5 / 4, imgsize * 15 / 13
	return {
		imgsize = imgsize,
		scale = {sx, sy},
		origin = {imgsize * 3 / 8, imgsize * 3 / 8},
		slot = imgsize,
		slot_step = sx,
		width = size[1] * sx + imgsize * 3 / 4,
		height = size[2] * sy + imgsize * 3 / 4,
	}
end

-- Luanti's translation and colour markup: an escape character, then either
-- (something) or a single letter. A client that does not translate has
-- nothing to do with it but take it out.
local function strip_escapes(s)
	s = s:gsub("\27%b()", "")
	s = s:gsub("\27.", "")
	return s
end

M.strip_escapes = strip_escapes

-- The colours Luanti's own markup names by word rather than by number.
--
-- simplified: the ones a mod actually writes. Luanti takes the whole CSS
-- list; a name that is not here is drawn in whatever colour the line
-- already had, which is what a client that did not understand it would do.
local COLOR_NAMES = {
	white = "#ffffff", black = "#000000", red = "#ff0000",
	green = "#008000", lime = "#00ff00", blue = "#0000ff",
	yellow = "#ffff00", cyan = "#00ffff", aqua = "#00ffff",
	magenta = "#ff00ff", fuchsia = "#ff00ff", orange = "#ffa500",
	pink = "#ffc0cb", purple = "#800080", brown = "#a52a2a",
	gray = "#808080", grey = "#808080", silver = "#c0c0c0",
	gold = "#ffd700", darkgray = "#a9a9a9", darkgrey = "#a9a9a9",
	lightgray = "#d3d3d3", lightgrey = "#d3d3d3",
}

-- "#rgb", "#rrggbb", "#rrggbbaa" or a name, as three numbers between zero
-- and one; nil for anything else
local function color_of(spec)
	spec = COLOR_NAMES[string.lower(spec or "")] or spec or ""
	local hex = string.match(spec, "^#(%x+)$")
	if hex == nil then
		return nil
	end
	if #hex == 3 or #hex == 4 then
		hex = string.gsub(string.sub(hex, 1, 3), "(%x)", "%1%1")
	end
	if #hex ~= 6 and #hex ~= 8 then
		return nil
	end
	return {
		r = tonumber(string.sub(hex, 1, 2), 16) / 255,
		g = tonumber(string.sub(hex, 3, 4), 16) / 255,
		b = tonumber(string.sub(hex, 5, 6), 16) / 255,
	}
end

M.color_of = color_of

-- A line as the pieces it is drawn in: Luanti's own colour markup says where
-- a colour starts and every piece runs until the next one. A string with no
-- markup in it is one piece with no colour of its own, which is the common
-- case and costs one table.
--
-- The escape is \27 and then either (word@argument) or a single letter; a
-- "c" is a colour and a "b" is a background colour, which nothing here
-- draws. What is not markup at all is text.
function M.split_colors(s)
	s = s or ""
	if string.find(s, "\27", 1, true) == nil then
		return {{text = s}}
	end
	local out = {}
	local color = nil
	local at = 1
	while at <= #s do
		local e = string.find(s, "\27", at, true)
		if e == nil then
			break
		end
		if e > at then
			out[#out + 1] = {text = string.sub(s, at, e - 1), color = color}
		end
		local rest = string.sub(s, e + 1)
		local body = string.match(rest, "^(%b())")
		if body then
			at = e + 1 + #body
			local word, arg = string.match(body, "^%((%a+)@(.*)%)$")
			if word == "c" then
				color = color_of(arg) or color
			end
		else
			-- A single letter, which is a translation marker and not ours
			at = e + 2
		end
	end
	if at <= #s then
		out[#out + 1] = {text = string.sub(s, at), color = color}
	end
	if #out == 0 then
		out[#out + 1] = {text = ""}
	end
	return out
end

local function unescape(s)
	return (s:gsub("\\(.)", "%1"))
end

M.unescape = unescape

-- Splits on an unescaped separator
local function split(s, sep)
	local parts = {}
	local start = 1
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 1
		elseif c == sep then
			parts[#parts + 1] = s:sub(start, i - 1)
			start = i + 1
		end
		i = i + 1
	end
	parts[#parts + 1] = s:sub(start)
	return parts
end

M.split = split

-- "1.5,-2" -> {1.5, -2}, or nil
function M.parse_v2(s)
	local a, b = s:match("^%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)%s*$")
	if not a then
		return nil
	end
	return {tonumber(a), tonumber(b)}
end

-- parse(spec) -> elements, size, real_coordinates
--
-- elements is an array of {name =, fields = {...}, raw = {...}, at = {x, y}},
-- where at is the container offset in force, already added to the element's
-- own position if it has one, and raw is the fields with their escapes still
-- in. size is what size[] said, defaulting to a small window.
function M.parse(spec)
	local elements = {}
	local size = {10, 10}
	local version = 1
	local real = nil
	local offset = {0, 0}
	local stack = {}
	local i = 1
	while i <= #spec do
		-- An element is a name, then its fields in brackets
		local name_start = i
		while i <= #spec and spec:sub(i, i) ~= "[" do
			i = i + 1
		end
		if i > #spec then
			break
		end
		-- A formspec a mod built out of lines has whitespace between its
		-- elements, and it belongs to neither of them; Luanti trims the same
		-- way. Without this every element after the first newline is a
		-- name nothing knows and the form comes out empty.
		local name = spec:sub(name_start, i - 1):match("^%s*(.-)%s*$")
		i = i + 1
		local body_start = i
		while i <= #spec do
			local c = spec:sub(i, i)
			if c == "\\" then
				i = i + 1
			elseif c == "]" then
				break
			end
			i = i + 1
		end
		local body = spec:sub(body_start, math.min(i, #spec) - 1)
		i = i + 1

		local fields = split(body, ";")
		-- The fields as they were written as well: a field that is itself a
		-- list -- a table's cells, a dropdown's items -- has to be split on
		-- its commas before the escapes in it are taken out, or a cell with
		-- a comma of its own turns into two
		local raw = {}
		for k, v in ipairs(fields) do
			raw[k] = v
			fields[k] = unescape(v)
		end

		if name == "size" then
			local v = M.parse_v2(fields[1] or "")
			if v then
				size = v
			end
		elseif name == "formspec_version" then
			version = tonumber(fields[1]) or 1
		elseif name == "real_coordinates" then
			real = fields[1] == "true"
		elseif name == "container" then
			local v = M.parse_v2(fields[1] or "")
			stack[#stack + 1] = offset
			offset = {offset[1] + (v and v[1] or 0),
					offset[2] + (v and v[2] or 0)}
		elseif name == "container_end" then
			offset = table.remove(stack) or {0, 0}
		else
			elements[#elements + 1] = {
				name = name, fields = fields, raw = raw, at = offset,
			}
		end
	end
	if real == nil then
		real = version >= 2
	end
	return elements, size, real
end

return M
-- vim: set noet ts=4 sw=4:
