-- Buildat: client/extensions.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/extensions")

-- Extension interfaces, indexed by extension name
local loaded_extensions = {}

-- [EXTENSIONS_SANDBOXED]: **an extension in extensions/ runs in the
-- sandbox**, as a server's client Lua and a launch UI do; only the
-- client's own, in client/extensions, are trusted. What it returns is
-- kept as it is, so trusted code reads its .safe as before, and the
-- sandbox's require hands out a view of that.
-- simplified: the ones below are still loaded trusted until they are
-- converted; the list only shrinks.
local NOT_YET_SANDBOXED = {luanti_client = true, sandbox_test = true}

local function load_trusted(name, path)
	local script, err = loadfile(path)
	if script == nil then
		log:error("Extension could not be opened: "..name.." at "..path..": "..err)
		return nil
	end
	return script()
end

local function load_sandboxed(name, path)
	local f = io.open(path, "rb")
	if not f then
		log:error("Extension could not be opened: "..name.." at "..path)
		return nil
	end
	local code = f:read("*a")
	f:close()
	-- The chunk's name is what run_extension_file and storage_read take
	-- the calling extension from
	local ok, err, interface = __buildat_run_code_in_sandbox(code,
			name.."/init.lua")
	if not ok then
		log:error("Extension "..name.." raised: "..tostring(err))
		return nil
	end
	return interface
end

-- Called by this file and client/sandbox.lua
function __buildat_require_extension(name)
	log:debug("__buildat_require_extension(\""..name.."\")")
	if loaded_extensions[name] then
		return loaded_extensions[name]
	end
	local dir = __buildat_extension_path(name)
	local own = __buildat_get_path("share").."/client/extensions/"
	local path = dir.."/init.lua"
	local interface
	if dir:sub(1, #own) == own or NOT_YET_SANDBOXED[name] then
		interface = load_trusted(name, path)
	else
		interface = load_sandboxed(name, path)
	end
	if interface == nil then
		log:error("Extension returned nil: "..name.." at "..path)
		return nil
	end
	loaded_extensions[name] = interface
	return interface
end

-- An extension that is already loaded, or nil -- **without loading it**,
-- which is what asking for the launcher must not do. The table above is
-- the only record of a loaded extension: `require` puts nothing in
-- `package.loaded` for these names, so every
-- `package.loaded["buildat/extension/..."]` in the tree read nil and the
-- code behind it never ran (found 2026-09-23 by [LAUNCH_WORLD], which
-- wanted the same lookup for its own name).
function __buildat_loaded_extension(name)
	return loaded_extensions[name]
end

-- Don't use package.loaders because for whatever reason it doesn't work in the
-- Windows version at least in Wine
-- TODO: Was that due to the table indexing bug which was fixed by using LuaJIT
--       instead of Lua?
local old_require = require

function require(name)
	log:debug("require called with name=\""..name.."\"")
	local m = string.match(name, '^buildat/extension/([a-zA-Z0-9_]+)$')
	if m then
		return __buildat_require_extension(m)
	end
	return old_require(name)
end

-- vim: set noet ts=4 sw=4:
