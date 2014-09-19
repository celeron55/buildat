local log = buildat.Logger("__client/packet")

__buildat_packet_subs = {}

function buildat:sub_packet(name, cb)
	__buildat_packet_subs[name] = cb
end
function buildat:unsub_packet(cb)
	for name, cb1 in pairs(buildat.packet_subs) do
		if cb1 == cb then
			__buildat_packet_subs[cb] = nil
		end
	end
end

function buildat:send_packet(name, data)
	__buildat_send_packet(name, data)
end
