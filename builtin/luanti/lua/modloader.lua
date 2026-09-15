-- Buildat: builtin/luanti/lua/modloader.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Finds the game's mods, puts them in dependency order, and runs them.
--
-- Not here: world mods, global mods and load_mod_* in world.mt. A world under
-- cache/luanti is a world for running a game, not for installing mods into;
-- when that changes this is where it goes.

local game_path = __luanti_game_path
local read_file = core.__read_file

-- Before the game's mods, because whatever the check of the map puts in the
-- world is a node like any other and has to be in the registry with them
core.__register_check_nodes()

do
	-- The two shapes a game writes a position setting in, which is what
	-- core.setting_get_pos() reads a static_spawnpoint out of. tutorial's
	-- minetest.conf has the second, spaces and all, and a game whose
	-- spawn point does not parse is refused by the vendored builtin's
	-- static_spawn.lua before it registers a node.
	--
	-- Checked here rather than beside setting_get_pos() because the parser
	-- is the vendored builtin's and bootstrap.lua runs before that.
	local a = core.string_to_pos("(93,4.6,24)")
	local b = core.string_to_pos("93, 4.6, 24")
	assert(a and b and a.x == b.x and a.y == b.y and a.z == b.z,
			"a position setting reads the same with and without brackets")
	assert(b.y == 4.6, "and keeps the fraction")
	assert(core.string_to_pos("93, 4.6") == nil,
			"while two numbers are not a position")
	-- And the method the builtin actually calls, which is the Settings
	-- one rather than core.setting_get_pos()
	core.settings:set("__check_pos", "93, 4.6, 24")
	local c = core.settings:get_pos("__check_pos")
	assert(c and c.y == 4.6, "core.settings:get_pos() reads one as well")
	core.settings:remove("__check_pos")
	assert(core.settings:get_pos("__check_pos") == nil,
			"and answers nil for a setting that is not there")
end

local modlist = dofile(__luanti_module_path .. "/lua/modlist.lua")
modlist.set_read_file(read_file)

do
	local game_conf = modlist.parse_conf(read_file(game_path .. "/game.conf"))
	local mods = modlist.scan_mods(game_path .. "/mods")
	local ordered = modlist.order_mods(mods, game_conf.first_mod, game_conf.last_mod)

	for _, mod in ipairs(ordered) do
		core.__mod_paths[mod.name] = mod.path
		core.__mod_names[#core.__mod_names + 1] = mod.name
	end

	core.log("action", "Loading " .. #ordered .. " mods from " .. game_path)
	local t0 = core.get_us_time()
	-- How long each mod took, because the first thing anybody porting a game
	-- asks about a two-minute startup is which mod it was. A clock read per
	-- mod is nothing beside loading one.
	local took = {}
	for i, mod in ipairs(ordered) do
		-- Whoever is waiting for the world hears which mod this is on:
		-- 220 of them take minutes and a screen that says nothing looks
		-- hung. Not a percentage -- how long the rest will take is not
		-- known -- and not the log, which is what a terminal is for.
		if __luanti_progress then
			__luanti_progress(i .. "/" .. #ordered .. " " .. mod.name)
		end
		core.__current_modname = mod.name
		local chunk, err = loadfile(mod.path .. "/init.lua")
		if not chunk then
			error("Cannot load mod " .. mod.name .. ": " .. tostring(err))
		end
		local mod_t0 = core.get_us_time()
		chunk()
		took[#took + 1] = {mod.name, core.get_us_time() - mod_t0}
	end
	core.__current_modname = nil

	-- What a mod does once every other mod has registered what it has:
	-- Luanti runs these after the last init.lua and before anything steps,
	-- and the vendored builtin's own -- the one that freezes the item and
	-- node registries -- is among them.
	for _, cb in ipairs(core.registered_on_mods_loaded or {}) do
		local ok, err = pcall(cb)
		if not ok then
			core.log("error", "on_mods_loaded: " .. tostring(err))
		end
	end

	-- Everything a generator is a function of is read after this point, so
	-- what a mod registers from here on is not in the world it makes; see
	-- core.set_gen_notify() in bootstrap.lua
	core.__mods_loaded = true

	local function count(t)
		local n = 0
		for _ in pairs(t or {}) do
			n = n + 1
		end
		return n
	end
	-- The slowest ten, longest first, and only the ones worth a line
	table.sort(took, function(a, b) return a[2] > b[2] end)
	local slowest = {}
	for i = 1, math.min(10, #took) do
		if took[i][2] < 100000 then
			break
		end
		slowest[#slowest + 1] = string.format("%s %.1f s", took[i][1],
				took[i][2] / 1000000)
	end
	if #slowest > 0 then
		core.log("action", "The mods that took longest to load: " ..
				table.concat(slowest, ", "))
	end

	core.log("action", string.format(
			"Mods loaded in %.1f s: %d nodes, %d craftitems, %d tools, " ..
			"%d items in all, %d aliases",
			(core.get_us_time() - t0) / 1000000,
			count(core.registered_nodes), count(core.registered_craftitems),
			count(core.registered_tools), count(core.registered_items),
			count(core.registered_aliases)))
end

-- vim: set noet ts=4 sw=4:
