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

-- Every mod directory under path, one modpack deep, as {name, path, depends,
-- optional_depends}
function M.scan_mods(path, out)
	out = out or {}
	for _, node in ipairs(__luanti_list_dir(path)) do
		if node.is_directory and node.name:sub(1, 1) ~= "." then
			local dir = path .. "/" .. node.name
			local conf = M.parse_conf(read_file(dir .. "/mod.conf"))
			if read_file(dir .. "/init.lua") then
				out[#out + 1] = {
					name = conf.name or node.name,
					path = dir,
					depends = M.split_list(conf.depends),
					optional_depends = M.split_list(conf.optional_depends),
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
-- A dependency that is not there is an error for depends and nothing for
-- optional_depends, which is what Luanti does.
function M.order_mods(mods, first_mod, last_mod)
	local by_name = {}
	for _, mod in ipairs(mods) do
		by_name[mod.name] = mod
	end

	local function weight(mod)
		if mod.name == first_mod then
			return 0
		elseif mod.name == last_mod then
			return 2
		end
		return 1
	end

	local out = {}
	local state = {}   -- nil, "visiting", "done"

	local function visit(mod, w)
		if state[mod.name] == "done" then
			return
		end
		if state[mod.name] == "visiting" then
			error("Circular mod dependency at " .. mod.name)
		end
		state[mod.name] = "visiting"
		for _, dep in ipairs(mod.depends) do
			local d = by_name[dep]
			if not d then
				error("Mod " .. mod.name .. " depends on " .. dep ..
						", which is not there")
			end
			visit(d, w)
		end
		for _, dep in ipairs(mod.optional_depends) do
			local d = by_name[dep]
			if d and weight(d) <= w then
				visit(d, w)
			end
		end
		state[mod.name] = "done"
		out[#out + 1] = mod
	end

	for w = 0, 2 do
		for _, mod in ipairs(mods) do
			if weight(mod) == w then
				visit(mod, w)
			end
		end
	end
	return out
end

return M

-- vim: set noet ts=4 sw=4:
