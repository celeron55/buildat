-- Buildat: extension/mouseinput/init.lua
local log = buildat.Logger("extension/mouseinput")
local M = {safe = {}}

local subs_move = {}
local subs_down = {}
local subs_up = {}

function __buildat_mouse_move(x, y)
	--log:info("__buildat_mouse_move("..x..", "..y..")")
	for _, cb in ipairs(subs_move) do
		cb(x, y)
	end
end

function __buildat_mouse_down(button, x, y)
	--log:info("__buildat_mouse_down("..button..", "..x..", "..y..")")
	for _, cb in ipairs(subs_down) do
		cb(button, x, y)
	end
end

function __buildat_mouse_up(button, x, y)
	--log:info("__buildat_mouse_up("..button..", "..x..", "..y..")")
	for _, cb in ipairs(subs_up) do
		cb(button, x, y)
	end
end

function M.safe.sub_move(cb)
	table.insert(subs_move, cb)
end
function M.safe.unsub_move(cb)
	for i=#subs_move,1,-1 do
		if subs_move[i] == cb then
			table.remove(subs_move, i)
		end
	end
end

function M.safe.sub_down(cb)
	table.insert(subs_down, cb)
end
function M.safe.unsub_down(cb)
	for i=#subs_down,1,-1 do
		if subs_down[i] == cb then
			table.remove(subs_down, i)
		end
	end
end

function M.safe.sub_up(cb)
	table.insert(subs_up, cb)
end
function M.safe.unsub_up(cb)
	for i=#subs_up,1,-1 do
		if subs_up[i] == cb then
			table.remove(subs_up, i)
		end
	end
end

return M
