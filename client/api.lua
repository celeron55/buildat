-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
buildat.extension_path    = __buildat_extension_path

buildat.safe.disconnect    = __buildat_disconnect

-- vim: set noet ts=4 sw=4:
