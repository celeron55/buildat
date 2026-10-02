-- SPDX-License-Identifier: Apache-2.0 OR MIT
-- Does the mapgen report what it made?
--
-- Run it against devtest, whose v7 world has dungeons and large caves in
-- it, and watch for the one line it logs:
--
--   BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=gennotify_check \
--   BUILDAT_LUANTI_LUA=builtin/luanti/test/gennotify.lua \
--   bin/buildat_server -m ../apps/vanilla -D ../user
--
-- A client has to connect for the world to stream, which is what makes
-- sections generate. See core.set_gen_notify() in lua/bootstrap.lua for
-- which side does what.
core.set_gen_notify("dungeon,temple,cave_begin,cave_end,large_cave_begin," ..
		"large_cave_end")

-- A decoration of this file's own, because devtest registers none and a
-- decoration is reported by id rather than by the flag alone: what a mod
-- hears about is the ids it named, which is how VoxeLibre's mcl_structures
-- finds out where its structures may go.
local marker_id = nil
-- Once every mod has registered, because devtest's mapgen mod calls
-- core.clear_registered_decorations() while it loads and this would go with
-- them. The generator is made after this, so its id is the one the mapgen
-- reports.
core.register_on_mods_loaded(function()
	core.register_decoration({
		name = "gennotify_check:marker",
		deco_type = "simple",
		place_on = {"mapgen_stone", "mapgen_dirt_with_grass", "mapgen_dirt"},
		sidelen = 16,
		fill_ratio = 0.02,
		y_min = -128,
		y_max = 128,
		decoration = "mapgen_stone",
	})
	marker_id = core.get_decoration_id("gennotify_check:marker")
	assert(marker_id, "the check's own decoration has no id")
	core.set_gen_notify({decoration = true}, {marker_id})
end)

local SECTIONS = 24
local seen = 0
local counts = {}
local a_position = nil
local said = false

core.register_on_generated(function(minp, maxp, seed)
	if said then
		return
	end
	local gn = core.get_mapgen_object("gennotify")
	assert(type(gn) == "table", "gennotify is not a table")
	for name, list in pairs(gn) do
		counts[name] = (counts[name] or 0) + #list
		for _, pos in ipairs(list) do
			-- Luanti reports a position inside the chunk it made the thing
			-- in, and a mod builds where it is told to
			assert(pos.x >= minp.x and pos.x <= maxp.x and
					pos.y >= minp.y and pos.y <= maxp.y and
					pos.z >= minp.z and pos.z <= maxp.z,
					"gennotify " .. name .. " at " ..
					core.pos_to_string(pos) .. " is outside " ..
					core.pos_to_string(minp) .. ".." ..
					core.pos_to_string(maxp))
			a_position = a_position or (name .. " at " ..
					core.pos_to_string(pos))
		end
	end
	seen = seen + 1
	if seen < SECTIONS then
		return
	end
	said = true
	local parts = {}
	for name, n in pairs(counts) do
		parts[#parts + 1] = name .. "=" .. n
	end
	table.sort(parts)
	local marker = counts["decoration#" .. tostring(marker_id)]
	if #parts == 0 then
		core.log("error", "gennotify check: FAILED -- " .. seen ..
				" sections and the mapgen reported nothing")
	elseif marker == nil then
		core.log("error", "gennotify check: FAILED -- nothing about " ..
				"decoration#" .. tostring(marker_id) .. ", which is this " ..
				"file's own: " .. table.concat(parts, " "))
	else
		core.log("action", "gennotify check: passed -- " ..
				table.concat(parts, " ") .. " over " .. seen ..
				" sections, first " .. tostring(a_position))
	end
end)
