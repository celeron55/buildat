-- Buildat: extension/test/init.lua
local log = buildat.Logger("extension/test")

local M = {}

function M.f()
	log:info("Unsafe f() called")
end

M.safe = {}

function M.safe.f()
	log:info("Safe f() called")
end

return M
