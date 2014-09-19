-- Buildat: client/init.lua
buildat = {}
function buildat:Logger(module)
	local logger = {}
	function logger:info(text)
		print(os.date("%b %d %H:%M:%S "..module..": "..text))
	end
	function logger:error(text)
		print(os.date("%b %d %H:%M:%S "..module.." ERROR: "..text))
	end
	return logger
end

local log = buildat:Logger("__client/init")

log:info("init.lua loaded")

dofile(__buildat_get_path("share").."/client/test.lua")
dofile(__buildat_get_path("share").."/client/packet.lua")
dofile(__buildat_get_path("share").."/client/sandbox.lua")

