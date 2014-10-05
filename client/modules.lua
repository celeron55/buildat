-- Buildat: client/modules.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/modules")

-- Module interfaces, indexed by module name
local loaded_modules = {}

-- Called by client/sandbox.lua
function __buildat_require_module(name)
	log:debug("__buildat_require_module(\""..name.."\")")
	if loaded_modules[name] then
		return loaded_modules[name]
	end
	local status, err, interface = buildat.run_script_file(name.."/module.lua")
	if not status then
		log:error("Module could not be loaded: "..name..": "..err)
		return nil
	end
	loaded_modules[name] = interface
	return interface
end

-- vim: set noet ts=4 sw=4:

