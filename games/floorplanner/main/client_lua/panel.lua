-- Buildat: games/floorplanner/main/client_lua/panel.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The few widgets the editor's panels are made of, on the default style
-- init.lua sets. A panel is rebuilt whole when what it shows changes.
local magic = require("buildat/extension/urho3d")
local M = {}

-- A window at a corner of the screen: halign/valign as SetAlignment takes
function M.window(halign, valign, x, y, horizontal)
	local w = magic.ui.root:CreateChild("Window")
	w:SetStyleAuto()
	w:SetLayout(horizontal and magic.LM_HORIZONTAL or magic.LM_VERTICAL, 4,
			magic.IntRect(6, 6, 6, 6))
	w:SetAlignment(halign, valign)
	w:SetPosition(x, y)
	w.opacity = 0.92
	return w
end

function M.row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

function M.label(parent, text, color)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	if color then
		t:SetColor(color)
	end
	return t
end

-- on_click(); `down` draws it pressed (the current tool, a set toggle)
function M.button(parent, text, on_click, down, min_width)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 24
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = math.max(min_width or 24, t.width + 16)
	if down then
		t:SetColor(magic.Color(1.0, 0.85, 0.3))
		b.selected = true
	end
	magic.SubscribeToEvent(b, "Released", function()
		on_click()
	end)
	return b
end

-- A labelled text field; on_finish(text) when Enter is pressed in it
function M.field(parent, label, value, on_finish, width)
	local r = M.row(parent)
	local l = M.label(r, label)
	l.minWidth = 112
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 22
	e.minWidth = width or 90
	e.textCopyable = true
	e.textSelectable = true
	e:SetText(tostring(value))
	magic.SubscribeToEvent(e, "TextFinished", function()
		on_finish(e:GetText())
		magic.ui:SetFocusElement(nil)
	end)
	return e, r
end

-- A palette row: one button with the colour and the label on it, so the
-- label is as much the thing to click as the colour is
function M.swatch_row(parent, rgb, text, on_click, down, text_color)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(4, 3, 6, 3))
	b.minHeight = 24
	local face = b:CreateChild("BorderImage")
	face:SetFixedSize(16, 16)
	face.color = magic.Color(math.floor(rgb / 65536) % 256 / 255,
			math.floor(rgb / 256) % 256 / 255, rgb % 256 / 255)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	if text_color then
		t:SetColor(text_color)
	end
	if down then
		b.selected = true
	end
	magic.SubscribeToEvent(b, "Released", function()
		on_click()
	end)
	return b
end

local function to_color(rgb, a)
	return magic.Color(math.floor(rgb / 65536) % 256 / 255,
			math.floor(rgb / 256) % 256 / 255, rgb % 256 / 255, a or 1)
end

-- h, s, v in 0..1 to 0xrrggbb and back
function M.hsv_rgb(h, s, v)
	local i = math.floor(h * 6) % 6
	local f = h * 6 - math.floor(h * 6)
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local c = ({{v, t, p}, {q, v, p}, {p, v, t}, {p, q, v}, {t, p, v},
			{v, p, q}})[i + 1]
	local function b(x) return math.floor(x * 255 + 0.5) end
	return b(c[1]) * 65536 + b(c[2]) * 256 + b(c[3])
end

function M.rgb_hsv(rgb)
	local r = math.floor(rgb / 65536) % 256 / 255
	local g = math.floor(rgb / 256) % 256 / 255
	local b = rgb % 256 / 255
	local mx, mn = math.max(r, g, b), math.min(r, g, b)
	local d = mx - mn
	local h = 0
	if d > 0 then
		if mx == r then
			h = ((g - b) / d) % 6
		elseif mx == g then
			h = (b - r) / d + 2
		else
			h = (r - g) / d + 4
		end
		h = h / 6
	end
	return h, mx > 0 and d / mx or 0, mx
end

