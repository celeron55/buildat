-- Buildat: games/floorplanner/main/client_lua/tutorial.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The tutorial** ([FP_TUTORIAL], user 2026-10-01): steps of a text and a
-- check, in a small window at the bottom; the next step comes when the
-- check says the user did it. Started from the plan picker, kept on this
-- client over a reload. It only reads what the editor and the document
-- already have: nothing in the editor knows it is there.
--
--   local tutorial = run_script_file("main/tutorial.lua")(doc)
--   tutorial.start()
-- doc.editor is the editor once it is loaded; its M.S is its state.
local magic = require("buildat/extension/urho3d")

return function(doc)
	local T = {}
	local win, title, body = nil, nil, nil
	local step = tonumber(buildat.storage_read("tutorial") or "") or 0
	local mark = {} -- what a step's check compares against, from its start

	local function ed()
		return doc.editor
	end
	local function S()
		return doc.editor and doc.editor.S or {}
	end
	local function of(type)
		return doc.in_plan and doc.of_type(type) or {}
	end
	local function kind_of(inst)
		local d = doc.ents[inst.ints.def]
		return d and d.ints.kind
	end
	local function instances(kind)
		local out = {}
		for _, i in ipairs(of("instance")) do
			if kind_of(i) == kind then
				out[#out + 1] = i
			end
		end
		return out
	end
	local function lamp_entry(id)
		local e = doc.ents[id]
		return e and e.type == "palette" and e.ints.kind == 4
	end
	local function lamp_on(id)
		local lo = S().local_on
		if lo and lo[id] ~= nil then
			return lo[id]
		end
		return doc.ents[id] and doc.ents[id].ints.on == 1
	end
	local function first_switch_lamps()
		for _, sw in ipairs(instances(5)) do
			if #sw.lists.lamps > 0 then
				return sw.lists.lamps
			end
		end
		return {}
	end
	local function lamps_state()
		local t = {}
		for _, l in ipairs(first_switch_lamps()) do
			t[#t + 1] = lamp_on(l) and "1" or "0"
		end
		return table.concat(t)
	end
	-- The lowest floor
	local function ground()
		local low = nil
		for _, l in ipairs(of("layout")) do
			if not low or l.ints.y < low.ints.y then
				low = l
			end
		end
		return low and low.id
	end
	local function minute()
		return ed() and ed().plan_minute and ed().plan_minute() or 0
	end

	-- {text, check, enter}; the text says what to do and where it is
	local STEPS = {
		{"Welcome. This tutorial builds a small house step by step. Type a " ..
				"name for a new plan in the field and press New plan.",
				function() return doc.in_plan end},
		{"A plan opens for viewing, so nothing changes by accident. Press " ..
				"Start editing at the end of the toolbar.",
				function() return doc.can("edit") end},
		{"Draw a room: pick Room (R) in the toolbar, then click its corners " ..
				"on the floor. Click the first corner again, or press Enter, " ..
				"to close it. The room gets walls.",
				function() return #of("room") >= 1 end},
		{"Draw a second room beside the first, starting and ending on the " ..
				"first room's corners, so the two share a wall.",
				function()
					local rooms = of("room")
					for i = 1, #rooms do
						for j = i + 1, #rooms do
							local set, n = {}, 0
							for _, x in ipairs(rooms[i].lists.nodes) do
								set[x] = true
							end
							for _, x in ipairs(rooms[j].lists.nodes) do
								if set[x] then n = n + 1 end
							end
							if n >= 2 then
								return true
							end
						end
					end
					return false
				end},
		{"Put a door in the wall between the rooms: pick Door/window (I) " ..
				"and click on the wall. What it puts in is shown in the " ..
				"properties panel on the right.",
				function() return #instances(3) >= 1 end},
		{"Now a window: with Door/window still picked, set Kind to Window " ..
				"in the panel (or press I), then click an outside wall.",
				function() return #instances(4) >= 1 end},
		{"A linked clone shares its shape with the original. Pick Select " ..
				"(V), click the window, press Ctrl+L, then click another wall.",
				function()
					local n = {}
					for _, w in ipairs(instances(4)) do
						n[w.ints.def] = (n[w.ints.def] or 0) + 1
						if n[w.ints.def] >= 2 then
							return true
						end
					end
					return false
				end},
		{"A cupboard: pick Object (O) and drag its footprint on the floor " ..
				"against a wall. Then type a height of 2000 in the panel's " ..
				"Height mm.",
				function()
					for _, i in ipairs(instances(0)) do
						if doc.ents[i.ints.def].ints.h >= 1500 then
							return true
						end
					end
					return false
				end},
		{"A night lamp needs a glowing material. In the Palette on the " ..
				"left, press New entry, then set its Type to Lamp.",
				function()
					for _, p in ipairs(of("palette")) do
						if p.ints.kind == 4 then return true end
					end
					return false
				end},
		{"Build the lamp from voxels on the cupboard: click the Lamp entry " ..
				"in the palette, pick Voxels (K) and go to 3D (the view " ..
				"dropdown, or F2). A left click takes the crosshair: aim at " ..
				"the cupboard's top and right click to place a voxel, then a " ..
				"few more. Esc lets the mouse go.",
				function()
					for _, i in ipairs(instances(1)) do
						for _, m in pairs(doc.voxels[i.ints.def] or {}) do
							if lamp_entry(m) then return true end
						end
					end
					return false
				end},
		{"A switch for it: pick Door/window (I), set Kind to Switch and " ..
				"click a wall. Then, with the switch selected, press \"Link " ..
				"lamps\" in its panel, click the lamp and press Done linking.",
				function() return #first_switch_lamps() > 0 end},
		{"Stairs: click the drywall entry in the palette (what is new gets " ..
				"the entry chosen), pick Object (O), set Shape to stairs in " ..
				"its panel and drag their footprint in a room. They climb " ..
				"along their depth.",
				function() return #instances(6) >= 1 end},
		{"A floor above: press the floor's button in the toolbar (it says " ..
				"its name), then Add a floor above. The new floor is edited " ..
				"now, the one below drawn under it.",
				function() return #of("layout") >= 2 end},
		{"Draw a room on the new floor with the Room tool, over the one " ..
				"below.",
				function()
					local cur = S().layout
					for _, r in ipairs(of("room")) do
						local n = doc.ents[r.lists.nodes[1]]
						if n and n.ints.layout == cur and cur ~= ground() then
							return true
						end
					end
					return false
				end},
		{"Back to the ground floor: press the floor's button and click the " ..
				"first one in the list.",
				function() return S().layout == ground() end},
		{"Walk in the house: choose Walk (F3) from the view dropdown. W, A, " ..
				"S and D walk; drag with the right mouse button to turn.",
				function() return S().view == "walk" end},
		{"Open the door: point at it and press E (or right click it).",
				function()
					for _, d in ipairs(instances(3)) do
						local lo = S().local_open and S().local_open[d.id]
						if (lo or d.ints.open) > 0 then return true end
					end
					return false
				end},
		{"Switch the lamp: point at the switch and press E. In the plan " ..
				"view a switch is small: drag a box over it to select it, " ..
				"then E switches the selected one.",
				function() return lamps_state() ~= mark.lamps end,
				function() mark.lamps = lamps_state() end},
		{"Switch the lamp on again if it is off. The light is the plan's " ..
				"place and moment: open the Menu (Esc), Plan settings, and " ..
				"type an evening time such as 22:00 in Time, then look at " ..
				"the room in 3D.",
				function() return math.abs(minute() - mark.minute) >= 60 end,
				function() mark.minute = minute() end},
		{"Menu, Client settings: set 3D lighting to Unlit, the plain look " ..
				"that is lighter to draw.",
				function() return S().lighting == "unlit" end},
		{"And back to PBR in the same place.",
				function() return S().lighting == "pbr" end},
		{"Menu, Plan settings: set Time-lapse to 1 h/s and watch the day " ..
				"go round in 3D; off stops it. Daylight: Temporary changes " ..
				"only your own view, which anyone may do.",
				function()
					local st = doc.settings and doc.settings()
					local t = S().sun_temp
					return (st and st.ints.lapse ~= 0) or (t and t.lapse ~= 0)
				end},
		{"That is the basics. Backups, members, copying and exporting are " ..
				"in the Menu. Press End to close this.",
				function() return false end},
	}

	local function show()
		if win then
			win:Remove()
			win = nil
		end
		if step < 1 or step > #STEPS then
			return
		end
		win = magic.ui.root:CreateChild("Window")
		win:SetStyleAuto()
		win:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(12, 10, 12, 10))
		-- At the lower right: the menus are in the middle and the panels
		-- at the top
		win:SetAlignment(magic.HA_RIGHT, magic.VA_BOTTOM)
		local width = math.min(460, magic.ui.root.width - 16)
		win:SetFixedWidth(width)
		win.priority = 20
		-- Over the hint lines at the bottom, four of them at most
		win:SetPosition(-8, -130)
		title = win:CreateChild("Text")
		title:SetStyleAuto()
		title:SetText("Tutorial, step " .. step .. " of " .. #STEPS)
		title:SetColor(magic.Color(1.0, 0.85, 0.3))
		body = win:CreateChild("Text")
		body:SetStyleAuto()
		body:SetFixedWidth(width - 48)
		body:SetWordwrap(true)
		body:SetText(STEPS[step][1])
		local row = win:CreateChild("UIElement")
		row:SetLayout(magic.LM_HORIZONTAL, 6, magic.IntRect(0, 0, 0, 0))
		local function button(text, fn)
			local b = row:CreateChild("Button")
			b:SetStyleAuto()
			b.minHeight = 24
			local t = b:CreateChild("Text")
			t:SetStyleAuto()
			t:SetText(text)
			t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
			b.minWidth = t.width + 20
			magic.SubscribeToEvent(b, "Released", fn)
		end
		if step < #STEPS then
			button("Skip this step", function() T.go(step + 1) end)
		end
		if step > 1 then
			button("Back", function() T.go(step - 1) end)
		end
		button("End", function() T.go(0) end)
	end

	function T.go(i)
		step = i
		buildat.storage_write("tutorial", tostring(i))
		mark = {}
		if STEPS[i] and STEPS[i][3] then
			STEPS[i][3]()
		end
		show()
	end

	function T.start()
		T.go(1)
	end

	-- The checks, a few times a second
	local since = 0
	magic.SubscribeToEvent("Update", function(_, data)
		if step < 1 or step > #STEPS then
			return
		end
		since = since + data:GetFloat("TimeStep")
		if since < 0.25 then
			return
		end
		since = 0
		if not win then
			T.go(step)
		end
		local ok, done = pcall(STEPS[step][2])
		if ok and done then
			T.go(step + 1)
		end
	end)

	-- A step's own marks start where it is on a reload too
	if step >= 1 and step <= #STEPS then
		T.go(step)
	end
	return T
end
-- vim: set noet ts=4 sw=4:
