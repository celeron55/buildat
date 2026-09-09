-- Buildat: extension/luanti_client/formspec_ui.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- A formspec on the screen, out of Urho3D's UI elements.
--
-- formspec.lua says what the elements are and where; this puts something
-- there. What a formspec asks for is mostly boxes with a texture in them, so
-- most of it is a BorderImage at a position, and the interesting parts are
-- the inventory lists: a slot's background, the item's image in it, and how
-- many of the item there are.
--
-- What an item looks like is its inventory image, or the texture of the top
-- of the node it places, and either of those is a texture modifier
-- expression, so it goes through the same composing the world's textures do.
--
-- simplified: an item that is a node is drawn as one of its tiles rather than
-- as the little cube Luanti draws. The upgrade path is rendering a cube to a
-- texture, which is what Luanti's own inventory does with a second scene.
--
-- The elements that are not implemented are counted and named once, which is
-- what says whether it is worth implementing the next one; styles, tooltips
-- and the list ring are deliberately ignored rather than missing.

local formspec = dofile(__buildat_extension_path("luanti_client")..
		"/formspec.lua")

local M = {}

-- The elements that say nothing about what is drawn
local IGNORED = {
	listring = true, listcolors = true, style = true, style_type = true,
	tooltip = true, set_focus = true, field_close_on_enter = true,
	field_enter_after_edit = true, no_prepend = true, bgcolor = true,
	scrollbaroptions = true, allow_close = true, position = true,
	anchor = true, padding = true, ["scroll_container_end"] = true,
}