for _, rgb in ipairs({0x000000, 0xffffff, 0xff0000, 0x00ff00, 0x0000ff,
		0xc49a6c, 0x4f5357, 0x123456}) do
	assert(M.hsv_rgb(M.rgb_hsv(rgb)) == rgb,
			string.format("hsv round trip %06x", rgb))
end

-- The wheel: hue around, saturation outwards, at full value; the picker
-- dims it by the value it has. The image is made once and a texture of it
-- for each window: the engine frees a texture made in Lua with the last
-- element that used it, and a kept handle then points at nothing.
local WHEEL = 144
local wheel_image = nil
local function wheel()
	if wheel_image then
		local t = magic.Texture2D:new()
		t:SetNumLevels(1)
		assert(t:SetData(wheel_image), "Texture2D:SetData")
		return t
	end
	local image = magic.Image:new()
	assert(image:SetSize(WHEEL, WHEEL, 4), "Image:SetSize")
	local c = (WHEEL - 1) / 2
	for y = 0, WHEEL - 1 do
		for x = 0, WHEEL - 1 do
			local dx, dy = x - c, y - c
			local s = math.sqrt(dx * dx + dy * dy) / c
			if s <= 1 then
				local rgb = M.hsv_rgb((math.atan2(-dy, dx) / (2 * math.pi)) % 1,
						s, 1)
				image:SetPixel(x, y, to_color(rgb))
			else
				image:SetPixel(x, y, magic.Color(0, 0, 0, 0))
			end
		end
	end
	wheel_image = image
	return wheel()
end

-- A small button of one colour; on_hover(text) as the pointer comes on it
function M.chip(parent, rgb, size, on_click, on_hover, text)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetFixedSize(size + 4, size + 4)
	b:SetLayout(magic.LM_HORIZONTAL, 0, magic.IntRect(2, 2, 2, 2))
	local face = b:CreateChild("BorderImage")
	face:SetFixedSize(size, size)
	face.color = to_color(rgb)
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
	if on_hover then
		magic.SubscribeToEvent(b, "HoverBegin", function() on_hover(text) end)
	end
	return b
end

