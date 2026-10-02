-- Buildat: extension/cereal/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/cereal")
local M = {safe = {}}

M.safe.binary_input = buildat.cereal_binary_input
M.safe.binary_output = buildat.cereal_binary_output

return M
-- vim: set noet ts=4 sw=4:
