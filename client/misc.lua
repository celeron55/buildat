-- Buildat: client/misc.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/misc")

-- Replicated scene from the server
__buildat_sync_scene = nil

-- Called by the client application
function __buildat_set_sync_scene(scene)
	assert(scene)
	log:verbose("__buildat_set_sync_scene(): ok")
	__buildat_sync_scene = scene
end

-- vim: set noet ts=4 sw=4:
