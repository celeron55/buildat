-- Buildat: extension/test/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
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
