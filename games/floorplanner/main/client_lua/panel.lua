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
	-- A click on the panel itself, not on a control, takes the focus from
	-- a field, as a click on the view does (user)
	w:SetFocusMode(magic.FM_FOCUSABLE)
	return w
end

-- **Panels folded away on a small screen** ([FP_TOUCH] 2): a phone's is
-- too narrow in portrait, and too low in landscape, for the palette and the
-- properties beside the view. There they start folded, a toolbar button opens one, and one opened
-- folds the others; on a wide screen none is ever folded.
M.folds = {}
function M.narrow()
	return magic.ui.root.width < 700 or magic.ui.root.height < 500
end

function M.folded(key)
	if not M.narrow() then
		return false
	end
	if M.folds[key] == nil then
		M.folds[key] = true
	end
	return M.folds[key]
end

function M.toggle_fold(key)
	local opening = M.folded(key)
	M.folds[key] = not opening
	if opening then
		for k in pairs(M.folds) do
			if k ~= key then
				M.folds[k] = true
			end
		end
	end
end

function M.row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

-- Things one under another, inside a row
function M.column(parent)
	local c = parent:CreateChild("UIElement")
	c:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	c:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
	return c
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

-- **A dropdown** (user): a button saying the choice, which opens under it
-- a list of the choices over everything else. A choice, the button again,
-- a press elsewhere (M.press) or Esc closes it; one is open at a time.
-- choices: {{text, value}, ...}; on_choose(value)
M.popup = nil
local owner_at = nil -- the open one's button's place, found again by it
local skip_owner = false
function M.close_popup()
	if M.popup then
		M.popup:Remove()
		M.popup, owner_at = nil, nil
	end
end
-- A button's mark at its right end, its text centred in what is left:
-- the dropdown's (Overpass has U+25BC and U+25B2, not the smaller ones)
function M.mark(b, mark)
	local t = b:GetChild(0)
	local m = b:CreateChild("Text")
	m:SetStyleAuto()
	m:SetText(mark)
	m:SetAlignment(magic.HA_RIGHT, magic.VA_CENTER)
	m:SetPosition(-6, 0)
	m:SetColor(t.color)
	local room = m.width + 16
	t:SetPosition(-room / 2, 0)
	b.minWidth = b.minWidth + room
	return b
end

function M.dropdown(parent, label, choices, current, on_choose, min_width)
	local shown = "?"
	for _, c in ipairs(choices) do
		if c[2] == current then
			shown = c[1]
		end
	end
	local b
	b = M.button(parent, (label and label .. ": " or "") .. shown,
			function()
		if skip_owner then
			-- This press on it closed it already
			skip_owner = false
			return
		end
		M.close_popup()
		local w = magic.ui.root:CreateChild("Window")
		w:SetStyleAuto()
		w:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(4, 4, 4, 4))
		w:SetFocusMode(magic.FM_FOCUSABLE)
		-- Over the pause menu and the colour picker
		w.priority = 300
		for _, c in ipairs(choices) do
			M.button(w, c[1], function()
				M.close_popup()
				on_choose(c[2])
			end, c[2] == current, b.width - 8)
		end
		local p = b.screenPosition
		local y = p.y + b.height
		if y + w.height > magic.ui.root.height then
			y = math.max(0, p.y - w.height)
		end
		w:SetPosition(p.x, y)
		M.popup = w
		owner_at = {p.x, p.y, b.width, b.height}
	end, false, min_width)
	return M.mark(b, "▼")
end

-- A press anywhere, in UI coordinates, before it goes on: one off the open
-- dropdown closes it. True when it did.
function M.press(ux, uy)
	if not M.popup or M.over({M.popup}, ux, uy) then
		return false
	end
	local o = owner_at
	skip_owner = ux >= o[1] and uy >= o[2] and ux < o[1] + o[3] and
			uy < o[2] + o[4]
	M.close_popup()
	return true
end

-- **A checkbox** (user): one thing on or off, ticked when on. The box and
-- its text are one button, drawn without a button's frame.
function M.check(parent, text, checked, on_click)
	local b = parent:CreateChild("Button")
	b.color = magic.Color(0, 0, 0, 0)
	b:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(4, 2, 4, 2))
	local c = b:CreateChild("CheckBox")
	c:SetStyleAuto()
	c.verticalAlignment = magic.VA_CENTER
	c.checked = checked
	-- The button takes the click, not the box
	c.enabled = false
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	t.verticalAlignment = magic.VA_CENTER
	magic.SubscribeToEvent(b, "Released", function()
		on_click()
	end)
	return b
end

