-- Buildat: client/packet.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/packet")

local packet_subs = {}

-- Microseconds the packets' Lua took since the reader last took it, and
-- the packet that took longest since then: the frame peak's "packets"
-- phase ([FRAME_PEAK]). A packet's work is a phase of the frame it lands
-- in, and it was the largest one in the first fuzz runs.
buildat.packet_us = {total = 0, worst = 0, worst_name = ""}
-- take_packet_us() -> {total, worst, worst_name}, zeroed after: the
-- sandbox sees its tables read-only, so the taking is the client's
buildat.safe.take_packet_us = function()
	local acc = buildat.packet_us
	local out = {total = acc.total, worst = acc.worst,
			worst_name = acc.worst_name}
	acc.total, acc.worst, acc.worst_name = 0, 0, ""
	return out
end

function __buildat_handle_packet(name, data)
	local cb = packet_subs[name]
	if cb then
		local t0 = buildat.get_time_us()
		cb(data)
		local us = buildat.get_time_us() - t0
		local acc = buildat.packet_us
		acc.total = acc.total + us
		if us > acc.worst then
			acc.worst, acc.worst_name = us, name
		end
	end
end

-- Every handler dropped: a menu-only connection left ([MENU_CONTEXT])
function __buildat_reset_packet_subs()
	packet_subs = {}
end

function buildat.sub_packet(name, cb)
	packet_subs[name] = cb
end
buildat.safe.sub_packet = buildat.sub_packet

function buildat.unsub_packet(cb)
	for name, cb1 in pairs(buildat.packet_subs) do
		if cb1 == cb then
			packet_subs[cb] = nil
		end
	end
end
buildat.safe.unsub_packet = buildat.unsub_packet

function buildat.send_packet(name, data)
	__buildat_send_packet(name, data)
end
buildat.safe.send_packet = buildat.send_packet

-- vim: set noet ts=4 sw=4:
