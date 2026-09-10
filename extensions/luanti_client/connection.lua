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
-- protocol id, peer id and channel
local BASE_HEADER_SIZE = 7
-- The type byte and the seqnum of a reliable packet
local RELIABLE_HEADER_SIZE = 3
-- The type byte, the split seqnum, the chunk count and the chunk number
local SPLIT_HEADER_SIZE = 7

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
			next_split_seqnum = 0,
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
	--
	-- Payloads that do not fit one datagram go as PACKET_TYPE_SPLIT chunks,
	-- each of which is a packet in its own right: a reliable send gets a
	-- seqnum per chunk. REQUEST_MEDIA is the first thing the client sends that
	-- needs this.
	function self:send(channel, reliable, data)
		local c = channels[channel]
		local chunk_size_max = MAX_PACKET_SIZE - BASE_HEADER_SIZE
		if reliable then
			chunk_size_max = chunk_size_max - RELIABLE_HEADER_SIZE
		end
		local packets = {}
		if #data + 1 > chunk_size_max then
			local split_seqnum = c.next_split_seqnum
			c.next_split_seqnum = (split_seqnum + 1) % 65536
			local payload_max = chunk_size_max - SPLIT_HEADER_SIZE
			local count = math.ceil(#data / payload_max)
			for i = 0, count - 1 do
				packets[#packets + 1] = serialize.writer()
						:u8(PACKET_TYPE_SPLIT):u16(split_seqnum)
						:u16(count):u16(i)
						:raw(data:sub(i * payload_max + 1,
								(i + 1) * payload_max))
						:data()
			end
		else
			packets[1] = serialize.writer():u8(PACKET_TYPE_ORIGINAL):raw(data)
					:data()
		end
		local ok = true
		for _, packet in ipairs(packets) do
			if reliable then
				local seqnum = c.next_outgoing_seqnum
				c.next_outgoing_seqnum = (seqnum + 1) % 65536
				local wrapped = serialize.writer():u8(PACKET_TYPE_RELIABLE)
						:u16(seqnum):raw(packet):data()
				c.unacked[seqnum] = {packet = wrapped, age = 0}
				ok = send_datagram(channel, wrapped) and ok
			else
				ok = send_datagram(channel, packet) and ok
			end
		end
		return ok
	end

	function self:disconnect()
		if not self.connected then
			return
		end
		send_control(0, CONTROLTYPE_DISCO)
		self.connected = false
	end

	local process_packet

	-- Assembled payloads waiting to be handed over. A burst of map blocks
	-- arrives as a hundred packets in one frame and parsing one is not free,
	-- so what a datagram costs here is the reassembly and the ack; the
	-- handler runs from pump() on the caller's own time budget.
	-- A queue with two indices rather than a list: the length operator on a
	-- table whose first entries have been taken out is not defined, and one
	-- payload landing on another loses it
	local pending = {}
	local pending_first = 1
	local pending_last = 0

	local function deliver(data, channel)
		pending_last = pending_last + 1
		pending[pending_last] = {data, channel}
	end

	-- Hands assembled payloads to on_data until budget_us microseconds have
	-- gone or there are none left, and says how many are still waiting. One
	-- is always handed over, so a payload that costs more than the whole
	-- budget still gets through.
	-- What the reliable layer is holding, per channel: how many of our own
	-- packets are waiting for an acknowledgement, how many of the server's
	-- have arrived early and are waiting for the ones before them, and how
	-- many split payloads are half assembled. A stall shows up here as
	-- unacked packets that do not clear or as an incoming queue that never
	-- empties, and neither is visible from anywhere else.
	function self:stats()
		local out = {}
		for channel = 0, M.CHANNEL_COUNT - 1 do
			local c = channels[channel]
			local unacked, incoming, splits = 0, 0, 0
			for _ in pairs(c.unacked) do unacked = unacked + 1 end
			for _ in pairs(c.incoming) do incoming = incoming + 1 end
			for _ in pairs(c.splits) do splits = splits + 1 end
			out[channel] = {unacked = unacked, incoming = incoming,
					splits = splits, next_in = c.next_incoming_seqnum,
					next_out = c.next_outgoing_seqnum}
		end
		return out
	end

	function self:pump(budget_us)
		local t0 = buildat.get_time_us()
		while pending_first <= pending_last do
			local entry = pending[pending_first]
			pending[pending_first] = nil
			pending_first = pending_first + 1
			if self.on_data then
				self.on_data(entry[1], entry[2])
			end
			if buildat.get_time_us() - t0 >= budget_us then
				break
			end
		end
		if pending_first > pending_last then
			-- Nothing waiting: start the indices over rather than let them
			-- run away
			pending_first = 1
			pending_last = 0
			return 0
		end
		return pending_last - pending_first + 1
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

	-- Call this every frame with the time since the last call.
	--
	-- self.last_receive_us is when the last datagram arrived, or nil if none
	-- has: whoever wants to know whether the other end is still there looks
	-- at that. Every datagram counts, acknowledgements included, because a
	-- peer that is alive at least acknowledges.
	function self:update(dtime)
		if not self.connected then
			return
		end
		while true do
			local data, err = socket:receive()
			if data then
				self.last_receive_us = buildat.get_time_us()
			end
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
