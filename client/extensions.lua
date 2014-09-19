local log = buildat:Logger("__client/extensions")

function __buildat_load_extension(name)
	log:info("__buildat_load_extension(\""..name.."\")")
	return dofile(__buildat_get_path("share").."/extensions/"..name.."/init.lua")
end

table.insert(package.loaders, function(name)
	log:info("package.loader called with name=\""..name.."\"")
	local m = string.match(name, '^buildat/extension/([a-zA-Z0-9_]+)$')
	if m then
		return function()
			return __buildat_load_extension(m)
		end
	end
	return nil
end)
