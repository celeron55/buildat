-- Buildat: extensions/luanti_client/res/hotbar.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- Luanti's hotbar, the way both Luanti clients draw it ([EXT_HOTBAR]): the
-- first slots of the player's main list along the bottom, in the geometry
-- Luanti's own hud.cpp gives them and wearing the game's own hotbar_image
-- and hotbar_selected_image. A game that places its health and hunger bars
-- against official's hotbar has them land where they were meant to only if
-- this row is where official's is, which is why the numbers are Luanti's
-- rather than a share of the screen.
--
-- Served by the luanti module as luanti/hotbar.lua for the sandbox and
-- dofile'd by the extension, so what it needs comes in the call:
--   new{magic =, buildat =, log =, parent = <UI element, default ui.root>,
--       font = <Font>, priority = <over the rest of the caller's UI>,
--       max = <slots built, default 32>, white = <a 1x1 white Texture2D>,
--       texture = function(name) -> Texture2D or nil,   -- a hotbar image
--       stack = function(stack) -> Texture2D or nil, count_text, item_name,
--               wear (0 to 65535, or nil)}
-- texture and stack are the caller's, because what an item looks like and
-- how a texture modifier expression is composed is each client's own.
--   h:draw{list =, wield =, count =, image =, selected_image =, shown =}
--   h:metrics() -> imagesize, padding, slot_size, margin
--   h:destroy()
local M = {}

-- How many are drawn is the game's to say -- hud_set_hotbar_itemcount() --
-- and this is Luanti's own ceiling on it. They are all built once and the
-- ones past the count are hidden, because the number changes when a game
-- says so and rebuilding them would be the same slots again.
M.MAX = 32
-- Luanti's own numbers, out of Hud::readScalingSetting() and
-- Hud::drawItems(): a slot's picture is 48 screen pixels times the display
-- density and the user's hud_scaling, its padding is a twelfth of that, and
-- a slot is the picture with padding on both sides. **The window size is not
-- in it**: the hotbar is a fixed size on the screen and does not grow with
-- the window.
local IMAGE_SIZE = 48
-- hud_hotbar_max_width's default. Past this share of the window the row
-- splits in two, the first half above the second, which is what a game that
-- asks for a lot of slots hits.
--
-- simplified: the setting itself is the game's and does not cross to the
-- client yet, so this is Luanti's default rather than what the game said.
local MAX_WIDTH = 1.0

