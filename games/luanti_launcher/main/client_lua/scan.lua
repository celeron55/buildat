-- Buildat: luanti_launcher/client_lua/scan.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- `event scan <resolution> <label>` in a command sequence ([SCAN_EVENT]):
-- what is on the screen, in the log under the label -- the crosshair's
-- hit, a grid of rays to ten voxels with what each hit and passed
-- through, and every element of an open form or the chat line. A run
-- reads it beside the screenshot it took in the same line. Here rather
-- than in the module's client half because the camera, the crosshair
-- march and the node names are the launcher's until the fold; init.lua
-- hands them in as ctx, as functions where the value moves.
local magic = require("buildat/extension/urho3d")
local voxelworld = require("buildat/module/voxelworld")
local luanti = require("buildat/module/luanti")

local RANGE = 10
local STEP = 0.25

return function(ctx)
	local log = ctx.log

	-- Every rectangle here is in window pixels, the coordinates mouse_pos
	-- takes: Urho's UI is laid out in its own units, the window's pixels
	-- over ui:GetScale(), and one conversion here beats every reader
	-- knowing which space a line is in. Clipped to the window, so that
	-- the centre of what is left is a valid mouse position.
	local function pixels(x, y, w, h)
		-- The frame's pixels over the root's units: the logical frame in
		-- a scripted client, whatever the window is ([SEQ_FIXED_SIZE])
		local ww, wh = buildat.logical_size()
		local k = ww / math.max(1, magic.ui.root.width)
		local x0 = math.max(0, math.floor(x * k))
		local y0 = math.max(0, math.floor(y * k))
		local x1 = math.min(ww, math.floor((x + w) * k))
		local y1 = math.min(wh, math.floor((y + h) * k))
		return x0, y0, math.max(0, x1 - x0), math.max(0, y1 - y0)
	end

	local function ray(p0, dir)
		local last = nil
		local through = {}
		for i = 1, math.floor(RANGE / STEP) do
			local p = (p0 + dir * (i * STEP)):round()
			if p ~= last then
				local v = voxelworld.get_static_voxel(p)
				if ctx.voxel_is_solid(v) then
					return ctx.node_name_at(p) or "?", p, i * STEP, through
				end
				-- Not solid but not air either: a plant, a liquid, a
				-- cutout, which the ray went through
				if v ~= nil then
					local name = ctx.node_name_at(p)
					if name and name ~= "air" then
						through[#through + 1] = name
					end
				end
				last = p
			end
		end
		return nil, nil, nil, through
	end

	local function ui(label, element, depth, out)
		local ok, n = pcall(function() return element:GetNumChildren() end)
		if not ok then
			return
		end
		for i = 0, n - 1 do
			local child = element:GetChild(i)
			if child then
				local kind = child:GetTypeName()
				local at = child.screenPosition
				local x, y, w, h = pixels(at.x, at.y, child.width, child.height)
				local line = string.format("scan %s: ui %s%s at %d,%d size %dx%d",
						label, string.rep("  ", depth), kind, x, y, w, h)
				if kind == "Text" or kind == "LineEdit" then
					local okt, text = pcall(function()
						return child.GetText and child:GetText() or child.text
					end)
					if okt and text then
						line = line .. " text " .. buildat.dump(text)
					end
				end
				if kind == "BorderImage" or kind == "Sprite" or
						kind == "Button" then
					local okt, name = pcall(function()
						local tex = child.texture
						return tex and tex.name or nil
					end)
					if okt and name and name ~= "" then
						line = line .. " image " .. buildat.dump(name)
					elseif not okt then
						line = line .. " image ? (" .. tostring(name) .. ")"
					end
				end
				out[#out + 1] = line
				ui(label, child, depth + 1, out)
			end
		end
	end

	magic.SubscribeToEvent("command_seq:scan", function(event_type, event_data)
		local param = event_data:GetString("Param") or ""
		local res, label = param:match("^(%d+)%s*(%S*)")
		res = math.max(1, math.min(32, tonumber(res) or 8))
		if label == nil or label == "" then
			label = "scan"
		end
		local lines = {}
		-- The player: where, which way, what is held ([SCAN_DRIVE] reads
		-- this line first). hp is the health bar's below.
		local px, py, pz = ctx.player_pos()
		local yaw0, pitch0, fov0 = ctx.view()
		local stacks = ctx.hotbar()
		local hot = {}
		for i = 1, math.min(#stacks, luanti.hotbar.count or 9) do
			hot[#hot + 1] = i .. ":" .. tostring(stacks[i] or "")
		end
		lines[#lines + 1] = string.format(
				"scan %s: self at %.1f,%.1f,%.1f yaw %.1f pitch %.1f fov %.1f hp ? wield %s hotbar %s",
				label, px, py, pz, yaw0, pitch0, fov0,
				buildat.dump(ctx.wield() or ""), table.concat(hot, " | "))
		-- The frame the rectangles are in, and the UI root it is read off
		local lw, lh = buildat.logical_size()
		lines[#lines + 1] = string.format("scan %s: frame %dx%d root %dx%d ui_scale %.3f",
				label, lw, lh, magic.ui.root.width, magic.ui.root.height,
				magic.ui:GetScale() or 0)
		-- The HUD's bars: health, hunger, breath, armour, by their picture
		for _, e in pairs(luanti.hud_elements) do
			if e.type == "statbar" then
				local rect = ""
				local rx, ry, rw, rh = ctx.hud_rect(e)
				if rx then
					rx, ry, rw, rh = pixels(rx, ry, rw, rh)
					rect = string.format(" at %d,%d size %dx%d", rx, ry, rw, rh)
				end
				lines[#lines + 1] = string.format("scan %s: hud statbar %s %s/%s%s",
						label, buildat.dump(e.text or ""), tostring(e.number or 0),
						tostring(e.item or e.number or 0), rect)
			end
		end
		-- The crosshair, by the same march the dig uses
		local hit = ctx.pointed()
		if hit then
			lines[#lines + 1] = string.format("scan %s: crosshair %s at %d,%d,%d",
					label, ctx.node_name_at(hit) or "?", hit.x, hit.y, hit.z)
		else
			lines[#lines + 1] = string.format(
					"scan %s: crosshair nothing within %d", label, ctx.dig_range())
		end
		-- The grid: a ray from the centre of each bin, built from the
		-- camera's yaw and pitch (Urho's, pitch positive down) and its
		-- field of view
		local p0 = buildat.Vector3(ctx.camera_node().worldPosition)
		local yaw, pitch, fov = ctx.view()
		local yr, pr = math.rad(yaw), math.rad(pitch)
		local fwd = buildat.Vector3(math.sin(yr) * math.cos(pr), -math.sin(pr),
				math.cos(yr) * math.cos(pr))
		local right = buildat.Vector3(math.cos(yr), 0, -math.sin(yr))
		local up = buildat.Vector3(math.sin(yr) * math.sin(pr), math.cos(pr),
				math.cos(yr) * math.sin(pr))
		local tan_v = math.tan(math.rad(fov) / 2)
		local aspect = magic.ui.root.width / math.max(1, magic.ui.root.height)
		for by = 0, res - 1 do
			for bx = 0, res - 1 do
				local sx = ((bx + 0.5) / res * 2 - 1) * tan_v * aspect
				local sy = (1 - (by + 0.5) / res * 2) * tan_v
				local dir = fwd + right * sx + up * sy
				local name, p, d, through = ray(p0, dir)
				local via = #through > 0 and
						(" via " .. table.concat(through, ",")) or ""
				-- The bins are voxels only; the objects are the listing
				-- below, every one on the screen
				if name then
					lines[#lines + 1] = string.format(
							"scan %s: bin %d,%d: %s at %d,%d,%d d=%.1f%s",
							label, bx, by, name, p.x, p.y, p.z, d, via)
				else
					lines[#lines + 1] = string.format("scan %s: bin %d,%d: %s%s",
							label, bx, by, dir.y > 0.2 and "sky" or "nothing", via)
				end
			end
		end
		-- Every object on the screen, by projection: a bin's ray misses
		-- an item lying about most of the time (a bin is ten degrees
		-- wide, an item four at four nodes), and this does not. The
		-- screen position is in window pixels, the bin the one its
		-- centre falls in.
		local ww, wh = buildat.logical_size()
		local function dot(a, b)
			return a.x * b.x + a.y * b.y + a.z * b.z
		end
		for _, o in ipairs(luanti.objects()) do
			local d = buildat.Vector3(o.x, o.y, o.z) - p0
			local depth = dot(d, fwd)
			if depth > 0.1 and depth <= RANGE then
				local sx = dot(d, right) / depth / (tan_v * aspect)
				local sy = dot(d, up) / depth / tan_v
				if sx >= -1 and sx <= 1 and sy >= -1 and sy <= 1 then
					lines[#lines + 1] = string.format(
							"scan %s: object %s %s at %.1f,%.1f,%.1f d=%.1f screen %d,%d bin %d,%d",
							label, tostring(o.id), o.label, o.x, o.y, o.z,
							d:length(), math.floor((sx + 1) / 2 * ww),
							math.floor((1 - sy) / 2 * wh),
							math.min(res - 1, math.floor((sx + 1) / 2 * res)),
							math.min(res - 1, math.floor((1 - sy) / 2 * res)))
				end
			end
		end
		-- The voxels around the player, a cube of radius VOX_R about the
		-- feet, as a name table and one line per (y, z) row of x: a
		-- driver keeps a grid of them and picks which to dig and which to
		-- keep (user, 2026-09-20), which the rays above cannot give it.
		-- 0 is air or anything not there.
		local VOX_R = 4
		local fx0 = math.floor(px + 0.5)
		local fy0 = math.floor(py + 0.5)
		local fz0 = math.floor(pz + 0.5)
		local names, index = {}, {}
		local rows = {}
		for y = fy0 - VOX_R, fy0 + VOX_R do
			for z = fz0 - VOX_R, fz0 + VOX_R do
				local row = {}
				for x = fx0 - VOX_R, fx0 + VOX_R do
					local v = voxelworld.get_static_voxel(buildat.Vector3(x, y, z))
					local name = v ~= nil and ctx.node_name_at(buildat.Vector3(x, y, z)) or nil
					local i = 0
					if name ~= nil and name ~= "air" then
						i = index[name]
						if i == nil then
							names[#names + 1] = name
							i = #names
							index[name] = i
						end
					end
					row[#row + 1] = tostring(i)
				end
				rows[#rows + 1] = string.format("scan %s: voxels y=%d z=%d x=%d: %s",
						label, y, z, fx0 - VOX_R, table.concat(row, " "))
			end
		end
		local legend = {}
		for i, name in ipairs(names) do
			legend[i] = i .. "=" .. name
		end
		lines[#lines + 1] = string.format("scan %s: voxel names %s", label,
				table.concat(legend, " "))
		for _, r in ipairs(rows) do
			lines[#lines + 1] = r
		end
		-- What takes input, if anything: the form (the inventory, the
		-- pause menu and the death screen are forms too) or the chat line
		local formname, window = luanti.form_window()
		local chat = ctx.chat_text()
		if window then
			lines[#lines + 1] = string.format("scan %s: form %s open", label,
					buildat.dump(formname))
			-- The slots by list and index, with what is in them: the
			-- elements below are the pictures and do not say
			for _, s in ipairs(luanti.form_slots() or {}) do
				local x, y, w, h = pixels(s.x, s.y, s.size, s.size)
				lines[#lines + 1] = string.format(
						"scan %s: slot %s:%s:%d at %d,%d size %dx%d item %s", label,
						s.location, s.list, s.index, x, y, w, h,
						buildat.dump(s.stack))
			end
			ui(label, window, 1, lines)
		elseif chat then
			lines[#lines + 1] = string.format("scan %s: chat line open, text %s",
					label, buildat.dump(chat))
		else
			lines[#lines + 1] = string.format("scan %s: no form open", label)
		end
		lines[#lines + 1] = string.format("scan %s: done, %d lines", label, #lines)
		log:info(table.concat(lines, "\n"))
	end)
end
-- vim: set noet ts=4 sw=4:
