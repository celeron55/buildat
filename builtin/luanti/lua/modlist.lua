-- Buildat: builtin/luanti/lua/modlist.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- What a mod is and what order mods load in: Luanti's ServerModManager in the
-- shape Lua makes it. A mod is a directory with an init.lua, a modpack is a
-- directory of those, and mod.conf says what a mod is called and what it
-- needs. Separated from modloader.lua so that test.lua can run the ordering
-- without a filesystem under it.

local M = {}

local read_file

-- The module needs a way to read a file; luanti.cpp gives Lua io, and
-- test.lua gives a fake
function M.set_read_file(f)
	read_file = f
end

function M.parse_conf(text)
	local out = {}
	if not text then
		return out
	end
	for line in text:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([^#=][^=]-)%s*=%s*(.-)%s*$")
		if key then
			out[key] = value
		end
	end
	return out
end

-- "a, b ,c" -> {"a", "b", "c"}
function M.split_list(s)
	local out = {}
	for item in tostring(s or ""):gmatch("[^,]+") do
		item = item:match("^%s*(.-)%s*$")
		if item ~= "" then
			out[#out + 1] = item
		end
	end
	return out
end

-- Luanti's older depends.txt, which mod.conf replaced and which plenty of
-- games still ship: one mod a line, a trailing "?" making it optional.
-- Returns the two lists.
function M.parse_depends_txt(text)
	local depends, optional = {}, {}
	for line in tostring(text or ""):gmatch("[^\r\n]+") do
		local name = line:match("^%s*(.-)%s*$")
		if name ~= "" then
			local opt = name:match("^(.-)%s*%?$")
			if opt then
				optional[#optional + 1] = opt
			else
				depends[#depends + 1] = name
			end
		end
	end
	return depends, optional
end

-- Every mod directory under path, one modpack deep, as {name, path, depends,
-- optional_depends}
function M.scan_mods(path, out)
	out = out or {}
	for _, node in ipairs(__luanti_list_dir(path)) do
		if node.is_directory and node.name:sub(1, 1) ~= "." then
			local dir = path .. "/" .. node.name
			local conf = M.parse_conf(read_file(dir .. "/mod.conf"))
			if read_file(dir .. "/init.lua") then
				local depends = M.split_list(conf.depends)
				local optional = M.split_list(conf.optional_depends)
				-- depends.txt is read only when mod.conf says nothing about
				-- dependencies at all, which is Luanti's own rule: a mod
				-- carrying both is a mod being ported, and its mod.conf is
				-- the one it means.
				if conf.depends == nil and conf.optional_depends == nil then
					depends, optional = M.parse_depends_txt(
							read_file(dir .. "/depends.txt"))
				end
				out[#out + 1] = {
					name = conf.name or node.name,
					path = dir,
					depends = depends,
					optional_depends = optional,
				}
			elseif read_file(dir .. "/modpack.conf") or
					read_file(dir .. "/modpack.txt") then
				M.scan_mods(dir, out)
			else
				-- A directory that is neither is not ours to guess about
				M.scan_mods(dir, out)
			end
		end
	end
	return out
end

-- Dependency order, with game.conf's first_mod and last_mod on either end.
--
-- **This is Luanti's own algorithm and not merely a topological sort**, and
-- the difference is visible: a game whose mods write each other's globals
-- without saying they depend on them works or does not work depending on
-- which valid order it gets. realtest is one -- its `light` assigns a
-- global called `metals` and its `hatches` reads the `metals` mod's table
-- of the same name -- and it runs on Luanti because Luanti happens to load
-- them the other way round. See ModConfiguration::resolveDependencies() in
-- Luanti's src/content/mod_configuration.cpp.
--
-- The shape that matters: the mods that start with nothing to wait for go
-- on a **stack** in scan order, and each one taken off it is taken from the
-- **end**; a mod whose last dependency has just arrived goes on the same
-- stack and so is taken next. That is depth-first from the last dep-free
-- mod backwards, which is not what visiting each mod's dependencies first
-- gives.
function M.order_mods(mods, first_mod, last_mod)
	first_mod = (first_mod ~= "" and first_mod) or nil
	last_mod = (last_mod ~= "" and last_mod) or nil

	local modnames = {}
	local first_spec, last_spec
	for _, mod in ipairs(mods) do
		if mod.name == first_mod then
			first_spec = mod
		elseif mod.name == last_mod then
			last_spec = mod
		else
			modnames[mod.name] = true
		end
	end
	if first_mod and not first_spec then
		error("The mod specified as first by the game was not found: " ..
				first_mod)
	end
	if last_mod and not last_spec then
		error("The mod specified as last by the game was not found: " ..
				last_mod)
	end

	local sorted = {}
	if first_spec then
		if #first_spec.depends > 0 or #first_spec.optional_depends > 0 then
			error("Mod specified by first_mod cannot have dependencies")
		end
		sorted[#sorted + 1] = first_spec
	end

	-- What a mod is still waiting for: everything it depends on, and the
	-- optional ones that are actually there. first_mod is already loaded.
	local function unmet_of(mod)
		local t = {}
		for _, dep in ipairs(mod.depends) do
			if dep ~= first_mod then
				t[dep] = true
			end
		end
		for _, dep in ipairs(mod.optional_depends) do
			if modnames[dep] then
				t[dep] = true
			end
		end
		if last_mod and t[last_mod] and mod ~= last_spec then
			error("Mod " .. mod.name .. " depends on " .. last_mod ..
					", which the game says loads last")
		end
		return t
	end

	local unmet = {}
	local satisfied = {}     -- a stack: taken from the end
	local unsatisfied = {}   -- in scan order
	for _, mod in ipairs(mods) do
		if mod ~= first_spec and mod ~= last_spec then
			unmet[mod.name] = unmet_of(mod)
			if next(unmet[mod.name]) == nil then
				satisfied[#satisfied + 1] = mod
			else
				unsatisfied[#unsatisfied + 1] = mod
			end
		end
	end
	if last_spec then
		unmet[last_spec.name] = unmet_of(last_spec)
	end

	while #satisfied > 0 do
		local mod = table.remove(satisfied)
		sorted[#sorted + 1] = mod
		local rest = {}
		for _, mod2 in ipairs(unsatisfied) do
			unmet[mod2.name][mod.name] = nil
			if next(unmet[mod2.name]) == nil then
				satisfied[#satisfied + 1] = mod2
			else
				rest[#rest + 1] = mod2
			end
		end
		unsatisfied = rest
		if last_spec then
			unmet[last_spec.name][mod.name] = nil
		end
	end

	if last_spec then
		if next(unmet[last_spec.name]) == nil then
			sorted[#sorted + 1] = last_spec
		else
			unsatisfied[#unsatisfied + 1] = last_spec
		end
	end

	-- What is left over never got everything it was waiting for: a
	-- dependency that is not installed, or a cycle. Which of the two it is
	-- is worth saying, because they are fixed in different places.
	if #unsatisfied > 0 then
		local said = {}
		for _, mod in ipairs(unsatisfied) do
			local missing = {}
			for dep in pairs(unmet[mod.name]) do
				missing[#missing + 1] = dep ..
						(modnames[dep] and "" or " (not there)")
			end
			table.sort(missing)
			said[#said + 1] = mod.name .. " waits for " ..
					table.concat(missing, ", ")
		end
		table.sort(said)
		error("Mods that never got what they depend on -- a dependency " ..
				"that is not installed, or a cycle: " ..
				table.concat(said, "; "))
	end
	return sorted
end

return M

-- vim: set noet ts=4 sw=4:
