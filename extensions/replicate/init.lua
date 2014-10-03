-- Buildat: extension/replicate/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/replicate")
local magic = require("buildat/extension/urho3d").safe
local dump = buildat.dump
local M = {safe = {}}

-- __buildat_replicated_scene is set by client/replication.lua
M.unsafe_main_scene = __buildat_replicated_scene
M.safe.main_scene = getmetatable(magic.Scene).wrap(__buildat_replicated_scene)

return M
-- vim: set noet ts=4 sw=4:
