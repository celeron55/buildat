-- Buildat: extension/entitysync/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/entitysync")
local unsafe_magic = require("buildat/extension/urho3d")
local magic = unsafe_magic.safe
local dump = buildat.dump
local M = {safe = {}}

--M.safe.scene = getmetatable(magic.Scene).wrap(__buildat_sync_scene)
M.safe.scene = __buildat_sync_scene
--__buildat_sandbox_debug_check_value(M.safe.scene)

return M
-- vim: set noet ts=4 sw=4:
