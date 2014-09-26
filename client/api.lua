-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

function buildat.connect_server(address)
	return __buildat_connect_server(address)
end

-- vim: set noet ts=4 sw=4:
