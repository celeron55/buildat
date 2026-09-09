-- Buildat: extension/luanti_client/test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Checks serialize.lua and connection.lua against a fake socket. Wants no
-- engine, so:
--
--   $ lua extensions/luanti_client/test.lua
--
-- The parts that need the engine are checked elsewhere: srp.lua has
-- self_test() (run at boot, vectors from util/srp_reference.py), and the whole
-- thing gets checked by logging into a Luanti server.

local dir = arg[0]:match("^(.*)/[^/]*$") or "."
__buildat_extension_path = function(name)
	return dir
end

local serialize = dofile(dir.."/serialize.lua")
local connection = dofile(dir.."/connection.lua")

local log = {}
for _, level in ipairs({"error", "warning", "info", "verbose", "debug"}) do
	log[level] = function(self, text) end
end

-- serialize.lua

local w = serialize.writer()
w:u8(0x12):u16(0x3456):u32(0x789abcde):s16(-2):s32(-2):string("hi")
		:longstring("yo"):raw("!")
local data = w:data()
-- Decimal escapes; hex ones would need Lua 5.2
assert(data == "\018\052\086\120\154\188\222\255\254\255\255\255\254"..
		"\000\002hi\000\000\000\002yo!", "serialize: wrong bytes out")

local r = serialize.reader(data)
assert(r:u8() == 0x12)
assert(r:u16() == 0x3456)
assert(r:u32() == 0x789abcde)
assert(r:s16() == -2)
assert(r:s32() == -2)
assert(r:string() == "hi")
assert(r:longstring() == "yo")
assert(r:remaining() == 1)
assert(r:rest() == "!")
assert(not pcall(function() r:u8() end), "serialize: read past the end")

-- Values at the edges
local edge = serialize.reader(serialize.writer():u16(0xffff):u32(0xffffffff)
		:s16(-32768):s32(-2147483648):data())
assert(edge:u16() == 0xffff)
assert(edge:u32() == 0xffffffff)
assert(edge:s16() == -32768)
assert(edge:s32() == -2147483648)

-- f32: IEEE 754 single precision, big-endian, which is what positions come in
local function f32(a, b, c, d)
	return serialize.reader(string.char(a, b, c, d)):f32()
end
assert(f32(0x00, 0x00, 0x00, 0x00) == 0, "serialize: f32 zero")
assert(f32(0x3f, 0x80, 0x00, 0x00) == 1, "serialize: f32 one")
assert(f32(0xbf, 0x80, 0x00, 0x00) == -1, "serialize: f32 minus one")
assert(f32(0x41, 0x20, 0x00, 0x00) == 10, "serialize: f32 ten")
assert(f32(0xc5, 0xcd, 0x8c, 0x00) == -6577.5, "serialize: f32 a position")
assert(f32(0x7f, 0x80, 0x00, 0x00) == math.huge, "serialize: f32 infinity")
local nan = f32(0x7f, 0xc0, 0x00, 0x00)
assert(nan ~= nan, "serialize: f32 NaN")
-- The smallest subnormal, which is the one case with no implicit leading one
assert(f32(0x00, 0x00, 0x00, 0x01) > 0, "serialize: f32 subnormal")

-- v3s16 and v3f, in the order the bytes came in
local v = serialize.reader(serialize.writer():v3s16(-1, 2, -3)
		:raw(string.char(0x3f, 0x80, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
				0x40, 0x40, 0x00, 0x00)):data())
local x, y, z = v:v3s16()
assert(x == -1 and y == 2 and z == -3, "serialize: v3s16")
local fx, fy, fz = v:v3f()
assert(fx == 1 and fy == 2 and fz == 3, "serialize: v3f")

print("serialize: ok")

-- connection.lua

