-- Buildat: extension/cereal/init.lua
local polybox = require("buildat/extension/polycode_sandbox")
local log = buildat.Logger("extension/cereal")
local M = {safe = {}}

function M.safe.binary_input(data, types)
	return __buildat_cereal_binary_input(data, types)
end

return M