-- **Numeric fields step** (user): the wheel over one, or Up and Down in
-- it, adds its step to the number and commits it as Enter would. A field
-- given a number is one, found again by its element's name: no element is
-- kept here, since a removed one still answers where it was.
-- By the label: 10 for millimetres, 100 for kelvin, else 1; Shift x10.
local numeric = {} -- element name -> {on_finish, step}
local numeric_n = 0

local function nudge(edit, dir, shift)
	local entry = numeric[edit:GetName()]
	local v = entry and tonumber(edit:GetText())
	if not v then
		return false
	end
	v = v + dir * entry.step * (shift and 10 or 1)
	local text = v == math.floor(v) and string.format("%d", v) or tostring(v)
	edit:SetText(text)
	entry.on_finish(text)
	return true
end

-- Up or Down in the field that has the focus; whether it was a numeric one
function M.nudge_focused(dir, shift)
	local f = magic.ui.focusElement
	return f ~= nil and nudge(f, dir, shift)
end

-- The wheel at a point in UI coordinates over the windows up now; whether
-- a numeric field was there. What the walk does not meet is forgotten.
function M.nudge_at(windows, ux, uy, dir, shift)
	local live, hit = {}, nil
	local function walk(el)
		local name = el:GetName()
		if numeric[name] then
			live[name] = numeric[name]
			local p, s = el.screenPosition, el.size
			if ux >= p.x and uy >= p.y and ux < p.x + s.x and uy < p.y + s.y then
				hit = el
			end
		end
		for i = 0, el:GetNumChildren() - 1 do
			walk(el:GetChild(i))
		end
	end
	for _, w in pairs(windows) do
		walk(w)
	end
	numeric = live
	return hit ~= nil and nudge(hit, dir, shift)
end

-- A labelled text field; on_finish(text) when Enter is pressed in it
-- **Leaving a field keeps what was typed** (user: Enter alone was obscure):
-- a click elsewhere, Back or Tab does what Enter does, for a field that
-- holds a value -- a number, or `keep`. A field that does something (a
-- copy's name, a password) still waits for Enter. The action runs at the
-- next flush(): the defocus comes while the UI is moving the focus, and a
-- panel rebuilt there would pull the next element from under it.
local leaving = {}
function M.flush()
	local l = leaving
	leaving = {}
	for _, f in ipairs(l) do
		f()
	end
end

function M.field(parent, label, value, on_finish, width, keep)
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
	if type(value) == "number" then
		numeric_n = numeric_n + 1
		local name = "fp_number_" .. numeric_n
		e:SetName(name)
		numeric[name] = {on_finish = on_finish,
				step = label:find("mm") and 10 or label:find("Kelvin") and 100 or 1}
	end
	local done = e:GetText()
	if keep or type(value) == "number" then
		magic.SubscribeToEvent(e, "Defocused", function()
			local t = e:GetText()
			if t ~= done then
				done = t
				leaving[#leaving + 1] = function() on_finish(t) end
			end
		end)
	end
	magic.SubscribeToEvent(e, "TextFinished", function()
		done = e:GetText()
		on_finish(done)
		-- Unless on_finish moved it on, to the next field of a form
		if e:HasFocus() then
			magic.ui:SetFocusElement(nil)
		end
	end)
	return e, r
end

-- A button of a picture over its name: rect of texture, 48 px square;
-- `down` draws it as the one chosen
function M.preview_button(parent, texture, rect, text, on_click, down)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(3, 3, 3, 3))
	b:SetFixedWidth(70)
	local face = b:CreateChild("BorderImage")
	face:SetFixedSize(48, 48)
	face.texture = texture
	face.imageRect = rect
	face:SetAlignment(magic.HA_CENTER, magic.VA_TOP)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	t:SetFontSize(10)
	t:SetAlignment(magic.HA_CENTER, magic.VA_TOP)
	if down then
		t:SetColor(magic.Color(1.0, 0.85, 0.3))
		b.selected = true
	end
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
	return b
end

-- A palette row: one button with the colour and the label on it, so the
-- label is as much the thing to click as the colour is
function M.swatch_row(parent, rgb, text, on_click, down, text_color)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(4, 3, 6, 3))
	b.minHeight = 24
	-- A column beside a longer one would stretch it
	b.maxHeight = 30
	local face = b:CreateChild("BorderImage")
	face:SetFixedSize(16, 16)
	face.color = magic.Color(math.floor(rgb / 65536) % 256 / 255,
			math.floor(rgb / 256) % 256 / 255, rgb % 256 / 255)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	-- As wide as its words, which a narrow column would otherwise clip
	b.minWidth = t.width + 36
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
