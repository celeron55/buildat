-- Buildat: builtin/luanti/lua/png.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- core.encode_png(). The data is either a string of raw RGBA bytes or an
-- array of ColorSpecs, one per pixel, row by row -- both of which Luanti
-- takes. The encoder itself is stb_image_write, in luanti.cpp.
--
-- Luanti reduces the colour type of what it writes: an image with no
-- transparency comes out RGB, and one that is grey all through comes out
-- grey. That is not a detail -- devtest checks the byte -- so it is done
-- here, before the bytes go to C.

local parse = core.__parse_colorspec

-- ColorSpecs or raw bytes -> a string of w*h*4 bytes
local function to_rgba(w, h, data)
	local n = w * h
	if type(data) == "string" then
		if #data ~= n * 4 then
			error("encode_png: " .. #data .. " bytes for " .. w .. "x" .. h)
		end
		return data
	end
	if type(data) ~= "table" then
		error("encode_png: data is a " .. type(data))
	end
	if #data ~= n then
		error("encode_png: " .. #data .. " pixels for " .. w .. "x" .. h)
	end
	local out = {}
	for i = 1, n do
		local r, g, b, a = parse(data[i])
		if r == nil then
			error("encode_png: pixel " .. i .. " is not a ColorSpec")
		end
		out[i] = string.char(r, g, b, a)
	end
	return table.concat(out)
end

-- 4, 3 or 1: what the image actually needs
local function component_count(rgba)
	local components = 1
	for i = 1, #rgba, 4 do
		local r, g, b, a = rgba:byte(i, i + 3)
		if a ~= 255 then
			return 4
		end
		if r ~= g or g ~= b then
			components = 3
		end
	end
	return components
end

local function reduce(rgba, components)
	if components == 4 then
		return rgba
	end
	local out = {}
	local j = 0
	for i = 1, #rgba, 4 do
		local r, g, b = rgba:byte(i, i + 2)
		j = j + 1
		if components == 3 then
			out[j] = string.char(r, g, b)
		else
			out[j] = string.char(r)
		end
	end
	return table.concat(out)
end

function core.encode_png(w, h, data, compression)
	w = math.floor(w)
	h = math.floor(h)
	local rgba = to_rgba(w, h, data)
	local components = component_count(rgba)
	return __luanti_encode_png(w, h, components, reduce(rgba, components))
end

-- vim: set noet ts=4 sw=4:
