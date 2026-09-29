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
	return e
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

-- Whether a point in UI coordinates is on one of the elements
function M.over(elements, ux, uy)
	for _, el in ipairs(elements) do
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