-- Many named colours at a glance: a column per row of `rows` (a paint
-- maker's hue family, lightest at the top), BAND columns to a band. One
-- texel a colour, drawn TILE px big with nearest filtering, so two thousand
-- are one small image; a click picks by the pointer, as the wheel does.
local SHEET_BAND, SHEET_TILE = 95, 8

-- The pointer in UI coordinates
local function pointer()
	local p = magic.input:GetMousePosition()
	local sc = magic.ui.scale
	return p.x / sc, p.y / sc
end

-- The sheet's entry under the pointer, or nil
local sheet = nil -- {button, cols, say(text)} of the window up now
local function sheet_entry()
	local at = sheet.button.screenPosition
	local px, py = pointer()
	local x = math.floor((px - at.x) / SHEET_TILE)
	local y = math.floor((py - at.y) / SHEET_TILE)
	if x < 0 or y < 0 or x >= SHEET_BAND then
		return nil
	end
	local col = sheet.cols[math.floor(y / 13) * SHEET_BAND + x + 1]
	return col and col[y % 13 + 1]
end
-- The name of the tile under the pointer, as a chip says its own
magic.SubscribeToEvent("MouseMove", function()
	if sheet then
		-- A window taken down some other way (a plan closed under it) is
		-- forgotten rather than asked again
		local ok, n = pcall(sheet_entry)
		if not ok then
			sheet = nil
		elseif n then
			sheet.say(string.format("%s  %06x", n.name, n.rgb))
		end
	end
end)

-- Takes the picker's window down; what is in it is not asked again
function M.close_picker(w)
	sheet = nil
	w:Remove()
end

function M.color_sheet(parent, cols, o)
	local bands = math.ceil(#cols / SHEET_BAND)
	local w = math.min(#cols, SHEET_BAND)
	local h = bands * 13 - 1
	local image = magic.Image:new()
	assert(image:SetSize(w, h, 4), "Image:SetSize")
	local none = magic.Color(0, 0, 0, 0)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			image:SetPixel(x, y, none)
		end
	end
	local at_col, at_row = nil, nil
	for ci, col in ipairs(cols) do
		local x = (ci - 1) % SHEET_BAND
		local y0 = math.floor((ci - 1) / SHEET_BAND) * 13
		for ri, n in ipairs(col) do
			image:SetPixel(x, y0 + ri - 1, to_color(n.rgb))
			if n.rgb == o.rgb and not at_col then
				at_col, at_row = x, y0 + ri - 1
			end
		end
	end
	local t = magic.Texture2D:new()
	t:SetNumLevels(1)
	-- Before the data: after it the tiles were drawn smeared together
	t.filterMode = magic.FILTER_NEAREST
	assert(t:SetData(image), "Texture2D:SetData")
	local b = parent:CreateChild("Button")
	b:SetFixedSize(w * SHEET_TILE, h * SHEET_TILE)
	b.color = magic.Color(1, 1, 1, 0)
	local face = b:CreateChild("BorderImage")
	face:SetFixedSize(w * SHEET_TILE, h * SHEET_TILE)
	face.texture = t
	face.blendMode = magic.BLEND_ALPHA
	-- The value's own tile, framed
	if at_col then
		local T = SHEET_TILE
		-- 2 px: at a UI scale under one a 1 px line can round to nothing
		for _, r in ipairs({{-2, -2, T + 4, 2}, {-2, T, T + 4, 2},
				{-2, 0, 2, T}, {T, 0, 2, T}}) do
			local line = face:CreateChild("BorderImage")
			line:SetPosition(at_col * T + r[1], at_row * T + r[2])
			line:SetFixedSize(r[3], r[4])
			line.color = magic.Color(1, 1, 1)
		end
	end
	sheet = {button = b, cols = cols, say = o.say}
	magic.SubscribeToEvent(b, "Released", function()
		local n = sheet and sheet_entry()
		if n then
			o.on_pick(n.rgb)
		end
	end)
	return b
end

-- The colour picker ([FP_COLOR]): a window over the middle of the screen.
-- o.title, o.rgb (the value now), o.named ({name, rgb} that fit this
-- field), o.query (what the named ones are narrowed by), o.on_pick(rgb),
-- o.on_query(text), o.on_close(). A pick is a whole new value; the window
-- is drawn again from the value that comes back.
local NAMED_SHOWN = 72
function M.color_picker(o)
	local w = M.window(magic.HA_CENTER, magic.VA_CENTER, 0, 0)
	w.minWidth = 340
	M.label(w, o.title)
	sheet = nil
	local h, s, v = M.rgb_hsv(o.rgb)
	local name_line
	local function hover(text)
		name_line:SetText(text or "")
	end

	local top = M.row(w)
	-- A button for its Released, with the wheel as a picture on it
	local disk = top:CreateChild("Button")
	disk:SetFixedSize(WHEEL, WHEEL)
	-- A button with no style is a plain white quad under the picture
	disk.color = magic.Color(1, 1, 1, 0)
	local face = disk:CreateChild("BorderImage")
	face:SetFixedSize(WHEEL, WHEEL)
	face.texture = wheel()
	face.color = magic.Color(v, v, v)
	face.blendMode = magic.BLEND_ALPHA
	magic.SubscribeToEvent(disk, "Released", function()
		local at = disk.screenPosition
		local c = (WHEEL - 1) / 2
		local px, py = pointer()
		local dx = px - at.x - c
		local dy = py - at.y - c
		local r = math.sqrt(dx * dx + dy * dy) / c
		if r <= 1.02 then
			-- A black one has no hue to keep; the wheel's pick is seen
			o.on_pick(M.hsv_rgb((math.atan2(-dy, dx) / (2 * math.pi)) % 1,
					math.min(1, r), v > 0.02 and v or 1))
		end
	end)
	-- The value, top bright to bottom dark, in this hue and saturation
	local values = top:CreateChild("UIElement")
	values:SetLayout(magic.LM_VERTICAL, 0, magic.IntRect(0, 0, 0, 0))
	for i = 0, 8 do
		local vv = 1 - i / 8
		M.chip(values, M.hsv_rgb(h, s, vv), 12, function()
			o.on_pick(M.hsv_rgb(h, s, vv))
		end, hover, string.format("Brightness %d %%", vv * 100 + 0.5))
	end
	local side = top:CreateChild("UIElement")
	side:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(4, 0, 0, 0))
	local now = side:CreateChild("BorderImage")
	now:SetFixedSize(64, 40)
	now.color = to_color(o.rgb)
	local hex = side:CreateChild("LineEdit")
	hex:SetStyleAuto()
	hex.minHeight = 22
	hex:SetFixedWidth(84)
	hex.textSelectable = true
	hex.textCopyable = true
	hex:SetText(string.format("%06x", o.rgb))
	magic.SubscribeToEvent(hex, "TextFinished", function()
		local t = hex:GetText():gsub("^#", "")
		local x = #t == 6 and tonumber(t, 16)
		magic.ui:SetFocusElement(nil)
		if x then o.on_pick(x) end
	end)
	M.button(side, "Done (Esc)", function() o.on_close() end)

	if #o.named > 0 then
		local q = (o.query or ""):lower()
		-- In rows: a family of its own ({family} from the file's fourth
		-- column, a paint maker's hue with its lightnesses), else twelve
		local rows, row, matches = {}, nil, 0
		for _, n in ipairs(o.named) do
			if q == "" or n.name:lower():find(q, 1, true) then
				matches = matches + 1
				if not row or #row == 12 or n.family ~= row.family then
					row = {family = n.family}
					rows[#rows + 1] = row
				end
				row[#row + 1] = n
			end
		end
		-- Narrowing is worth offering only when there is more than a page.
		-- Enter on what leaves one colour, a code typed whole, takes it.
		if #o.named > NAMED_SHOWN or q ~= "" then
			M.field(w, "Find", o.query or "", function(t)
				local one, count = nil, 0
				for _, n in ipairs(o.named) do
					if t ~= "" and n.name:lower():find(t:lower(), 1, true) then
						one, count = n, count + 1
						if n.name:lower():sub(-#t - 1) == " " .. t:lower() then
							count = 1
							break
						end
					end
				end
				o.on_query(t)
				if count == 1 then
					o.on_pick(one.rgb)
				end
			end, 160)
		end
		if matches > NAMED_SHOWN then
			M.color_sheet(w, rows, {rgb = o.rgb, on_pick = o.on_pick,
					say = hover})
		else
			for _, r in ipairs(rows) do
				local line = M.row(w)
				for _, n in ipairs(r) do
					M.chip(line, n.rgb, 18, function() o.on_pick(n.rgb) end, hover,
							string.format("%s  %06x", n.name, n.rgb))
				end
			end
		end
		if matches == 0 then
			M.label(w, "Nothing matches")
		end
	end
	name_line = M.label(w, "")
	-- What the value is called, when it is one of the named ones
	for _, n in ipairs(o.named) do
		if n.rgb == o.rgb then
			name_line:SetText(n.name)
			break
		end
	end
	return w
end

-- Whether a point in UI coordinates is on one of the elements. pairs, not
-- ipairs: a window that is not up is a nil in the list, and ipairs stopped
-- at it -- a click on the colour picker, after the pause menu's nil, went
-- through to the view behind.
function M.over(elements, ux, uy)
	for _, el in pairs(elements) do
		if el and el.visible then
			local p = el.screenPosition
			local s = el.size
			if ux >= p.x and uy >= p.y and ux < p.x + s.x and uy < p.y + s.y then
				return true
			end
		end
	end
	return false
end

return M
-- vim: set noet ts=4 sw=4:
