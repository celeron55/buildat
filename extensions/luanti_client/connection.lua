-- Buildat: extension/luanti_client/connection.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's UDP transport: three channels, each with its own reliable stream.
-- A datagram is
--
--   u32 protocol id | u16 sender peer id | u8 channel | packet
--
-- and a packet is one of
--
--   0 control:  u8 type, then ack (u16 seqnum), set_peer_id (u16), ping, disco
--   1 original: the payload as it is
--   2 split:    u16 seqnum, u16 chunk count, u16 chunk number, then the piece
--   3 reliable: u16 seqnum, then a packet of one of the other kinds
--
-- Reliable packets are acknowledged and handed on in seqnum order; the rest go
-- as they arrive.
--
-- Checked by test.lua in this directory, which runs it against a fake socket.

local serialize = dofile(__buildat_extension_path("luanti_client")..
		"/serialize.lua")

local M = {}

M.PROTOCOL_ID = 0x4f457403
M.PEER_ID_INEXISTENT = 0
M.PEER_ID_SERVER = 1
M.CHANNEL_COUNT = 3
M.SEQNUM_INITIAL = 65500

local PACKET_TYPE_CONTROL = 0
local PACKET_TYPE_ORIGINAL = 1
local PACKET_TYPE_SPLIT = 2
local PACKET_TYPE_RELIABLE = 3

local CONTROLTYPE_ACK = 0
local CONTROLTYPE_SET_PEER_ID = 1
local CONTROLTYPE_PING = 2
local CONTROLTYPE_DISCO = 3

local RESEND_TIMEOUT = 0.5
local PING_INTERVAL = 5.0
-- What one datagram carries; Luanti's own default before MTU discovery
local MAX_PACKET_SIZE = 512

local function seqnum_higher(totest, base)
	if totest > base then
		return (totest - base) <= 32767
	end
	return (base - totest) > 32767
end

-- conn.on_data(data, channel) gets each assembled payload,
-- conn.on_disconnect(reason) gets told when the peer goes away.
function M.new(socket, log)
	local self = {
		socket = socket,
		peer_id = M.PEER_ID_INEXISTENT,
		on_data = nil,
		on_disconnect = nil,
		connected = true,
	}
	local channels = {}
	for i = 0, M.CHANNEL_COUNT - 1 do
		channels[i] = {
			next_outgoing_seqnum = M.SEQNUM_INITIAL,
			next_incoming_seqnum = M.SEQNUM_INITIAL,
			incoming = {},   -- seqnum -> payload waiting for its turn
			unacked = {},    -- seqnum -> {data=, age=}
			splits = {},     -- seqnum -> {count=, got=, chunks={}}
		}
	end
	local time_since_send = 0

	local function send_datagram(channel, packet)
		local w = serialize.writer()
		w:u32(M.PROTOCOL_ID):u16(self.peer_id):u8(channel):raw(packet)
		local data = w:data()
		if #data > MAX_PACKET_SIZE then
			-- simplified: no outgoing split. Nothing the client sends during
			-- login and play is this big; media requests would be, and this is
			-- where PACKET_TYPE_SPLIT would go on the sending side too.
			error("luanti_client/connection: packet of "..#data..
					" bytes is too big to send")
		end
		local sent, err = socket:send(data)
		if not sent then
			log:warning("send failed: "..tostring(err))
			return false
		end
		time_since_send = 0
		return true
	end

	local function send_control(channel, controltype, seqnum_or_nil)
		local w = serialize.writer()
		w:u8(PACKET_TYPE_CONTROL):u8(controltype)
		if seqnum_or_nil then
			w:u16(seqnum_or_nil)
		end
		send_datagram(channel, w:data())
	end

	-- send(channel, reliable, data)
	function self:send(channel, reliable, data)
		local original = serialize.writer():u8(PACKET_TYPE_ORIGINAL):raw(data)
				:data()
		if not reliable then
			return send_datagram(channel, original)
		end
		local c = channels[channel]
		local seqnum = c.next_outgoing_seqnum
		c.next_outgoing_seqnum = (seqnum + 1) % 65536
		local packet = serialize.writer():u8(PACKET_TYPE_RELIABLE):u16(seqnum)
				:raw(original):data()
		c.unacked[seqnum] = {packet = packet, age = 0}
		return send_datagram(channel, packet)
	end

	function self:disconnect()
		if not self.connected then
			return
		end
		send_control(0, CONTROLTYPE_DISCO)
		self.connected = false
	end

	local process_packet

	local function deliver(data, channel)
		if self.on_data then
			self.on_data(data, channel)
		end
	end

	local function process_split(channel, r)
		local c = channels[channel]
		local seqnum = r:u16()
		local count = r:u16()
		local num = r:u16()
		local split = c.splits[seqnum]
		if not split then
			split = {count = count, got = 0, chunks = {}}
			c.splits[seqnum] = split
		end
		if not split.chunks[num] then
			split.chunks[num] = r:rest()
			split.got = split.got + 1
		end
		if split.got < split.count then
			return
		end
		local parts = {}
		for i = 0, split.count - 1 do
			parts[#parts + 1] = split.chunks[i]
		end
		c.splits[seqnum] = nil
		deliver(table.concat(parts), channel)
	end

	local function process_control(channel, r)
		local controltype = r:u8()
		if controltype == CONTROLTYPE_ACK then
			local seqnum = r:u16()
			channels[channel].unacked[seqnum] = nil
		elseif controltype == CONTROLTYPE_SET_PEER_ID then
			self.peer_id = r:u16()
			log:info("Got peer id "..self.peer_id)
		elseif controltype == CONTROLTYPE_PING then
			-- Nothing to do; a reliable ping is answered by its ack
		elseif controltype == CONTROLTYPE_DISCO then
			self.connected = false
			if self.on_disconnect then
				self.on_disconnect("The server closed the connection")
			end
		else
			log:warning("Unknown control type "..controltype)
		end
	end

	local function process_reliable(channel, r)
		local c = channels[channel]
		local seqnum = r:u16()
		local payload = r:rest()
		-- Acknowledge even a duplicate; the ack for the first one may be what
		-- got lost
		send_control(channel, CONTROLTYPE_ACK, seqnum)
		if seqnum == c.next_incoming_seqnum then
			c.next_incoming_seqnum = (seqnum + 1) % 65536
			process_packet(channel, payload)
			-- Whatever arrived early can go now
			while c.incoming[c.next_incoming_seqnum] do
				local next_payload = c.incoming[c.next_incoming_seqnum]
				c.incoming[c.next_incoming_seqnum] = nil
				c.next_incoming_seqnum = (c.next_incoming_seqnum + 1) % 65536
				process_packet(channel, next_payload)
			end
		elseif seqnum_higher(seqnum, c.next_incoming_seqnum) then
			c.incoming[seqnum] = payload
		end
		-- Anything older has been processed already
	end

	process_packet = function(channel, packet)
		local r = serialize.reader(packet)
		local packet_type = r:u8()
		if packet_type == PACKET_TYPE_ORIGINAL then
			deliver(r:rest(), channel)
		elseif packet_type == PACKET_TYPE_RELIABLE then
			process_reliable(channel, r)
		elseif packet_type == PACKET_TYPE_CONTROL then
			process_control(channel, r)
		elseif packet_type == PACKET_TYPE_SPLIT then
			process_split(channel, r)
		else
			log:warning("Unknown packet type "..packet_type)
		end
	end

	local function process_datagram(data)
		local r = serialize.reader(data)
		if r:u32() ~= M.PROTOCOL_ID then
			log:warning("Datagram with a foreign protocol id; ignoring")
			return
		end
		r:u16() -- The sender's peer id; the server's, and we know who it is
		local channel = r:u8()
		if channel >= M.CHANNEL_COUNT then
			log:warning("Datagram on channel "..channel.."; ignoring")
			return
		end
		process_packet(channel, r:rest())
	end

	-- Call this every frame with the time since the last call
	function self:update(dtime)
		if not self.connected then
			return
		end
		while true do
			local data, err = socket:receive()
			if not data then
				if err ~= "timeout" then
					self.connected = false
					if self.on_disconnect then
						self.on_disconnect(err)
					end
				end
				break
			end
			local ok, process_err = pcall(process_datagram, data)
			if not ok then
				log:warning("Bad datagram: "..tostring(process_err))
			end
		end
		if not self.connected then
			return
		end
		for channel = 0, M.CHANNEL_COUNT - 1 do
			for seqnum, packet in pairs(channels[channel].unacked) do
				packet.age = packet.age + dtime
				if packet.age >= RESEND_TIMEOUT then
					packet.age = 0
					log:verbose("Resending seqnum "..seqnum..
							" on channel "..channel)
					send_datagram(channel, packet.packet)
				end
			end
		end
		time_since_send = time_since_send + dtime
		if time_since_send >= PING_INTERVAL then
			send_control(0, CONTROLTYPE_PING)
		end
	end

	return self
end

return M
-- vim: set noet ts=4 sw=4:
