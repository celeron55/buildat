-- Buildat: client/extensions.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/extensions")

-- Extension interfaces, indexed by extension name
local loaded_extensions = {}

-- Called by this file and client/sandbox.lua
function __buildat_require_extension(name)
	log:debug("__buildat_require_extension(\""..name.."\")")
	if loaded_extensions[name] then
		return loaded_extensions[name]
	end
	local path = __buildat_extension_path(name).."/init.lua"
	local script, err = loadfile(path)
	if script == nil then
		log:error("Extension could not be opened: "..name.." at "..path..": "..err)
		return nil
	end
	local interface = script()
	if interface == nil then
		log:error("Extension returned nil: "..name.." at "..path)
		return nil
	end
	loaded_extensions[name] = interface
	return interface
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