function M.new(o)
	local magic, buildat, log = o.magic, o.buildat, o.log
	local h = {}
	local max = o.max or M.MAX
	local parent = o.parent or magic.ui.root
	local slots = {}

	-- Luanti's own m_scale_factor, which every size and offset a HUD element
	-- carries is multiplied by before it is drawn: Luanti's is the user's
	-- hud_scaling times the display density, and its numbers are screen
	-- pixels. This UI is not in screen pixels -- magic.ui.root is 1920 wide
	-- on a 1280 window -- so this is the conversion, and it is what keeps
	-- the row the same number of screen pixels Luanti would have drawn.
	local function hud_scale()
		-- Over the frame's width, which is the window's -- or the logical
		-- size a scripted client keeps whatever the window does
		-- ([SEQ_FIXED_SIZE]); over the window there, the hotbar shrank as
		-- the window grew
		local fw = buildat.logical_size()
		return magic.ui.root.width / math.max(1, fw or magic.graphics.width)
	end

	-- The three numbers everything below is drawn from, in this UI's units
	function h:metrics()
		local per_pixel = hud_scale()
		local imagesize = math.floor(IMAGE_SIZE * per_pixel + 0.5)
		local padding = math.floor(imagesize / 12)
		-- And how far above the bottom of the screen it sits: Luanti's
		-- default hotbar element is at (0.5, 1) with an offset of four
		-- scaled pixels
		local margin = math.floor(4 * per_pixel + 0.5)
		return imagesize, padding, imagesize + padding * 2, margin
	end

	-- The whole hotbar hangs off one element of its own, screen-sized so
	-- that a centred or bottom-aligned child of it lands where it would
	-- have landed on the parent. Everything in it says outright how far
	-- forward it is drawn ([HOTBAR_LAYERS]): the order used to be the
	-- order the elements were made in as children of the UI root, and a
	-- screen pushed or popped, or a re-layout, reordered them -- the
	-- marker behind the background in one slot and in front in the next.
	local root = parent:CreateChild("UIElement")
	root:SetPosition(0, 0)
	root.size = magic.IntVector2(parent.width, parent.height)
	root.priority = o.priority or 10
	h.root = root

	-- One per row, because Luanti draws the hotbar image once per row
	-- rather than once per slot; behind the slots by priority
	local backgrounds = {}
	for r = 1, 2 do
		local bg = root:CreateChild("BorderImage")
		bg.priority = 0
		bg.horizontalAlignment = magic.HA_CENTER
		bg.verticalAlignment = magic.VA_BOTTOM
		bg.blendMode = magic.BLEND_ALPHA
		bg.visible = false
		backgrounds[r] = bg
	end
	for i = 1, max do
		local frame = root:CreateChild("UIElement")
		frame.priority = 1
		frame.horizontalAlignment = magic.HA_CENTER
		frame.verticalAlignment = magic.VA_BOTTOM
		frame.visible = false
		-- The game's own mark for the slot in hand, under the item the way
		-- Luanti draws it; see hud_set_hotbar_selected_image()
		local marker = frame:CreateChild("BorderImage")
		marker.blendMode = magic.BLEND_ALPHA
		marker.visible = false
		marker.priority = 0
		-- Luanti's own mark when the game names none: a red ring a
		-- padding wide around the picture, one side at a time
		local ring = {}
		for k = 1, 4 do
			ring[k] = frame:CreateChild("BorderImage")
			if o.white then
				ring[k].texture = o.white
			end
			ring[k].color = magic.Color(1, 0, 0)
			ring[k].priority = 0
		end
		-- What a slot wears when the game has given no hotbar image, which
		-- is Luanti's own fallback: half-transparent black under the
		-- picture, the padding between left clear
		local back = frame:CreateChild("BorderImage")
		if o.white then
			back.texture = o.white
		end
		back.priority = 1
		local image = frame:CreateChild("BorderImage")
		image.visible = false
		image.priority = 2
		-- A worn tool's bar, the worn part black ([UI_PARITY] 5)
		local bar = {}
		for k = 1, 2 do
			bar[k] = frame:CreateChild("BorderImage")
			if o.white then
				bar[k].texture = o.white
			end
			bar[k].priority = 3
		end
		local count = frame:CreateChild("Text")
		count.priority = 4
		if o.font then
			count:SetFont(o.font, 12)
		end
		count:SetTextEffect(magic.TE_SHADOW)
		count.effectColor = magic.Color(0, 0, 0, 0.9)
		count.horizontalAlignment = magic.HA_RIGHT
		count.verticalAlignment = magic.VA_BOTTOM
		slots[i] = {frame = frame, image = image, count = count,
				marker = marker, ring = ring, bar = bar, back = back}
	end

	-- The row the window changed size under: the root is the parent's size
	-- and a centred child of it is placed against that
	function h:relayout()
		root.size = magic.IntVector2(parent.width, parent.height)
	end

	-- Said once per picture that had no size when it was assigned, which is
	-- what [ITEM_TILED] reads
	local sizeless = {}

	-- state.list is the stacks, in whatever form the caller's stack()
	-- takes; wield is the one in hand, one-based; count is how many slots
	-- the game asked for; image and selected_image are the game's two
	-- hotbar pictures, by name; shown false takes the whole row away.
	function h:draw(state)
		local list = state.list or {}
		local wield = state.wield or 1
		local shown = state.shown ~= false
		local n = math.max(1, math.min(max, state.count or 8))
		local imagesize, padding, slot_size, margin = h:metrics()
		-- Luanti splits the row in two when it would be wider than this
		-- share of the window, the first half above the second
		local upper = 0
		if (n * slot_size) / magic.ui.root.width > MAX_WIDTH then
			upper = math.floor(n / 2)
		end
		local rows = {
			{first = upper + 1, last = n, y = 0},
			{first = 1, last = upper, y = imagesize + padding},
		}
		-- The picture the game puts behind a row, half a padding proud of
		-- it on every side, which is where Luanti's own hud.cpp puts it --
		-- one image stretched over the row rather than one per slot
		local bg = o.texture(state.image)
		local selected = o.texture(state.selected_image)
		local at_row, at_x = {}, {}
		for r, row in ipairs(rows) do
			local count = row.last - row.first + 1
			local row_width = count * slot_size
			local element = backgrounds[r]
			if bg and count > 0 then
				element.texture = bg
				element.size = magic.IntVector2(
						math.floor(row_width + padding),
						math.floor(slot_size + padding))
				-- Half a padding proud of the slots on every side, which is
				-- what hud.cpp draws it as
				element:SetPosition(0,
						-math.floor(margin + row.y - padding / 2))
			end
			element.visible = shown and bg ~= nil and count > 0
			for i = row.first, row.last do
				at_row[i] = row
				-- A centred element's position is where its own centre
				-- goes, so the half slot is what puts the row's left edge
				-- on the left edge of the picture behind it
				at_x[i] = math.floor(-row_width / 2 +
						(i - row.first) * slot_size + slot_size / 2)
			end
		end
		for i = 1, max do
			local slot = slots[i]
			slot.frame.visible = shown and i <= n
			if i <= n then
				slot.frame.size = magic.IntVector2(slot_size, slot_size)
				slot.frame:SetPosition(at_x[i], -(margin + at_row[i].y))
				-- The game's mark is the item's own square grown by two
				-- paddings on every side, which is bigger than the slot:
				-- see drawItem() in Luanti's hud.cpp
				slot.marker:SetPosition(-padding, -padding)
				slot.marker.size = magic.IntVector2(
						imagesize + padding * 4, imagesize + padding * 4)
				slot.image:SetPosition(padding, padding)
				slot.image.size = magic.IntVector2(imagesize, imagesize)
				slot.back:SetPosition(padding, padding)
				slot.back.size = magic.IntVector2(imagesize, imagesize)
				local far = padding + imagesize
				for k, r in ipairs{{0, 0, slot_size, padding},
						{0, far, slot_size, padding},
						{0, padding, padding, imagesize},
						{far, padding, padding, imagesize}} do
					slot.ring[k]:SetPosition(r[1], r[2])
					slot.ring[k].size = magic.IntVector2(r[3], r[4])
				end
				-- The count's corner is the picture's ([UI_PARITY] 4)
				slot.count:SetPosition(-padding, -padding)
			end
			-- The stack's own look when its metadata gives it one
			-- ([ITEM_META_LOOK]); the name is still what the tooltip reads
			local tex, count_text, name, wear = o.stack(list[i])
			-- Assigned only when there is one: the sandbox takes a Texture
			-- and not a nil, and an empty slot is an image that is not
			-- drawn.
			-- The rect said outright ([ITEM_TILED]): while it is zero Urho
			-- spans the element's width in texels, and a texture that had
			-- no size at assignment tiled sixteen pickaxes to a slot
			if tex then
				slot.image.texture = tex
				if tex.width > 0 then
					slot.image.imageRect =
							magic.IntRect(0, 0, tex.width, tex.height)
				elseif not sizeless[tostring(tex.name)] then
					sizeless[tostring(tex.name)] = true
					log:info("picture "..tostring(tex.name)..
							" has no size yet at assignment ([ITEM_TILED])")
				end
			end
			slot.image.visible = tex ~= nil and tex.width > 0
			-- Luanti's own per-slot background, which is what a game that
			-- names no hotbar image gets; a game that names one has it
			-- behind the whole row instead, so the slots themselves are
			-- not drawn
			local marked = i == wield
			slot.back.color = (name and tex == nil) and
					magic.Color(0.5, 0.3, 0.5, 0.75) or
					magic.Color(0, 0, 0, bg and 0 or 0.5)
			for _, r in ipairs(slot.ring) do
				r.visible = marked and selected == nil
			end
			-- Luanti's drawItemStack(): a sixteenth of the picture high, a
			-- sixteenth in from the sides and the bottom, green through
			-- yellow to red over what is left
			wear = (wear or 0) / 65535
			slot.bar[1].visible = wear > 0 and i <= n
			slot.bar[2].visible = wear > 0 and i <= n
			if wear > 0 and i <= n then
				local x0 = padding + math.floor(imagesize / 16)
				local w = imagesize - 2 * math.floor(imagesize / 16)
				local h = math.max(1, math.floor(imagesize / 16))
				local y = padding + imagesize - math.floor(imagesize / 16) - h
				local left = math.floor(w * (1 - wear))
				local wi = math.min(math.min(math.floor(wear * 600), 511) + 10,
						511)
				slot.bar[1].color = wi <= 255 and
						magic.Color(wi / 255, 1, 0) or
						magic.Color(1, (511 - wi) / 255, 0)
				slot.bar[1]:SetPosition(x0, y)
				slot.bar[1].size = magic.IntVector2(left, h)
				slot.bar[2].color = magic.Color(0, 0, 0)
				slot.bar[2]:SetPosition(x0 + left, y)
				slot.bar[2].size = magic.IntVector2(w - left, h)
			end
			if selected then
				slot.marker.texture = selected
			end
			slot.marker.visible = marked and selected ~= nil
			slot.count:SetText(count_text or "")
		end
	end

	function h:destroy()
		root:Remove()
	end

	return h
end

return M
-- vim: set noet ts=4 sw=4:
