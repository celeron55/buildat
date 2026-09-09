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
	tableoptions = true,
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

	-- tablecolumns[type,opt=val,...;...] says what the columns of the tables
	-- after it are. What matters here is which of them carry text and which
	-- only say something about the row: a colour column colours the cells
	-- after it and a tree column moves them to the right.
	local function parse_columns(fields)
		local cols = {}
		for _, part in ipairs(fields) do
			local bits = formspec.split(part, ",")
			local col = {type = (bits[1] or "text"):match("^%s*(.-)%s*$"),
					opts = {}}
			for i = 2, #bits do
				local k, v = bits[i]:match("^%s*([%w_]+)%s*=%s*(.*)$")
				if k then
					col.opts[k] = v
				end
			end
			cols[#cols + 1] = col
		end
		if #cols == 0 then
			cols[1] = {type = "text", opts = {}}
		end
		return cols
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

	-- The slots of one inventory list, and what is in them. held is the slot
	-- whose stack is in hand, which is marked so that it can be seen.
	local function draw_list(parent, layout, e, slots, held)
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
				local in_hand = held and held.location == e.fields[1] and
						held.list == e.fields[2] and held.index == index
				box(parent, x, y, slot, slot, in_hand and
						magic.Color(0.6, 0.6, 0.2, 0.55) or
						magic.Color(0, 0, 0, 0.45))
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
	-- state is what has to live longer than one drawing of the form: how far
	-- a table is scrolled. The caller keeps it and hands it back.
	function self:show(root, elements, layout, screen_w, screen_h, state)
		state = state or {}
		state.scroll = state.scroll or {}
		state.open = state.open or {}
		state.check = state.check or {}
		local slots = {}
		local buttons = {}
		local fields = {}
		-- The things that are not buttons but send the form back all the
		-- same: a tab of a tabheader, a checkbox
		local taps = {}

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

		-- The columns the tables after a tablecolumns[] have, and where the
		-- tables ended up, for whoever handles a click in one
		local columns = {{type = "text", opts = {}}}
		local tables = {}

		-- table[X,Y;W,H;name;cell,cell,...;selected] and its cousin
		-- textlist[]: rows of text in a dark box, a cell per column.
		--
		-- A tree column makes the rows a tree: a row whose next row is
		-- deeper is one that opens, its children are hidden until it is
		-- clicked, and which ones are open is kept in the state the caller
		-- holds. Luanti's own table does the opening client-side as well.
		--
		-- Luanti measures a column's width from what is in it; this counts
		-- characters, which is close enough for the tables a game builds and
		-- needs none of the font's metrics.
		--
		-- simplified: no image or custom colour columns, and no scrollbar to
		-- drag -- the wheel is what scrolls. A cell that does not fit its
		-- column is cut rather than shortened with an ellipsis.
		local function draw_table(e, x, y, w, h)
			local list = e.name == "table" and columns or
					{{type = "text", opts = {}}}
			local ncol = #list
			local cells = {}
			for _, c in ipairs(formspec.split(e.raw[4] or "", ",")) do
				cells[#cells + 1] = formspec.strip_escapes(
						formspec.unescape(c))
			end
			local name = e.fields[3]
			local rows = {}
			for i = 1, math.ceil(#cells / ncol) do
				local row = {index = i}
				for j = 1, ncol do
					row[j] = cells[(i - 1) * ncol + j] or ""
				end
				rows[i] = row
			end

			-- What each column says about a row: its colour, how deep it is
			-- in the tree
			local color_col, tree_col = nil, nil
			for j, col in ipairs(list) do
				if col.type == "color" then
					color_col = j
				elseif col.type == "tree" or col.type == "indent" then
					tree_col = j
				end
			end
			for i, row in ipairs(rows) do
				row.depth = tree_col and (tonumber(row[tree_col]) or 0) or 0
				row.color = color_col and
						markup_color("\27(c@"..row[color_col]..")") or nil
				-- A cell may name its own colour in front of its text, as
				-- "#rgb" or "#rrggbb"; "##" is one of those characters
				-- rather than the start of a colour
				for j = 1, ncol do
					if j ~= color_col and j ~= tree_col then
						local hex, rest = row[j]:match("^#(%x%x%x%x%x%x)(.*)$")
						if not hex then
							hex, rest = row[j]:match("^#(%x%x%x)([^%x].*)$")
						end
						if hex then
							row.color = row.color or
									markup_color("\27(c@#"..hex..")")
							row[j] = rest
						else
							row[j] = row[j]:gsub("^##", "#")
						end
					end
				end
			end
			for i, row in ipairs(rows) do
				row.opens = tree_col ~= nil and rows[i + 1] ~= nil and
						rows[i + 1].depth > row.depth
			end

			-- Only what is open is on the screen
			local open = state.open[name] or {}
			state.open[name] = open
			local shown = {}
			local hidden_below = nil
			for _, row in ipairs(rows) do
				if hidden_below and row.depth > hidden_below then
					-- A child of something that is closed
				else
					hidden_below = nil
					shown[#shown + 1] = row
					if row.opens and not open[row.index] then
						hidden_below = row.depth
					end
				end
			end

			-- How wide each text column wants to be, by its longest cell
			local CHAR_W = 6.5
			local pad = 3
			local text_cols = {}
			local deepest = 0
			for _, row in ipairs(shown) do
				deepest = math.max(deepest, row.depth)
			end
			for j, col in ipairs(list) do
				if j ~= color_col and j ~= tree_col then
					local longest = 1
					for _, row in ipairs(shown) do
						longest = math.max(longest, #row[j])
					end
					local want = longest * CHAR_W + 12
					if #text_cols == 0 then
						-- The first column is where the tree's indent goes,
						-- and a name pushed to the right needs the room
						want = want + deepest * 14 + 12
					end
					text_cols[#text_cols + 1] = {j = j, want = want}
				end
			end
			-- A column keeps the width it wants, as long as it leaves room
			-- for the ones after it; the last one takes what is left and
			-- what does not fit in it is cut. A single cell with a long line
			-- in it must not be allowed to squeeze the columns before it
			-- down to nothing, which is what sharing the width out in
			-- proportion would do.
			local avail = w - pad * 2
			local left = avail
			for k, tc in ipairs(text_cols) do
				local for_the_rest = (#text_cols - k) * 40
				tc.w = math.max(20, math.min(tc.want, left - for_the_rest))
				left = left - tc.w
			end

			box(window, x, y, w, h, magic.Color(0.04, 0.04, 0.05, 0.92))
			local row_h = 16
			local visible = math.max(1, math.floor((h - pad * 2) / row_h))
			local scroll = math.min(state.scroll[name] or 0,
					math.max(0, #shown - visible))
			local selected = tonumber(e.fields[5])
			local on_screen = {}
			for i = scroll + 1, math.min(#shown, scroll + visible) do
				local row = shown[i]
				local ry = y + pad + (i - scroll - 1) * row_h
				if row.index == selected then
					box(window, x + 1, ry, w - 2, row_h,
							magic.Color(0.35, 0.62, 0.23, 0.95))
				end
				local indent = row.depth * 14
				if row.opens then
					label(window, x + pad + indent, ry, 12,
							open[row.index] and "-" or "+", 12, row.color)
				end
				local cx = x + pad
				for k, tc in ipairs(text_cols) do
					-- The tree moves the row's own text to the right; the
					-- columns after the first stay in their places
					local tx = cx + (k == 1 and (indent + 12) or 0)
					local room = tc.w - (tx - cx) - 4
					local fits = math.max(0, math.floor(room / CHAR_W))
					local text = row[tc.j]
					if #text > fits then
						text = text:sub(1, fits)
					end
					if text ~= "" then
						label(window, tx, ry, room, text, 12, row.color)
					end
					cx = cx + tc.w
				end
				on_screen[#on_screen + 1] = {index = row.index, y = ry,
						opens = row.opens}
			end
			tables[#tables + 1] = {name = name, x = x, y = y, w = w, h = h,
					row_h = row_h, count = #shown, visible = visible,
					scroll = scroll, rows = on_screen}
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
				draw_list(window, layout, e, slots, state.held)
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
						-- A styled button's image is nine-sliced too: the
						-- middle is what stretches and the border of it
						-- keeps its size, or the image comes out smeared
						local border = drawn and
								slice_border(st.bgimg_middle)
						if border then
							drawn.imageBorder = border
							drawn.border = border
						end
					end
					if not drawn and st.border ~= "false" then
						box(window, x, y, w, h,
								magic.Color(0.35, 0.35, 0.42, 0.9))
					end
					if text and text ~= "" then
						-- Luanti centres a button's text in it
						local t = label(window, x + 4, y + h / 2 - 8, w - 8,
								formspec.strip_escapes(text), 12,
								st.textcolor and markup_color(
										"\27(c@"..st.textcolor..")"))
						t:SetTextAlignment(1) -- HA_CENTER
					end
					buttons[#buttons + 1] = {name = button_name,
							x = x, y = y, w = w, h = h,
							exit = name:sub(-5) == "_exit"}
				end
			elseif name == "tabheader" then
				-- tabheader[X,Y;name;caption,...;current;...] and the newer
				-- form with a W,H after the position. The tabs are drawn
				-- across the form, the one that is on lighter than the rest.
				--
				-- simplified: a tab's width comes from counting the
				-- characters of its caption rather than from the font, and
				-- neither the transparent nor the border flag is honoured.
				local x, y = at(e, 1)
				local sized = formspec.parse_v2(e.fields[2]) ~= nil
				local i0 = sized and 3 or 2
				local w = sized and select(1, geometry(e, 2)) or layout.width
				-- Luanti's own tab height, twice its button height, and its
				-- y is the bottom of the tabs rather than the top: they sit
				-- above whatever the form puts at the same y
				local h = layout.imgsize * 15 / 13 * 0.35 * 2
				y = y - h
				local captions = {}
				for _, c in ipairs(formspec.split(e.raw[i0 + 1] or "", ",")) do
					captions[#captions + 1] = formspec.strip_escapes(
							formspec.unescape(c))
				end
				local current = tonumber(e.fields[i0 + 2]) or 1
				if x and #captions > 0 then
					local tx = x
					for i, caption in ipairs(captions) do
						-- As wide as its own caption, which is what
						-- Luanti's tab control does
						local tw = #caption * 6.5 + 18
						box(window, tx, y, tw - 2, h, i == current and
								magic.Color(0.75, 0.75, 0.78, 0.95) or
								magic.Color(0.35, 0.35, 0.4, 0.9))
						local t = label(window, tx, y + h / 2 - 8, tw - 2,
								caption, 12, i == current and
								magic.Color(0.1, 0.1, 0.1) or nil)
						t:SetTextAlignment(1) -- HA_CENTER
						taps[#taps + 1] = {name = e.fields[i0],
								value = tostring(i), x = tx, y = y,
								w = tw - 2, h = h}
						tx = tx + tw
					end
				end
			elseif name == "checkbox" then
				-- checkbox[X,Y;name;label;selected]. The state the player
				-- clicked wins over the one the form was drawn with, so that
				-- the tick moves before the server has answered.
				local x, y = at(e, 1)
				if x then
					local on = state.check[e.fields[2]]
					if on == nil then
						on = e.fields[4] == "true"
					end
					local size = math.floor(layout.imgsize * 0.35)
					-- A label's y is the middle of its line, and so is a
					-- checkbox's
					local cy = y - size / 2
					box(window, x, cy, size, size,
							magic.Color(0.1, 0.1, 0.12, 0.9))
					if on then
						box(window, x + 3, cy + 3, size - 6, size - 6,
								magic.Color(0.85, 0.85, 0.9, 0.95))
					end
					local st = style_of(name, e.fields[2])
					label(window, x + size + 6, y - 8, nil,
							formspec.strip_escapes(e.fields[3] or ""), 13,
							st.textcolor and markup_color(
									"\27(c@"..st.textcolor..")"))
					taps[#taps + 1] = {name = e.fields[2],
							value = tostring(not on), x = x, y = cy,
							w = size, h = size, check = true}
				end
			elseif name == "table" or name == "textlist" then
				local x, y = at(e, 1)
				local w, h = geometry(e, 2)
				if x and w then
					draw_table(e, x, y, w, h)
				end
			elseif name == "tablecolumns" then
				columns = parse_columns(e.fields)
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
				buttons = buttons, fields = fields, tables = tables,
				taps = taps,
				close_on_enter = close_on_enter}
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
