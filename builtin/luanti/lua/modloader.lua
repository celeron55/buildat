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
	for _, mod in ipairs(ordered) do
		core.__current_modname = mod.name
		local chunk, err = loadfile(mod.path .. "/init.lua")
		if not chunk then
			error("Cannot load mod " .. mod.name .. ": " .. tostring(err))
		end
		chunk()
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

	local function count(t)
		local n = 0
		for _ in pairs(t or {}) do
			n = n + 1
		end
		return n
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
