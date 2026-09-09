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
	tooltip = true, field_enter_after_edit = true,
	no_prepend = true, bgcolor = true,
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
-- ctx.style is the UI style (an XMLFile) everything under the form inherits;
--   without it a Text element has no font and draws nothing at all
function M.new(magic, buildat, log, ctx)
	local self = {}
	local WHITE = "luanti_client/res/white.png"
	local unknown = {}

	-- Urho3D sorts an element's children by priority and the sort is not a
	-- stable one, so siblings that all sit at the default priority are drawn
	-- in whatever order the sort happens to leave them in -- a background
	-- over the slots one run and under them the next. Every element gets the
	-- priority its turn to be drawn is instead.
	local depth = 0
	local function next_priority()
		depth = depth + 1
		return depth
	end

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
		e.priority = next_priority()
		return e
	end

	-- A nine-sliced image: the corners keep their size and only the middle
	-- stretches, which is what a formspec's background9 asks for. middle is
	-- Luanti's own field: one number for every side, two for horizontal and
	-- vertical, or four for left, top, right and bottom.
	local function slice_border(middle)
		local n = {}
		for v in tostring(middle or ""):gmatch("-?%d+%.?%d*") do
			n[#n + 1] = math.floor(math.abs(tonumber(v)))
		end
		if #n == 1 then
			return magic.IntRect(n[1], n[1], n[1], n[1])
		elseif #n == 2 then
			return magic.IntRect(n[1], n[2], n[1], n[2])
		elseif #n >= 4 then
			return magic.IntRect(n[1], n[2], n[3], n[4])
		end
		return nil
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
		e.priority = next_priority()
		return e
	end

	-- Luanti's colour markup: \27(c@#rgb) and \27(c@#rrggbb) set the colour
	-- of what follows. Only the first one is honoured -- a Text element is
	-- one colour -- which is enough for a label a game has coloured.
	local function markup_color(text)
		local hex = text:match("\27%(c@#(%x%x%x%x%x%x)%)") or
				text:match("\27%(c@#(%x%x%x)%)")
		if not hex then
			return nil
		end
		local function part(i, n)
			local v = tonumber(hex:sub(i, i + n - 1), 16) / (n == 1 and 15 or 255)
			return v
		end
		if #hex == 3 then
			return magic.Color(part(1, 1), part(2, 1), part(3, 1))
		end
		return magic.Color(part(1, 2), part(3, 2), part(5, 2))
	end

	local function label(parent, x, y, w, text, size, color)
		local e = parent:CreateChild("Text")
		e:SetStyleAuto()
		e.text = text
		e.priority = next_priority()
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
			e.priority = next_priority()
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
		if ctx.style then
			holder.defaultStyle = ctx.style
		end
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
		-- No backdrop of its own: what a form looks like is the backgrounds
		-- it asks for, and a panel behind them darkens every one of them.
		-- The element is still what catches the clicks.
		local window = root:CreateChild("UIElement")
		-- Inherited by everything under it, which is where the text in a
		-- form gets its font
		if ctx.style then
			window.defaultStyle = ctx.style
		end
		window.size = magic.IntVector2(math.floor(layout.width),
				math.floor(layout.height))
		window:SetPosition(ox, oy)
		-- Urho3D leaves an element disabled unless told otherwise, and a
		-- disabled element is not hit by a click: nothing is found under the
		-- mouse and no click event is sent at all
		window.enabled = true

		-- style[name;k=v;...] and style_type[type;k=v;...]. Only the default
		-- state is kept: hovered and pressed need an event this does not get.
		local styles, type_styles = {}, {}
		for _, e in ipairs(elements) do
			if e.name == "style" or e.name == "style_type" then
				local props = {}
				for i = 2, #e.fields do
					local k, v = e.fields[i]:match("^%s*([%w_]+)%s*=%s*(.*)$")
					if k then
						props[k] = v
					end
				end
				local into = e.name == "style" and styles or type_styles
				for target in tostring(e.fields[1] or ""):gmatch("[^,]+") do
					local base, state = target:match("^%s*([^:%s]+):?(.*)$")
					if base and (state == "" or state == "default") then
						into[base] = into[base] or {}
						for k, v in pairs(props) do
							into[base][k] = v
						end
					end
				end
			end
		end

		-- What a named element of a given type is styled as
		local function style_of(element_type, element_name)
			local by_name = element_name and styles[element_name]
			local by_type = type_styles[element_type]
			if not by_name then
				return by_type or {}
			end
			if not by_type then
				return by_name
			end
			local out = {}
			for k, v in pairs(by_type) do out[k] = v end
			for k, v in pairs(by_name) do out[k] = v end
			return out
		end

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

		-- Luanti draws the backgrounds in a pass of their own, behind
		-- everything else, whatever order they are in; a background that is
		-- drawn in element order covers the slots that came before it.
		for _, e in ipairs(elements) do
			if e.name == "background" or e.name == "background9" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if e.fields[4] == "true" then
					-- auto_clip: the whole form, x and y being an offset
					-- outwards and w and h not used at all.
					-- simplified: the offset is dropped, so a background that
					-- means to stick out past the form's edge does not.
					x, y, w, h = 0, 0, layout.width, layout.height
				end
				if x and w then
					local img = image(window, x, y, w, h, e.fields[3])
					if img and e.name == "background9" then
						local border = slice_border(e.fields[5])
						if border then
							img.imageBorder = border
							img.border = border
						end
					end
				end
			end
		end

		for _, e in ipairs(elements) do
			local name = e.name
			if IGNORED[name] then
				-- Nothing to draw
			elseif name == "background" or name == "background9" then
				-- Drawn in the pass above
			elseif name == "list" then
				draw_list(window, layout, e, slots)
			elseif name == "image" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					-- Nothing at all for a texture that is not there yet:
					-- these cover a whole form, and a grey box each hides
					-- what the form is made of. The media is asked for when
					-- the texture is wanted, and the form is drawn again
					-- when it arrives.
					image(window, x, y, w, h, e.fields[3])
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
					local st = style_of(name, button_name)
					local drawn = is_image and
							image(window, x, y, w, h, e.fields[3])
					-- A game that styles its buttons means them to look like
					-- the image it gives, and a bordered box behind that is
					-- not what it asked for
					if not drawn and st.bgimg and st.bgimg ~= "" then
						drawn = image(window, x, y, w, h, st.bgimg)
					end
					if not drawn and st.border ~= "false" then
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
					local st = style_of(name, nil)
					-- A label's y is the middle of its line
					label(window, x, y - 8, nil,
							formspec.strip_escapes(text), 13,
							markup_color(text) or
									(st.textcolor and
									markup_color("\27(c@"..st.textcolor..")")))
				end
			elseif name == "field" or name == "pwdfield" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					local st = style_of(name, e.fields[3])
					local bg = st.bgcolor and
							markup_color("\27(c@"..st.bgcolor..")")
					if st.bgimg and st.bgimg ~= "" then
						image(window, x, y, w, h, st.bgimg)
					end
					-- A line edit of Urho3D's own, so that the field can be
					-- typed into; it is drawn dark with light text in it,
					-- which is what Luanti's own field looks like
					local edit = window:CreateChild("LineEdit")
					if ctx.style then
						edit.defaultStyle = ctx.style
					end
					edit:SetStyleAuto()
					edit:SetPosition(math.floor(x), math.floor(y))
					edit.size = magic.IntVector2(math.floor(w),
							math.floor(h))
					edit.enabled = true
					edit.priority = next_priority()
					edit.texture = magic.cache:GetResource("Texture2D", WHITE)
					edit.color = bg or magic.Color(0.1, 0.1, 0.12, 0.9)
					local value = name == "field" and e.fields[5] or ""
					edit:SetText(formspec.strip_escapes(value or ""))
					if name == "pwdfield" then
						edit.echoCharacter = 42 -- an asterisk
					end
					-- The field's label goes above it, as Luanti puts it
					local text = e.fields[4]
					if text and text ~= "" then
						label(window, x, y - 15, nil,
								formspec.strip_escapes(text), 12)
					end
					fields[#fields + 1] = {name = e.fields[3],
							value = value or "", edit = edit}
				end
			elseif name == "set_focus" or name == "field_close_on_enter" then
				-- Read after the pass, where the fields are all known
			elseif not unknown[name] then
				unknown[name] = true
				log:info("formspec: nothing drawn for \""..name.."\"")
			end
		end
		-- field_close_on_enter[name;bool] says whether pressing enter in a
		-- field closes the form; a field nobody said anything about does.
		-- set_focus[name;force] is which field starts with the keys.
		local close_on_enter = {}
		local focus_name = nil
		for _, e in ipairs(elements) do
			if e.name == "field_close_on_enter" then
				close_on_enter[e.fields[1]] = e.fields[2] ~= "false"
			elseif e.name == "set_focus" then
				focus_name = e.fields[1]
			end
		end
		for _, f in ipairs(fields) do
			if f.name == focus_name and f.edit then
				f.edit:SetFocus(true)
			end
		end
		return {window = window, origin = {ox, oy}, slots = slots,
				buttons = buttons, fields = fields,
				close_on_enter = close_on_enter}
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
