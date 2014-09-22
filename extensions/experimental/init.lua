-- Buildat: extension/experimental/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/experimental")
local M = {safe = {}}

local subs_tick = {}

function __buildat_tick(dtime)
	for _, cb in ipairs(subs_tick) do
		cb(dtime)
	end
end

function M.safe.sub_tick(cb)
	table.insert(subs_tick, cb)
end
function M.safe.unsub_tick(cb)
	for i=#subs_tick,1,-1 do
		if subs_tick[i] == cb then
			table.remove(subs_tick, i)
		end
	end
end

return M