local function fake_socket()
	local s = {sent = {}, incoming = {}}
	function s:send(data)
		self.sent[#self.sent + 1] = data
		return #data
	end
	function s:receive()
		local data = table.remove(self.incoming, 1)
		if not data then
			return nil, "timeout"
		end
		return data
	end
	function s:address()
		return "test:30000"
	end
	return s
end

-- What the server would send us
local function datagram(peer_id, channel, packet)
	return serialize.writer():u32(connection.PROTOCOL_ID):u16(peer_id)
			:u8(channel):raw(packet):data()
end

local function reliable(seqnum, packet)
	return serialize.writer():u8(3):u16(seqnum):raw(packet):data()
end

local function original(payload)
	return serialize.writer():u8(1):raw(payload):data()
end

local function split(seqnum, count, num, piece)
	return serialize.writer():u8(2):u16(seqnum):u16(count):u16(num):raw(piece)
			:data()
end

local socket = fake_socket()
local conn = connection.new(socket, log)
local got = {}
conn.on_data = function(data, channel)
	got[#got + 1] = {data = data, channel = channel}
end

-- Sending: header, then the packet
conn:send(1, false, "hello")
assert(#socket.sent == 1)
local sent = serialize.reader(socket.sent[1])
assert(sent:u32() == connection.PROTOCOL_ID, "connection: wrong protocol id")
assert(sent:u16() == 0, "connection: peer id should still be 0")
assert(sent:u8() == 1, "connection: wrong channel")
assert(sent:u8() == 1, "connection: unreliable data should be an original")
assert(sent:rest() == "hello")

-- A reliable send is remembered until it is acknowledged, and resent if it is
-- not
socket.sent = {}
conn:send(0, true, "reliable")
assert(#socket.sent == 1)
local rel = serialize.reader(socket.sent[1])
rel:skip(7)
assert(rel:u8() == 3, "connection: should be a reliable packet")
local seqnum = rel:u16()
assert(seqnum == connection.SEQNUM_INITIAL, "connection: wrong first seqnum")
socket.sent = {}
conn:update(0.1)
assert(#socket.sent == 0, "connection: resent too early")
conn:update(0.5)
assert(#socket.sent == 1, "connection: did not resend an unacknowledged packet")
socket.sent = {}
-- The server acknowledges it: no more resending
socket.incoming = {datagram(1, 0,
		serialize.writer():u8(0):u8(0):u16(seqnum):data())}
conn:update(0.6)
assert(#socket.sent == 0, "connection: resent an acknowledged packet")

-- The peer id the server hands out is used in what we send after that
socket.incoming = {datagram(1, 0,
		serialize.writer():u8(0):u8(1):u16(1234):data())}
conn:update(0.01)
assert(conn.peer_id == 1234, "connection: did not take the peer id")
socket.sent = {}
conn:send(0, false, "x")
assert(serialize.reader(socket.sent[1]):u32() and
		serialize.reader(socket.sent[1]:sub(5)):u16() == 1234,
		"connection: did not send with the peer id")

-- Reliable packets arriving out of order are handed on in order, and every
-- one of them is acknowledged
got = {}
socket.sent = {}
local first = connection.SEQNUM_INITIAL
socket.incoming = {
	datagram(1, 0, reliable(first + 1, original("second"))),
	datagram(1, 0, reliable(first, original("first"))),
	datagram(1, 0, reliable(first + 2, original("third"))),
}
conn:update(0.01)
assert(#got == 3, "connection: expected three payloads, got "..#got)
assert(got[1].data == "first" and got[2].data == "second" and
		got[3].data == "third", "connection: reliable packets out of order")
assert(#socket.sent == 3, "connection: did not acknowledge every packet")

-- A duplicate is acknowledged again but not handed on twice
got = {}
socket.sent = {}
socket.incoming = {datagram(1, 0, reliable(first, original("first")))}
conn:update(0.01)
assert(#got == 0, "connection: handed on a duplicate")
assert(#socket.sent == 1, "connection: did not acknowledge a duplicate")

-- Split packets are put back together, in whatever order the pieces arrive
got = {}
socket.incoming = {
	datagram(1, 1, split(5, 3, 2, "cde")),
	datagram(1, 1, split(5, 3, 0, "a")),
	datagram(1, 1, split(5, 3, 1, "b")),
}
conn:update(0.01)
assert(#got == 1 and got[1].data == "abcde",
		"connection: split packets did not come back together")
assert(got[1].channel == 1, "connection: wrong channel")

-- A payload too big for one datagram goes out as split chunks, each of them a
-- packet in its own right; REQUEST_MEDIA is what needs this
socket.sent = {}
local big = string.rep("m", 2000)
conn:send(2, true, big)
assert(#socket.sent > 1, "connection: did not split a big send")
local pieces = {}
local split_count, split_seqnum = nil, nil
for i, packet in ipairs(socket.sent) do
	assert(#packet <= 512, "connection: split chunk "..i.." is "..#packet..
			" bytes")
	local rd = serialize.reader(packet)
	rd:skip(7)
	assert(rd:u8() == 3, "connection: a split chunk should be reliable")
	rd:u16() -- Its own reliable seqnum
	assert(rd:u8() == 2, "connection: should be a split packet")
	local seqnum = rd:u16()
	local count = rd:u16()
	local num = rd:u16()
	split_seqnum = split_seqnum or seqnum
	split_count = split_count or count
	assert(seqnum == split_seqnum, "connection: split seqnum changed")
	assert(count == split_count, "connection: chunk count changed")
	assert(num == i - 1, "connection: chunks out of order")
	pieces[#pieces + 1] = rd:rest()
end
assert(split_count == #socket.sent, "connection: wrong chunk count")
assert(table.concat(pieces) == big, "connection: split lost data")

-- The next big send uses the next split seqnum
socket.sent = {}
conn:send(2, true, big)
local rd = serialize.reader(socket.sent[1])
rd:skip(7 + 3 + 1)
assert(rd:u16() == (split_seqnum + 1) % 65536,
		"connection: split seqnum did not advance")

-- A datagram from something else is ignored, not an error
got = {}
socket.incoming = {"garbage", datagram(1, 0, original("fine"))}
conn:update(0.01)
assert(#got == 1 and got[1].data == "fine",
		"connection: a bad datagram should not stop the good one")

-- The socket going away disconnects
local disconnect_reason = nil
conn.on_disconnect = function(reason)
	disconnect_reason = reason
end
socket.receive = function()
	return nil, "closed"
end
conn:update(0.01)
assert(disconnect_reason == "closed", "connection: did not notice the close")
assert(conn.connected == false)

print("connection: ok")
print("luanti_client/test.lua: ok")