-- new(magic, buildat, log, ctx)
--
-- ctx.texture(expression) -> a resource name for a texture modifier
--   expression, or nil
-- ctx.item_image(item_name) -> a resource name for what an item looks like,
--   or nil
-- ctx.inventory(location, list_name) -> the list to draw in a list[] element,
--   as inventory.lua's {size =, items = {...}}, or nil
function M.new(magic, buildat, log, ctx)
	local self = {}
	local WHITE = "luanti_client/res/white.png"
	local unknown = {}

	local function texture(name)
		if not name or name == "" then
			return nil
		end
		local resource = ctx.texture(name)
		if not resource then
			return nil
		end
		return magic.cache:GetResource("Texture2D", resource)
	end

	-- A rectangle of one colour, which is what a box is and what stands in
	-- for a texture that could not be composed
	local function box(parent, x, y, w, h, color)
		local e = parent:CreateChild("BorderImage")
		e:SetPosition(math.floor(x), math.floor(y))
		e.size = magic.IntVector2(math.floor(w), math.floor(h))
		e.texture = magic.cache:GetResource("Texture2D", WHITE)
		e.color = color
		return e
	end

	local function image(parent, x, y, w, h, name)
		local tex = texture(name)
		if not tex then
			return nil
		end
		local e = parent:CreateChild("BorderImage")
		e:SetPosition(math.floor(x), math.floor(y))
		e.size = magic.IntVector2(math.floor(w), math.floor(h))
		e.texture = tex
		return e
	end

	local function label(parent, x, y, w, text, size, color)
		local e = parent:CreateChild("Text")
		e:SetStyleAuto()
		e.text = text
		e:SetFontSize(size)
		e:SetPosition(math.floor(x), math.floor(y))
		e.color = color or magic.Color(1, 1, 1)
		if w then
			e.width = math.floor(w)
		end
		return e
	end

	-- An item stack in a slot: what it looks like, and how many
	local function draw_stack(parent, x, y, size, stack)
		local resource = stack and ctx.item_image(stack.name)
		if resource then
			local e = parent:CreateChild("BorderImage")
			e:SetPosition(math.floor(x + size * 0.1),
					math.floor(y + size * 0.1))
			e.size = magic.IntVector2(math.floor(size * 0.8),
					math.floor(size * 0.8))
			e.texture = magic.cache:GetResource("Texture2D", resource)
		elseif stack then
			-- Something is there but there is no image for it; a marked
			-- square says so, and the name is in the tooltip line
			box(parent, x + size * 0.3, y + size * 0.3, size * 0.4,
					size * 0.4, magic.Color(0.8, 0.4, 0.8, 0.8))
		end
		if stack and stack.count > 1 then
			local t = label(parent, x + size * 0.05, y + size * 0.55,
					size * 0.9, tostring(stack.count),
					math.max(8, math.floor(size * 0.32)))
			t:SetTextAlignment(2) -- HA_RIGHT
		end
	end

	-- The slots of one inventory list, and what is in them
	local function draw_list(parent, layout, e, slots)
		local pos = formspec.parse_v2(e.fields[3])
		local geom = formspec.parse_v2(e.fields[4])
		if not pos or not geom then
			return
		end
		local list = ctx.inventory(e.fields[1], e.fields[2])
		local start = tonumber(e.fields[5]) or 0
		local step = layout.slot_step
		local slot = layout.slot
		for row = 0, geom[2] - 1 do
			for col = 0, geom[1] - 1 do
				local x = (pos[1] + e.at[1]) * layout.scale[1] +
						layout.origin[1] + col * step
				local y = (pos[2] + e.at[2]) * layout.scale[2] +
						layout.origin[2] + row * step
				local index = start + row * geom[1] + col + 1
				box(parent, x, y, slot, slot, magic.Color(0, 0, 0, 0.45))
				local stack = list and list.items[index] or nil
				draw_stack(parent, x, y, slot, stack)
				slots[#slots + 1] = {
					location = e.fields[1], list = e.fields[2],
					index = index, x = x, y = y, size = slot,
					stack = stack,
				}
			end
		end
	end

	-- The hotbar and the health bar, which are not a formspec at all: the
	-- game describes them as HUD elements and this draws the two of them a
	-- player needs to see, out of the inventory and the hit points.
	--
	-- simplified: not the game's own HUD. This server sends a hundred HUD
	-- elements -- its own hearts, its bubbles, its armour bar, its crosshair
	-- -- and none of them are drawn; what is drawn is a hotbar of the first
	-- slots of the player's main list and a bar for the hit points. The
	-- upgrade path is HUDADD and its friends.
	--
	-- Returns the element it all went under, for the caller to take away
	-- again when it changes.
	function self:hud(root, list, count, wield, hp, hp_max, screen_w,
			screen_h)
		local holder = root:CreateChild("UIElement")
		local slot = math.floor(math.min(screen_w, screen_h) / 15)
		local step = math.floor(slot * 1.1)
		local width = step * count
		local x0 = math.floor((screen_w - width) / 2)
		local y0 = screen_h - slot - math.floor(slot * 0.5)

		for i = 1, count do
			local x = x0 + (i - 1) * step
			local stack = list and list.items[i] or nil
			-- The wielded slot is the lighter one, which is how a hotbar
			-- says which it is
			box(holder, x, y0, slot, slot, i == wield and
					magic.Color(0.9, 0.9, 0.9, 0.55) or
					magic.Color(0, 0, 0, 0.45))
			draw_stack(holder, x, y0, slot, stack)
		end

		if hp and hp_max and hp_max > 0 then
			local bar_h = math.max(3, math.floor(slot * 0.14))
			local y = y0 - bar_h - 4
			box(holder, x0, y, width, bar_h, magic.Color(0, 0, 0, 0.5))
			local filled = math.floor(width * math.min(hp, hp_max) / hp_max)
			if filled > 0 then
				box(holder, x0, y, filled, bar_h,
						magic.Color(0.85, 0.15, 0.15, 0.9))
			end
		end
		return holder
	end

	-- show(root, elements, layout, screen_w, screen_h)
	--
	-- root is the UI element everything goes under. What comes back is the
	-- window, where it ended up, and where the slots and the buttons are in
	-- it, for whoever handles clicks.
	--
	-- The window is positioned rather than aligned, because a click has to be
	-- turned back into a position inside it and the sandbox does not hand out
	-- an element's own position.
	function self:show(root, elements, layout, screen_w, screen_h)
		local slots = {}
		local buttons = {}
		local fields = {}

		local ox = math.floor((screen_w - layout.width) / 2)
		local oy = math.floor((screen_h - layout.height) / 2)
		local window = root:CreateChild("BorderImage")
		window.texture = magic.cache:GetResource("Texture2D", WHITE)
		window.color = magic.Color(0.15, 0.15, 0.18, 0.92)
		window.size = magic.IntVector2(math.floor(layout.width),
				math.floor(layout.height))
		window:SetPosition(ox, oy)

		local function at(e, field_i)
			local pos = formspec.parse_v2(e.fields[field_i])
			if not pos then
				return nil
			end
			return (pos[1] + e.at[1]) * layout.scale[1] + layout.origin[1],
					(pos[2] + e.at[2]) * layout.scale[2] + layout.origin[2]
		end

		local function geometry(e, field_i)
			local g = formspec.parse_v2(e.fields[field_i])
			if not g then
				return nil
			end
			return g[1] * layout.scale[1], g[2] * layout.scale[2]
		end

		for _, e in ipairs(elements) do
			local name = e.name
			if IGNORED[name] then
				-- Nothing to draw
			elseif name == "list" then
				draw_list(window, layout, e, slots)
			elseif name == "image" or name == "background" or
					name == "background9" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					if not image(window, x, y, w, h, e.fields[3]) then
						box(window, x, y, w, h,
								magic.Color(0.25, 0.25, 0.3, 0.6))
					end
				end
			elseif name == "box" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					box(window, x, y, w, h, magic.Color(0.3, 0.3, 0.35, 0.7))
				end
			elseif name == "item_image" or name == "item_image_button" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					draw_stack(window, x, y, math.min(w, h),
							{name = e.fields[3], count = 1})
					if name == "item_image_button" then
						buttons[#buttons + 1] = {name = e.fields[4],
								x = x, y = y, w = w, h = h}
					end
				end
			elseif name == "button" or name == "button_exit" or
					name == "image_button" or name == "image_button_exit" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					local is_image = name:sub(1, 5) == "image"
					local button_name = is_image and e.fields[4] or e.fields[3]
					local text = is_image and e.fields[5] or e.fields[4]
					if not (is_image and
							image(window, x, y, w, h, e.fields[3])) then
						box(window, x, y, w, h,
								magic.Color(0.35, 0.35, 0.42, 0.9))
					end
					if text and text ~= "" then
						label(window, x + 4, y + h / 2 - 8, w - 8,
								formspec.strip_escapes(text), 12)
					end
					buttons[#buttons + 1] = {name = button_name,
							x = x, y = y, w = w, h = h,
							exit = name:sub(-5) == "_exit"}
				end
			elseif name == "label" or name == "textarea" then
				local x, y = at(e, 1)
				local text = name == "label" and e.fields[2] or e.fields[5]
				if x and text then
					-- A label's y is the middle of its line
					label(window, x, y - 8, nil, formspec.strip_escapes(text), 13)
				end
			elseif name == "field" or name == "pwdfield" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					box(window, x, y, w, h, magic.Color(0.9, 0.9, 0.9, 0.9))
					local value = e.fields[5] or ""
					fields[#fields + 1] = {name = e.fields[3], value = value}
					if value ~= "" then
						label(window, x + 4, y + h / 2 - 7, w - 8,
								formspec.strip_escapes(value), 12,
								magic.Color(0.1, 0.1, 0.1))
					end
				end
			elseif not unknown[name] then
				unknown[name] = true
				log:info("formspec: nothing drawn for \""..name.."\"")
			end
		end
		return {window = window, origin = {ox, oy}, slots = slots,
				buttons = buttons, fields = fields}
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
