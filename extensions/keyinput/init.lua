-- Buildat: extension/keyinput/init.lua
local log = buildat.Logger("extension/keyinput")
local M = {safe = {}}

local subs = {}

function __buildat_key_down(key)
	--log:info("__buildat_key_down("..key..")")
	for _, cb in ipairs(subs) do
		cb(key, "down")
	end
end

function __buildat_key_up(key)
	--log:info("__buildat_key_up("..key..")")
	for _, cb in ipairs(subs) do
		cb(key, "up")
	end
end

function M.safe.sub(cb)
	table.insert(subs, cb)
end

function M.safe.unsub(cb)
	for i=#subs,1,-1 do
		if subs[i] == cb then
			table.remove(subs, i)
		end
	end
end

-- Add keycodes from KEY_* globals
for k, v in pairs(_G) do
	if string.match(k, "KEY_[A-Z0-9_]+") then
		if type(v) == 'number' then
			M.safe[k] = v
		end
	end
end

return M
