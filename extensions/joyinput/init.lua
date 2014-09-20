-- Buildat: extension/joystick/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("extension/joystick")
local core = CoreServices.getInstance():getCore()
local M = {safe = {}}

local subs_move = {}
local subs = {}

function __buildat_joystick_axis_move(joystick, axis, value)
	log:info("__buildat_joystick_axis_move("..joystick..", "..axis..", "..value..")")
	for _, cb in ipairs(subs_move) do
		cb(joystick, axis, value)
	end
end

function __buildat_joystick_button_down(joystick, button)
	log:info("__buildat_joystick_button_down("..joystick..", "..button..")")
	for _, cb in ipairs(subs) do
		cb(joystick, button, "down")
	end
end

function __buildat_joystick_button_up(joystick, button)
	log:info("__buildat_joystick_button_up("..joystick..", "..button..")")
	for _, cb in ipairs(subs) do
		cb(joystick, button, "up")
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

return M

