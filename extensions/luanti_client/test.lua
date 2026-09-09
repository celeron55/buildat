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

-- The engine's own; connection.lua times how long it spends handing
-- assembled payloads over
buildat = {
	get_time_us = function()
		return math.floor(os.clock() * 1000000)
	end,
}

local serialize = dofile(dir.."/serialize.lua")
local connection = dofile(dir.."/connection.lua")
local player = dofile(dir.."/player.lua")
local texmod = dofile(dir.."/texmod.lua")
local inventory = dofile(dir.."/inventory.lua")
local formspec = dofile(dir.."/formspec.lua")
local objects = dofile(dir.."/objects.lua")
local nodedef = dofile(dir.."/nodedef.lua")
local media = dofile(dir.."/media.lua")
local shapes = dofile(dir.."/shapes.lua")
local itemdef = dofile(dir.."/itemdef.lua")
local nodemeta = dofile(dir.."/nodemeta.lua")
local objmesh = dofile(dir.."/objmesh.lua")

local function dump_name(s)
	return "\""..s:gsub("[^%w%p ]", "?").."\""
end

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

-- Floats out and back, which is what the object messages and the movement
-- constants are made of
for _, v in ipairs({0, 1, -1, 0.5, 1.625, 10.4, 123456.75, -3.5}) do
	local got = serialize.reader(serialize.writer():f32(v):data()):f32()
	assert(math.abs(got - v) <= math.abs(v) * 1e-6,
			"serialize: f32 round trip of "..v.." gave "..got)
end

-- Wide strings, which is what chat is: a count of UTF-16 units and then
-- those, so what is not in the basic plane goes as a surrogate pair
for _, text in ipairs({"", "hello", "a\228\184\173b",
		"\195\164\195\182\195\165", "tree \240\159\140\178 here"}) do
	local packed = serialize.writer():wstring(text):data()
	local got = serialize.reader(packed):wstring()
	assert(got == text, "serialize: wstring round trip of "..#text..
			" bytes gave "..#got)
end
-- The count is units, not bytes or code points: one tree is two units
assert(serialize.reader(serialize.writer():wstring(
		"\240\159\140\178"):data()):u16() == 2,
		"serialize: a surrogate pair is two units")
assert(#serialize.utf16_units("ab") == 2, "serialize: utf16_units")
-- A byte that is not valid UTF-8 comes out as the replacement character
-- rather than stopping anything
local bad = serialize.reader(serialize.writer():wstring("a\255b"):data())
		:wstring()
assert(bad:sub(1, 1) == "a" and bad:sub(-1) == "b",
		"serialize: a bad byte took the rest with it")

-- base64, which is how a server older than protocol 48 announces the sha1 of
-- a media file. The vector is the hash of the empty string, as
-- base64_encode() writes it, padding left off the way Luanti leaves it off.
assert(serialize.base64_decode("2jmj7l5rSw0yVb/vlWAYkK/YBwk") ==
		"\218\057\163\238\094\107\075\013\050\085\191\239"..
		"\149\096\024\144\175\216\007\009",
		"serialize: base64_decode of a sha1")
assert(serialize.base64_decode("YQ==") == "a", "serialize: base64_decode padded")

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
-- One frame: what arrived is reassembled and then handed over, with a
-- budget big enough that everything waiting gets through
local function conn_update(dtime)
	conn:update(dtime)
	conn:pump(1000000000)
end

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
conn_update(0.1)
assert(#socket.sent == 0, "connection: resent too early")
conn_update(0.5)
assert(#socket.sent == 1, "connection: did not resend an unacknowledged packet")
socket.sent = {}
-- The server acknowledges it: no more resending
socket.incoming = {datagram(1, 0,
		serialize.writer():u8(0):u8(0):u16(seqnum):data())}
conn_update(0.6)
assert(#socket.sent == 0, "connection: resent an acknowledged packet")

-- The peer id the server hands out is used in what we send after that
socket.incoming = {datagram(1, 0,
		serialize.writer():u8(0):u8(1):u16(1234):data())}
conn_update(0.01)
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
conn_update(0.01)
assert(#got == 3, "connection: expected three payloads, got "..#got)
assert(got[1].data == "first" and got[2].data == "second" and
		got[3].data == "third", "connection: reliable packets out of order")
assert(#socket.sent == 3, "connection: did not acknowledge every packet")

-- A duplicate is acknowledged again but not handed on twice
got = {}
socket.sent = {}
socket.incoming = {datagram(1, 0, reliable(first, original("first")))}
conn_update(0.01)
assert(#got == 0, "connection: handed on a duplicate")
assert(#socket.sent == 1, "connection: did not acknowledge a duplicate")

-- Split packets are put back together, in whatever order the pieces arrive
got = {}
socket.incoming = {
	datagram(1, 1, split(5, 3, 2, "cde")),
	datagram(1, 1, split(5, 3, 0, "a")),
	datagram(1, 1, split(5, 3, 1, "b")),
}
conn_update(0.01)
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

-- What arrived is handed over on the caller's budget: a frame that has run
-- out of time leaves the rest waiting, and one always gets through
got = {}
socket.incoming = {datagram(1, 0, original("a")),
		datagram(1, 0, original("b")), datagram(1, 0, original("c"))}
conn:update(0.01)
assert(#got == 0, "connection: nothing is handed over before pump()")
local waiting = conn:pump(0)
assert(#got == 1 and waiting == 2,
		"connection: a spent budget still hands one over, got "..#got..
		" with "..waiting.." waiting")
assert(conn:pump(1000000000) == 0 and #got == 3,
		"connection: the rest waited for the next pump")

-- More arriving while some are still waiting goes behind them, in order:
-- what is waiting has left holes at the front of the queue
got = {}
socket.incoming = {datagram(1, 0, original("d")),
		datagram(1, 0, original("e"))}
conn:update(0.01)
conn:pump(0)
socket.incoming = {datagram(1, 0, original("f"))}
conn:update(0.01)
conn:pump(1000000000)
assert(#got == 3 and got[1].data == "d" and got[2].data == "e" and
		got[3].data == "f",
		"connection: a payload was lost or came out of order, got "..#got)

-- A datagram from something else is ignored, not an error
got = {}
socket.incoming = {"garbage", datagram(1, 0, original("fine"))}
conn_update(0.01)
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
conn_update(0.01)
assert(disconnect_reason == "closed", "connection: did not notice the close")
assert(conn.connected == false)

print("connection: ok")
-- nodedef.lua

-- A NODEDEF packet built the way the server builds one, and read back. This is
-- the whole point of the parser: finding the six tiles means reading through
-- everything in front of them, and a tile is variable-length.
local function write_tiledef(w, name, flags, animation)
	w:u8(6) -- TileDef version
	w:string(name)
	if animation == "vertical" then
		w:u8(1):u16(16):u16(16):raw(string.char(0x3f, 0x80, 0, 0)) -- 1.0 s
	elseif animation == "sheet" then
		w:u8(2):u8(2):u8(2):raw(string.char(0x3f, 0x80, 0, 0))
	else
		w:u8(0)
	end
	w:u16(flags)
	if flags % 16 >= 8 then -- has_color
		w:u8(255):u8(128):u8(0)
	end
	if flags % 32 >= 16 then -- has_scale
		w:u8(2)
	end
	if flags % 64 >= 32 then -- has_align_style
		w:u8(1)
	end
end

local function write_node(name, drawtype, tile_names, flags, animation, opts)
	opts = opts or {}
	local w = serialize.writer()
	w:u8(13) -- ContentFeatures version
	w:string(name)
	w:u16(2) -- Groups
	w:string("cracky"):s16(3)
	w:string("oddly_breakable_by_hand"):s16(-1)
	w:u8(0) -- param_type
	w:u8(0) -- param_type_2
	w:u8(drawtype)
	w:string("") -- mesh
	w:raw(string.char(0x3f, 0x80, 0, 0)) -- visual_scale 1.0
	w:u8(6)
	for i = 1, 6 do
		write_tiledef(w, tile_names[i], flags or 0, animation)
	end
	for _ = 1, 6 do
		write_tiledef(w, opts.overlay or "", 0)
	end
	w:u8(6) -- CF_SPECIAL_COUNT
	for _ = 1, 6 do
		write_tiledef(w, "", 0)
	end
	w:u8(255) -- alpha for legacy clients
	w:u8(255):u8(254):u8(253) -- color
	w:string(opts.palette or "")
	w:u8(0) -- waving
	w:u8(0) -- connect_sides
	w:u16(0) -- connects_to
	w:raw(string.rep("\0", 4)) -- post_effect_color
	w:u8(0) -- leveled
	w:u8(1) -- light_propagates
	w:u8(opts.sunlight_propagates and 1 or 0)
	w:u8(opts.light_source or 0)
	w:u8(1) -- is_ground_content
	w:u8(opts.walkable == false and 0 or 1)
	w:u8(1) -- pointable
	w:u8(1) -- diggable
	w:u8(opts.climbable and 1 or 0)
	w:u8(0) -- buildable_to
	w:u8(0) -- rightclickable
	w:u32(opts.damage_per_second or 0)
	w:u8(opts.liquid_type or 0)
	w:string(""):string("") -- liquid_alternative_flowing, _source
	w:u8(0) -- liquid_viscosity
	w:u8(0) -- liquid_renewable
	w:u8(0) -- liquid_range
	w:u8(opts.drowning or 0)
	w:u8(0) -- floodable
	-- Everything after this is skipped by the parser, which is what lets it
	-- read a newer ContentFeatures than it knows: node boxes, sounds, and the
	-- fields added after them
	w:raw(string.rep("\255", 40))
	return w:data()
end

local nodes = {
	{7, write_node("test:stone", 0, {"stone.png", "stone.png", "stone.png",
			"stone.png", "stone.png", "stone.png"}, 0)},
	{9, write_node("test:grass", 0, {"grass_top.png", "dirt.png",
			"dirt.png^shadow.png", "dirt.png^shadow.png",
			"dirt.png^shadow.png", "dirt.png^shadow.png"}, 8 + 16 + 32)},
	{11, write_node("test:water", 2, {"water.png", "water.png", "water.png",
			"water.png", "water.png", "water.png"}, 1, "vertical",
			{walkable = false, liquid_type = 2, drowning = 1,
			palette = "water_palette.png"})},
	{13, write_node("test:torch", 7, {"torch.png", "torch.png", "torch.png",
			"torch.png", "torch.png", "torch.png"}, 0, "sheet")},
}
local inner = serialize.writer()
for _, node in ipairs(nodes) do
	inner:u16(node[1]):string(node[2])
end
local nodedef_packet = serialize.writer():u8(1):u16(#nodes)
		:longstring(inner:data()):data()

local defs, count = nodedef.parse(serialize, nodedef_packet)
assert(count == #nodes, "nodedef: count is "..count)
assert(defs[7].name == "test:stone", "nodedef: name is "..
		tostring(defs[7] and defs[7].name))
assert(defs[7].drawtype == 0 and defs[9].drawtype == 0 and
		defs[11].drawtype == 2 and defs[13].drawtype == 7,
		"nodedef: wrong draw types")
assert(defs[7].groups.cracky == 3 and
		defs[7].groups.oddly_breakable_by_hand == -1, "nodedef: groups")
-- The flags on test:grass add a colour, a scale and an align style after the
-- name, and getting past those is what finds the next tile
assert(defs[9].tiles[1].name == "grass_top.png" and
		defs[9].tiles[6].name == "dirt.png^shadow.png",
		"nodedef: tiles after the optional tile fields")
assert(defs[11].tiles[1].animation.type == 1 and
		defs[11].tiles[1].animation.aspect_w == 16,
		"nodedef: a vertical-frames animation")
assert(defs[13].tiles[1].animation.type == 2, "nodedef: a sheet animation")
assert(defs[7].tiles[1].animation.type == 0, "nodedef: no animation")
assert(defs[13].tiles[3].name == "torch.png", "nodedef: tiles after a sheet")
-- The fields past the eighteen tiles: everything walking and digging need
assert(defs[7].walkable and defs[7].diggable and not defs[7].climbable,
		"nodedef: interaction fields of a solid node")
assert(defs[11].walkable == false and defs[11].liquid_type == 2 and
		defs[11].drowning == 1 and
		defs[11].palette_name == "water_palette.png",
		"nodedef: liquid fields")
assert(defs[7].color[1] == 255 and defs[7].color[3] == 253,
		"nodedef: colour")
-- test:grass has the flags that put a colour, a scale and an align style
-- after the tile's name; the colour is the tile's own
assert(defs[9].tiles[1].color and defs[9].tiles[1].color[1] == 255 and
		defs[9].tiles[1].color[2] == 128 and defs[9].tiles[1].color[3] == 0,
		"nodedef: a tile's own colour")
assert(defs[7].tiles[1].color == nil, "nodedef: a tile with no colour")
assert(defs[7].overlays[1].name == "" and #defs[7].special == 6,
		"nodedef: the overlay and special tiles")

-- A node whose definition cannot be read is left out, and the rest still parse
local broken = serialize.writer():u16(20):string(string.char(13, 0, 200))
		:data()
local mixed = serialize.writer():u8(1):u16(2):longstring(
		broken..serialize.writer():u16(7):string(nodes[1][2]):data()):data()
local defs2, count2 = nodedef.parse(serialize, mixed)
assert(count2 == 2 and defs2[20] == nil and defs2[7].name == "test:stone",
		"nodedef: one broken node should not stop the rest")

print("nodedef: ok")

-- media.lua

-- A name from the server becomes a file name, so what is not usable as one is
-- refused rather than trusted
for _, name in ipairs({"default_dirt.png", "mcl_core_stone.png", "a-b_c.png"}) do
	assert(media.is_safe_name(name), "media: refused "..name)
end
for _, name in ipairs({"", ".", "..", "../etc/passwd", "a/b.png", "a\\b.png",
		".hidden", "a b.png", "a;b.png", string.rep("a", 201)}) do
	assert(not media.is_safe_name(name), "media: accepted "..dump_name(name))
end
assert(media.server_key("127.0.0.1", 30000) == "127.0.0.1_30000")
assert(media.server_key("::1", 30000) == "__1_30000")
-- Dots survive, slashes do not, and the port on the end means the name can
-- never come out as "." or ".."
assert(media.server_key("a/../b", 1) == "a_.._b_1")
assert(media.server_key("..", 1) == ".._1")

-- plan() with no set of wanted names asks for every announced file that the
-- cache does not have, which is what the client does with an announcement:
-- working out which files a game reaches costs more than the bytes do
do
	local dir = os.getenv("TMPDIR") or "/tmp"
	dir = dir.."/luanti_client_media_test"
	__buildat_mkdir = function() end
	buildat.sha1 = function(data) return "sha1:"..data end
	local store = media.new(buildat, {warning = function() end}, dir)
	local announced = {
		{name = "a.png", sha1 = "sha1:a"},
		{name = "b.png", sha1 = "sha1:b"},
		{name = "../evil", sha1 = "sha1:e"},
	}
	local ask = store:plan(announced)
	table.sort(ask)
	assert(#ask == 2 and ask[1] == "a.png" and ask[2] == "b.png",
			"media: plan() with no set asks for every safe announced name")
	-- What is already on the way is not asked for a second time
	assert(#store:plan(announced) == 0, "media: plan() asks once")
	assert(store:missing_count() == 2, "media: what was asked for is missing")
end

print("media: ok")

--
-- player.lua: the box against the nodes
--

-- A world made of a function: the bottom of everything at y <= -3, ground at
-- y <= 0, a wall two nodes tall at x = 3, a one-node plateau at x <= -3, and
-- a hole at (0, 6) with water in it.
local function is_solid(x, y, z)
	if y <= -3 then
		return true
	end
	if x <= -3 and y == 1 then
		return true
	end
	if x == 3 and (y == 1 or y == 2) then
		return true
	end
	if y <= 0 then
		return not (x == 0 and z == 6)
	end
	return false
end

local function is_liquid(x, y, z)
	return x == 0 and z == 6 and y <= 0 and y >= -2
end

local NO_WISH = {x = 0, z = 0}

local function settle(p, n, wish)
	for _ = 1, n do
		p:update(1 / 60, wish or NO_WISH)
	end
end

-- Standing on the ground: the box's bottom ends up on the top face of the
-- node at y = 0, which is y = 0.5
local p = player.new(is_solid)
p:set_position(0, 4, 0)
settle(p, 200)
assert(math.abs(p.y - 0.5) < 1e-6, "player: fell to "..p.y)
assert(p.on_ground, "player: does not know it is on the ground")

-- Walking into the wall stops a radius short of its face
p:set_position(0, 0.5, 0)
settle(p, 200, {x = 1, z = 0})
assert(math.abs(p.x - (2.5 - player.RADIUS)) < 1e-6,
		"player: walked to x = "..p.x)
assert(p.vx == 0, "player: still has speed into the wall")

-- Walking at the wall at an angle slides along it rather than stopping
p:set_position(0, 0.5, 0)
settle(p, 200, {x = 1, z = 1})
assert(math.abs(p.x - (2.5 - player.RADIUS)) < 1e-6 and p.z > 5,
		"player: did not slide along the wall, at "..p.x..", "..p.z)

-- A node in the way has to be jumped over: nothing steps up on its own,
-- which is what Luanti does too
p:set_position(-1, 0.5, 0)
settle(p, 120, {x = -1, z = 0})
assert(math.abs(p.x - (-2.5 + player.RADIUS)) < 1e-6,
		"player: walked up the plateau to x = "..p.x)
settle(p, 300, {x = -1, z = 0, jump = true})
settle(p, 120)
assert(p.x < -3.5, "player: did not get onto the plateau, x = "..p.x)
assert(math.abs(p.y - 1.5) < 1e-6, "player: is at y = "..p.y..", not on it")

-- Jumping leaves the ground and comes back to it
p:set_position(0, 0.5, 0)
p:update(1 / 60, NO_WISH)
p:update(1 / 60, {x = 0, z = 0, jump = true})
assert(p.y > 0.5 and not p.on_ground, "player: did not jump")
local top = p.y
for _ = 1, 200 do
	p:update(1 / 60, NO_WISH)
	if p.y > top then top = p.y end
end
assert(top > 1.5 and top < 3, "player: jumped to "..top)
assert(math.abs(p.y - 0.5) < 1e-6, "player: landed at "..p.y)

-- Falling into the hole lands in the water and stops sinking at its bottom,
-- and the jump key swims back out of it
local w = player.new(is_solid, is_liquid)
w:set_position(0, 0.5, 6)
settle(w, 300)
assert(w.in_liquid, "player: not in the water")
assert(math.abs(w.y - (-2.5)) < 1e-6, "player: sank to "..w.y)
settle(w, 300, {x = 0, z = 0, jump = true})
assert(w.y > 0.5, "player: did not swim out, y = "..w.y)

-- Flying ignores gravity, goes down on the sneak key, and still stops at the
-- ground
local f = player.new(is_solid)
f.fly = true
f:set_position(0, 10, 0)
settle(f, 60)
assert(math.abs(f.y - 10) < 1e-6, "player: flying fell to "..f.y)
settle(f, 300, {x = 0, z = 0, sneak = true, fast = true})
assert(math.abs(f.y - 0.5) < 1e-6, "player: flew down to "..f.y)

-- Going through walls takes the player out of anything they are inside, and
-- gravity does not apply while it is on
local n = player.new(is_solid)
n:set_position(3, 0.5, 0)
n.noclip = true
settle(n, 120)
assert(math.abs(n.y - 0.5) < 1e-6, "player: fell while noclipping to "..n.y)
settle(n, 120, {x = 0, z = 0, jump = true})
assert(n.y > 5, "player: did not rise through the wall, y = "..n.y)

-- A player the server put inside a node can walk out of it rather than being
-- held there by it
local i = player.new(is_solid)
i:set_position(3, 0.5, 0)
settle(i, 120, {x = -1, z = 0})
assert(i.x < 2, "player: stuck inside the wall at x = "..i.x)

-- A voxel made of boxes rather than a whole cube: a slab at x = 6 whose top
-- is half a voxel up, and a stair-shaped pair of boxes at x = 8. Walking into
-- either steps onto it; the wall at x = 3 is still a wall.
local SLAB = {{-0.5, -0.5, -0.5, 0.5, 0.0, 0.5}}
local STAIR = {
	{-0.5, -0.5, -0.5, 0.5, 0.0, 0.5},
	{-0.5, 0.0, 0.0, 0.5, 0.5, 0.5},
}
local function is_solid_boxed(x, y, z)
	if x >= 6 and y == 1 then
		return SLAB
	end
	return is_solid(x, y, z)
end

-- The same, with the stair-shaped one from z = 6 instead: its lower half
-- faces -Z, so walking that way is walking up it
local function is_solid_stair(x, y, z)
	if z >= 6 and y == 1 then
		return STAIR
	end
	return is_solid(x, y, z)
end

-- Standing on the slab: its top is at y = 1 - 0.5 + 0.5 = 1.0
local b = player.new(is_solid_boxed)
b:set_position(6, 4, 0)
settle(b, 240)
assert(math.abs(b.y - 1.0) < 1e-6, "player: stands on the slab at "..b.y)

-- Walking into the slab steps onto it rather than stopping at it
local w2 = player.new(is_solid_boxed)
w2:set_position(4.0, 0.5, 0)
settle(w2, 240, {x = 1, z = 0})
assert(w2.x > 6, "player: did not step onto the slab, x = "..w2.x)
assert(math.abs(w2.y - 1.0) < 1e-6, "player: stepped up to "..w2.y)

-- The lower half of the stair is the same step up; the box on its back half
-- is what the player then stands on
-- Up the stair: its lower half is one step and its upper half another, and
-- both are inside the step height, so a walk goes up it without a jump
local w3 = player.new(is_solid_stair)
w3:set_position(0.2, 0.5, 4.0)
settle(w3, 240, {x = 0, z = 1})
assert(w3.z > 6, "player: did not walk up the stair, z = "..w3.z)
assert(math.abs(w3.y - 1.5) < 1e-6,
		"player: the stair's top is 1.5, stood at "..w3.y)

-- Two nodes of wall are still two nodes of wall
local w4 = player.new(is_solid_boxed)
w4:set_position(1.0, 0.5, 0)
settle(w4, 240, {x = 1, z = 0})
assert(w4.x < 2.8, "player: climbed the wall to x = "..w4.x)

print("player: ok")

--
-- texmod.lua: Luanti's texture modifier language
--

assert(texmod.parse_color("#f80")[1] == 255 and
		texmod.parse_color("#f80")[2] == 136 and
		texmod.parse_color("#f80")[3] == 0, "texmod: #rgb")
assert(texmod.parse_color("#ff8000")[2] == 128, "texmod: #rrggbb")
assert(texmod.parse_color("#ff800040")[4] == 64, "texmod: #rrggbbaa")
assert(texmod.parse_color("#f804")[4] == 68, "texmod: #rgba")
assert(texmod.parse_color("yellow")[1] == 255 and
		texmod.parse_color("yellow")[3] == 0, "texmod: a named colour")
assert(texmod.parse_color("Red")[1] == 255, "texmod: names are lowercased")
assert(texmod.parse_color("chartreuse") == nil, "texmod: unknown name")
assert(texmod.parse_color("#ff") == nil, "texmod: five nibbles")

-- The eight symmetries, including several written in a row, which multiply
assert(texmod.parse_transform("R90") == 1, "texmod: R90")
assert(texmod.parse_transform("r270") == 3, "texmod: r270")
assert(texmod.parse_transform("FX") == 4, "texmod: FX")
assert(texmod.parse_transform("FY") == 6, "texmod: FY")
assert(texmod.parse_transform("46") == 2, "texmod: a flip and a flip")
assert(texmod.parse_transform("") == 0, "texmod: nothing")

-- A "^" inside parentheses is not where the chain splits
local parts = texmod.parse("(a.png^b.png)^[colorize:red:128^c.png")
assert(#parts == 3, "texmod: "..#parts.." parts")
assert(parts[1].kind == "group" and parts[1].expr == "a.png^b.png",
		"texmod: the group")
assert(parts[2].kind == "mod" and parts[2].name == "colorize" and
		parts[2].args[1] == "red" and parts[2].args[2] == "128",
		"texmod: the modifier and its arguments")
assert(parts[3].kind == "file" and parts[3].name == "c.png",
		"texmod: the file after it")
assert(texmod.parse("(a.png") == nil, "texmod: unbalanced parentheses")

-- Every file name an expression reaches, including through the arguments of
-- [combine and [mask
local names = {}
assert(texmod.sources(
		"[combine:32x16:0,0=a.png:16,0=(b.png^[mask:m.png)", names),
		"texmod: sources failed")
assert(names["a.png"] and names["b.png"] and names["m.png"],
		"texmod: sources missed one")
local n2 = {}
texmod.sources("c.png^[opacity:128", n2)
assert(n2["c.png"] and n2["[opacity:128"] == nil, "texmod: sources of a chain")

-- What an expression builds. The resolve() context is what a caller supplies:
-- media names in, resource names out, and one composition per expression.
local composed = {}
local ctx = {
	resource = function(name)
		if name == "missing.png" then
			return nil
		end
		return "srv/"..name
	end,
	compose = function(expr, ops, size)
		composed[#composed + 1] = {expr = expr, ops = ops, size = size}
		return "srv/composed/"..#composed
	end,
}

-- A plain name is not composed at all
assert(texmod.resolve("a.png", ctx) == "srv/a.png", "texmod: a plain name")
assert(#composed == 0, "texmod: composed a plain name")

-- An overlay chain: the first image is the canvas, the rest are stretched
-- over it
assert(texmod.resolve("a.png^b.png", ctx) == "srv/composed/1",
		"texmod: an overlay")
local ops = composed[1].ops
assert(#ops == 2 and ops[1].op == "blit" and ops[1].src == "srv/a.png" and
		not ops[1].fill and ops[2].fill, "texmod: overlay ops")

-- The modifiers this game's nodes use
local function ops_of(expr)
	composed = {}
	assert(texmod.resolve(expr, ctx), "texmod: could not build "..expr)
	return composed[#composed].ops, composed[#composed].size
end

local o = ops_of("a.png^[multiply:yellow")
assert(o[2].op == "multiply" and o[2].color[1] == 255 and
		o[2].color[3] == 0 and o[2].color[4] == 255,
		"texmod: multiply keeps the alpha")
o = ops_of("a.png^[opacity:128")
assert(o[2].op == "multiply" and o[2].color[4] == 128 and
		o[2].color[1] == 255, "texmod: opacity is an alpha multiply")
o = ops_of("a.png^[colorize:#ff000080")
assert(o[2].op == "colorize" and o[2].ratio == 128,
		"texmod: colorize with no ratio uses the colour's alpha")
o = ops_of("a.png^[colorize:red:200")
assert(o[2].ratio == 200, "texmod: colorize with a ratio")
o = ops_of("a.png^[hsl:120:-50")
assert(o[2].op == "hsl" and o[2].hue == 120 and o[2].saturation == -50 and
		o[2].lightness == 0, "texmod: hsl")
o = ops_of("a.png^[noalpha")
assert(o[2].op == "alpha" and o[2].value == 255, "texmod: noalpha")
o = ops_of("a.png^[brighten")
assert(o[2].op == "colorize" and o[2].ratio == 128, "texmod: brighten")
o = ops_of("a.png^[transformFX")
assert(o[2].op == "transform" and o[2].transform == 4, "texmod: transform")
o = ops_of("a.png^[resize:32x32")
assert(o[2].op == "resize" and o[2].size[1] == 32, "texmod: resize")
o = ops_of("a.png^[verticalframe:4:2")
assert(o[2].op == "crop" and o[2].grid[2] == 4 and o[2].cell[2] == 2,
		"texmod: verticalframe is one cell of a stack")
o = ops_of("a.png^[verticalframe:4:9")
assert(o[2].cell[2] == 3, "texmod: a frame past the end is the last one")
o = ops_of("a.png^[mask:m.png")
assert(o[2].op == "blit" and o[2].blend == "and" and o[2].fill,
		"texmod: mask")

-- [combine says the canvas size and places its pieces
local size
o, size = ops_of("[combine:32x16:0,0=a.png:16,0=b.png")
assert(size[1] == 32 and size[2] == 16, "texmod: combine size")
assert(#o == 2 and o[1].at[1] == 0 and o[2].at[1] == 16,
		"texmod: combine places")

-- A nested expression is composed on its own and referred to by name
composed = {}
assert(texmod.resolve("(a.png^[transformR90)^[multiply:red", ctx),
		"texmod: nested")
assert(#composed == 2, "texmod: "..#composed.." compositions for a nest")
assert(composed[1].expr == "a.png^[transformR90", "texmod: the inner one")
assert(composed[2].ops[1].src == "srv/composed/1",
		"texmod: the outer one refers to the inner")

-- A missing file, and a modifier that is not implemented, make the whole
-- expression unusable rather than half a texture
assert(texmod.resolve("missing.png^[noalpha", ctx) == nil,
		"texmod: built on a missing file")
assert(texmod.resolve("a.png^[invert:rgb", ctx) == nil,
		"texmod: built an unimplemented modifier")
assert(texmod.resolve("a.png^[colorize:chartreuse", ctx) == nil,
		"texmod: built an unknown colour")

-- A modifier build() does not implement leaves the expression unusable, and
-- says so once with an example: a node whose texture cannot be built is drawn
-- as a placeholder and nothing else explains why
assert(texmod.resolve("a.png^[invert:rgb", ctx) == nil,
		"texmod: an unimplemented modifier does not build")
assert(texmod.unimplemented["invert"] == "a.png^[invert:rgb",
		"texmod: an unimplemented modifier is recorded with an example")

print("texmod: ok")

--
-- inventory.lua: what the player is carrying
--

local inv_data = table.concat({
	"List main 5",
	"Width 5",
	"Item mcl_core:dirt 42",
	"Empty",
	'Item "a b:c" 3 7',
	"Item mcl_tools:pick_iron 1 0 \"metadata\"",
	"Item mcl_core:stone",
	"EndInventoryList",
	"List hand 1",
	"Width 0",
	"Item mcl_meshhand:hand",
	"EndInventoryList",
	"EndInventory",
	"",
}, "\n")

local lists = inventory.parse(inv_data)
assert(lists.main and lists.main.width == 5 and lists.main.size == 5,
		"inventory: main width and size")
assert(#lists.main.items == 5, "inventory: "..#lists.main.items.." slots")
assert(lists.main.items[1].name == "mcl_core:dirt" and
		lists.main.items[1].count == 42 and lists.main.items[1].wear == 0,
		"inventory: the first stack")
assert(lists.main.items[2] == nil, "inventory: an empty slot is a hole")
-- A name with a space in it is written as a JSON string, and the count and
-- the wear follow it
assert(lists.main.items[3].name == "a b:c" and
		lists.main.items[3].count == 3 and lists.main.items[3].wear == 7,
		"inventory: a quoted name")
assert(lists.main.items[4].name == "mcl_tools:pick_iron" and
		lists.main.items[4].count == 1, "inventory: an item with metadata")
-- A stack of one is written as the name alone
assert(lists.main.items[5].name == "mcl_core:stone" and
		lists.main.items[5].count == 1, "inventory: a bare name")
assert(lists.hand.items[1].name == "mcl_meshhand:hand", "inventory: the hand")

-- A game may leave the width at zero, and the size is still what the list
-- says; this is what the player inventory of the test server looks like
local no_width = inventory.parse(
		"List main 3\nWidth 0\nEmpty\nEmpty\nEmpty\nEndInventoryList\n"..
		"EndInventory\n")
assert(no_width.main.size == 3 and no_width.main.width == 0 and
		next(no_width.main.items) == nil, "inventory: an empty main list")

-- KeepList means the list the client already had
local kept = inventory.parse("List main 1\nWidth 1\nItem a:b\n"..
		"EndInventoryList\nKeepList hand\nEndInventory\n", lists)
assert(kept.main.items[1].name == "a:b", "inventory: the replaced list")
assert(kept.hand == lists.hand, "inventory: KeepList kept the old one")
-- Without a previous inventory there is nothing to keep, and the list is
-- simply not there
local nothing = inventory.parse("KeepList hand\nEndInventory\n")
assert(nothing.hand == nil, "inventory: KeepList with nothing to keep")

-- Which tool capabilities a dig goes by
local items = {
	[""] = {tool_capabilities = {groupcaps = {}, name = "empty"}},
	["mcl_meshhand:hand"] = {tool_capabilities = {groupcaps = {},
			name = "hand"}},
	["mcl_tools:pick_iron"] = {tool_capabilities = {groupcaps = {},
			name = "pick"}},
	["mcl_core:dirt"] = {},
}
local caps = inventory.dig_capabilities(lists, 4, items)
assert(caps.name == "pick", "inventory: the wielded tool's own capabilities")
-- A stack of something that is not a tool falls through to the hand slot
caps = inventory.dig_capabilities(lists, 1, items)
assert(caps.name == "hand", "inventory: the hand slot's capabilities")
-- An empty slot with no hand list falls through to the empty item
caps = inventory.dig_capabilities({main = {items = {}}}, 1, items)
assert(caps.name == "empty", "inventory: the empty item's capabilities")

print("inventory: ok")

--
-- formspec.lua: the windows the server describes
--

-- The inventory form this game's server actually sends
local elements, size, real = formspec.parse(
		"size[8,7.5]list[current_player;main;0,3.5;8,4;]"..
		"list[current_player;craft;3,0;3,3;]listring[]"..
		"list[current_player;craftpreview;7,1;1,1;]")
assert(size[1] == 8 and size[2] == 7.5, "formspec: size")
assert(real == false, "formspec: no formspec_version means the old units")
assert(#elements == 4, "formspec: "..#elements.." elements")
assert(elements[1].name == "list" and
		elements[1].fields[1] == "current_player" and
		elements[1].fields[2] == "main" and
		elements[1].fields[3] == "0,3.5" and
		elements[1].fields[4] == "8,4" and elements[1].fields[5] == "",
		"formspec: the list element")
assert(elements[3].name == "listring" and elements[3].fields[1] == "",
		"formspec: an element with nothing in it")

-- A container shifts what is inside it, and formspec_version 2 and up means
-- the units are inventory slots rather than slots plus their spacing
local e2, s2, r2 = formspec.parse("formspec_version[6]size[13,11.43]"..
		"container[0,1.34]image[0.325,7.325;1.1,1.1;a.png]"..
		"container[1,1]label[0,0;in two]container_end[]container_end[]"..
		"label[1,2;out]")
assert(r2 == true, "formspec: formspec_version 6 means real coordinates")
assert(s2[1] == 13, "formspec: size again")
assert(#e2 == 3, "formspec: "..#e2.." elements past the containers")
assert(e2[1].at[1] == 0 and e2[1].at[2] == 1.34, "formspec: one container")
assert(e2[2].at[1] == 1 and e2[2].at[2] == 2.34,
		"formspec: containers add up")
assert(e2[3].at[1] == 0 and e2[3].at[2] == 0,
		"formspec: container_end goes back")

-- A backslash escapes what would otherwise end a field or the element
local e3 = formspec.parse("label[0,0;a\\;b\\]c]button[1,1;2,2;n;l]")
assert(#e3 == 2, "formspec: "..#e3.." escaped elements")
assert(e3[1].fields[2] == "a;b]c",
		"formspec: an escaped field is \""..tostring(e3[1].fields[2]).."\"")
assert(e3[2].name == "button", "formspec: the element after an escape")

-- Luanti's translation and colour markup is not text to show
assert(formspec.strip_escapes("\27(T@mcl_inventory)Search Items\27E") ==
		"Search Items", "formspec: escapes stripped")

-- The layout arithmetic, against Luanti's own: with real coordinates a slot
-- is one unit, and the form is as big as its size says
local l = formspec.layout({10, 10}, true, 1000, 1000)
assert(l.imgsize == 1000 / 15, "formspec: imgsize is capped per slot")
assert(l.slot == l.imgsize and l.slot_step == l.imgsize * 1.25,
		"formspec: a real-coordinate slot and its step")
assert(l.origin[1] == 0, "formspec: real coordinates have no padding")
-- A form too big for the screen is shrunk to fit it
local big = formspec.layout({40, 10}, true, 1000, 1000)
assert(math.abs(big.width - 900) < 1e-6,
		"formspec: a wide form is "..big.width.." across")
-- The old units are a slot plus its spacing, and a position has padding added
local old_units = formspec.layout({10, 10}, false, 1000, 1000)
assert(old_units.slot_step == old_units.imgsize * 1.25,
		"formspec: the old spacing")
assert(old_units.origin[1] == old_units.imgsize * 3 / 8,
		"formspec: the old padding")

print("formspec: ok")

--
-- objects.lua: the things in the world that are not nodes
--

-- What the server sends for an object that just arrived: its name and where
-- it is, then the messages that say what it looks like
local function write_properties()
	local w = serialize.writer()
	w:u8(4) -- ObjectProperties version
	w:u16(20) -- hp_max
	w:u8(1) -- physical
	w:u32(0) -- the weight that used to be here
	w:v3f(-0.4, 0, -0.4):v3f(0.4, 1.8, 0.4) -- collision box
	w:v3f(-0.4, 0, -0.4):v3f(0.4, 1.8, 0.4) -- selection box
	w:u8(1) -- pointable
	w:string("mesh")
	w:v3f(1, 1, 1) -- visual_size
	w:u16(2):string("cow.png"):string("cow_extra.png")
	w:s16(1):s16(1) -- spritediv
	w:s16(0):s16(0) -- initial_sprite_basepos
	w:u8(1) -- is_visible
	w:u8(1) -- makes_footstep_sound
	w:f32(0) -- automatic_rotate
	w:string("cow.b3d")
	w:u16(0) -- colors
	w:u8(1) -- collide_with_objects
	w:f32(0.6) -- stepheight
	w:u8(0) -- automatic_face_movement_dir
	w:f32(0) -- automatic_face_movement_dir_offset
	w:u8(1) -- backface_culling
	w:string("Bella")
	w:u32(0xffffffff) -- nametag_color
	w:f32(0) -- automatic_face_movement_max_rotation_per_sec
	w:string("a cow")
	w:string("") -- wield_item
	w:u8(0) -- glow
	w:u16(10) -- breath_max
	w:f32(1.5) -- eye_height
	w:f32(1.72) -- zoom_fov
	w:u8(1) -- use_texture_alpha
	return serialize.writer():u8(objects.CMD_SET_PROPERTIES)
			:raw(w:data()):data()
end

local init = serialize.writer()
init:u8(1) -- init data version
init:string("mobs_mc:cow")
init:u8(0) -- is_player
init:u16(42)
init:v3f(-3200, 180, 250) -- position, in BS units
init:v3f(0, 90, 0) -- rotation
init:u16(20) -- hp
init:u8(1) -- one message follows
init:longstring(write_properties())

local obj = objects.parse_init(serialize, init:data())
assert(obj.name == "mobs_mc:cow" and obj.is_player == false and obj.id == 42,
		"objects: the object's own fields")
-- Positions arrive in BS units and come out in nodes
assert(math.abs(obj.position[1] - -320) < 1e-3 and
		math.abs(obj.position[2] - 18) < 1e-3 and
		math.abs(obj.position[3] - 25) < 1e-3,
		"objects: position "..obj.position[1]..","..obj.position[2])
assert(math.abs(obj.yaw - 90) < 1e-3, "objects: yaw is "..obj.yaw)
assert(obj.hp == 20, "objects: hp")
assert(obj.props, "objects: the properties message was not applied")
assert(obj.props.visual == "mesh" and obj.props.mesh == "cow.b3d",
		"objects: visual and mesh")
assert(#obj.props.textures == 2 and obj.props.textures[1] == "cow.png",
		"objects: textures")
assert(obj.props.nametag == "Bella" and obj.props.infotext == "a cow",
		"objects: the strings past the boxes")
assert(math.abs(obj.props.collision_max[2] - 1.8) < 1e-6,
		"objects: the collision box, which is in nodes")
assert(math.abs(obj.props.eye_height - 1.5) < 1e-6, "objects: eye height")

-- Where it is now, which is what most of the messages are
local move = serialize.writer()
move:u8(objects.CMD_UPDATE_POSITION)
move:v3f(-3190, 180, 250) -- position
move:v3f(0, 0, 0) -- velocity
move:v3f(0, 0, 0) -- acceleration
move:v3f(0, 45, 0) -- rotation
move:u8(1) -- interpolate
move:u8(0) -- is_end_position
move:f32(0.1) -- how long until the next one
objects.apply_message(obj, serialize.reader(move:data()))
assert(math.abs(obj.target[1] - -319) < 1e-3, "objects: the new position")
assert(math.abs(obj.yaw - 45) < 1e-3, "objects: the new yaw")
-- Interpolation walks it there rather than jumping
assert(math.abs(obj.position[1] - -320) < 1e-3,
		"objects: it jumped instead of walking")
objects.interpolate({obj}, 0.05)
assert(obj.position[1] > -320 and obj.position[1] < -319.4,
		"objects: half way is "..obj.position[1])
objects.interpolate({obj}, 1.0)
assert(math.abs(obj.position[1] - -319) < 1e-3,
		"objects: it did not arrive, at "..obj.position[1])

-- A message this does not implement leaves the object alone
local unknown = serialize.writer():u8(objects.CMD_SET_ANIMATION)
		:raw(string.rep("\0", 20)):data()
objects.apply_message(obj, serialize.reader(unknown))
assert(obj.props.visual == "mesh", "objects: an unknown message broke it")

print("objects: ok")

-- A formspec written out as lines has whitespace between its elements, which
-- is not part of the name of either of them
local wsel, wssize = formspec.parse("size[3,4]\n	label[0,0;hi]\n"..
		"	button[0,1;2,1;go;Go]\n")
assert(wssize[1] == 3, "formspec: size after a newline")
assert(#wsel == 2 and wsel[1].name == "label" and wsel[2].name == "button",
		"formspec: element names are trimmed, got \""..wsel[1].name.."\"")

-- itemdef.lua
--
-- An item under two names: its own, and one the game renamed it away from

local function item_wrapper(name, image, protocol)
	local w = serialize.writer()
	w:u8(6):u8(itemdef.TYPE_CRAFT):string(name):string("A thing")
	-- An image carries an animation from protocol 51 on, and is a bare name
	-- before that
	w:string(image)
	if protocol >= 51 then
		w:u8(0)
	end
	w:string("")
	if protocol >= 51 then
		w:u8(0)
	end
	w:raw(string.rep("\0", 12)) -- wield_scale
	w:s16(99):u8(0):u8(0) -- stack_max, usable, liquids_pointable
	w:string("") -- no tool capabilities
	w:u16(0) -- no groups
	w:string("") -- node_placement_prediction
	for _ = 1, 2 do
		w:string(""):raw(string.rep("\0", 12)) -- a sound
	end
	w:f32(-1) -- range
	return w:data()
end

local function item_payload(protocol)
	local idw = serialize.writer()
	idw:u8(0):u16(1):string(item_wrapper("mcl_core:axe", "axe.png", protocol))
	idw:u16(1):string("default:axe"):string("mcl_core:axe")
	return idw:data()
end

local item_defs, item_count, item_aliases =
		itemdef.parse(serialize, item_payload(52), log, 52)
assert(item_count == 1, "itemdef: one item")
assert(item_defs["mcl_core:axe"], "itemdef: the item itself")
assert(item_defs["mcl_core:axe"].inventory_image == "axe.png",
		"itemdef: the inventory image")
assert(item_defs["default:axe"] == item_defs["mcl_core:axe"],
		"itemdef: an alias is the item it means")
assert(item_aliases["default:axe"] == "mcl_core:axe", "itemdef: the alias")

-- The same item as a server older than protocol 51 writes it
local old_defs = itemdef.parse(serialize, item_payload(47), log, 47)
assert(old_defs["mcl_core:axe"].inventory_image == "axe.png",
		"itemdef: an image with no animation after it")

print("itemdef: ok")

-- nodemeta.lua
--
-- What hangs off a voxel: the fields and the inventory, with the inventory's
-- text ending the entry rather than a length saying where it stops

local mw = serialize.writer()
mw:u8(2):u16(1) -- version, one entry
mw:u16(5 + 2 * 16 + 3 * 256) -- the index of (5, 2, 3) in a block
mw:u32(2) -- two fields
mw:string("formspec"):longstring("size[8,9]"):u8(0)
mw:string("infotext"):longstring("Chest"):u8(0)
mw:raw("List main 3\nItem mcl_core:dirt 5\nEmpty\nItem mcl_core:stone\n"..
		"EndInventoryList\nEndInventory\n")
local metas = nodemeta.parse(serialize.reader(mw:data()), inventory, false)
local entry = metas[5 + 2 * 16 + 3 * 256]
assert(entry, "nodemeta: the entry is at the block index")
assert(entry.fields.formspec == "size[8,9]", "nodemeta: a field")
assert(entry.fields.infotext == "Chest", "nodemeta: the second field")
assert(entry.lists.main.size == 3, "nodemeta: the list's size")
assert(entry.lists.main.items[1].count == 5, "nodemeta: the first stack")
assert(entry.lists.main.items[2] == nil, "nodemeta: the empty slot")
assert(entry.lists.main.items[3].name == "mcl_core:stone",
		"nodemeta: the stack after the empty one")

-- Nothing at all is a version of zero, and no count follows it
assert(next(nodemeta.parse(serialize.reader("\0"), inventory, false)) == nil,
		"nodemeta: an empty list")

-- The same list with absolute positions, which is how a change arrives
local aw = serialize.writer()
aw:u8(2):u16(1):s16(-3):s16(9):s16(-40):u32(0)
aw:raw("EndInventory\n")
local abs = nodemeta.parse(serialize.reader(aw:data()), inventory, true)
assert(abs["-3,9,-40"], "nodemeta: an absolute position is its own key")

print("nodemeta: ok")

-- shapes.lua
--
-- The two ways a facedir is followed have to agree: a cube's tiles are moved
-- to other faces by FACEDIR_TILES, and a shape's quads are turned by
-- turn_quads. Turning the six quads of a full cube must therefore land the
-- tile FACEDIR_TILES names on each face.

-- Which of our faces a quad points at, from the normal its winding gives
local function quad_face(q)
	local p = q.p
	local function edge(a, b)
		return {p[b * 3 + 1] - p[a * 3 + 1], p[b * 3 + 2] - p[a * 3 + 2],
				p[b * 3 + 3] - p[a * 3 + 3]}
	end
	local e1, e2 = edge(0, 1), edge(1, 2)
	local n = {e1[2] * e2[3] - e1[3] * e2[2], e1[3] * e2[1] - e1[1] * e2[3],
			e1[1] * e2[2] - e1[2] * e2[1]}
	for i, d in ipairs({{0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0},
			{0, 0, 1}, {0, 0, -1}}) do
		local dot = n[1] * d[1] + n[2] * d[2] + n[3] * d[3]
		local len = math.sqrt(n[1] ^ 2 + n[2] ^ 2 + n[3] ^ 2)
		if len > 1e-9 and dot / len > 0.99 then
			return i
		end
	end
	return nil
end

local cube = shapes.box_quads({-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}, {})
assert(#cube == 6, "shapes: a box is six quads")
for i, q in ipairs(cube) do
	assert(quad_face(q) == i, "shapes: box quad "..i.." faces "..
			tostring(quad_face(q)))
end
for facedir = 0, 23 do
	local turned = shapes.turn_quads(cube, facedir)
	local seen = {}
	for _, q in ipairs(turned) do
		local face = quad_face(q)
		assert(face, "shapes: facedir "..facedir.." left a quad degenerate")
		assert(not seen[face], "shapes: facedir "..facedir..
				" put two quads on face "..face)
		seen[face] = true
		local want = shapes.FACEDIR_TILES[facedir + 1][face]
		assert(q.tile == want, "shapes: facedir "..facedir..", face "..face..
				" wears tile "..q.tile..", FACEDIR_TILES says "..want)
		-- A turn stays inside the voxel's own cube
		for c = 0, 3 do
			for a = 1, 3 do
				assert(math.abs(q.p[c * 3 + a]) < 0.5 + 1e-9,
						"shapes: facedir "..facedir.." moved a corner out")
			end
		end
	end
end

-- The texture turned inside each face, which is the other half of Luanti's
-- table. A facedir under 4 is a turn about +Y: the top's texture turns with
-- the voxel and the bottom's turns the other way, because it is seen from
-- below. Every face of an upside-down voxel (facedir 20) is turned half way.
for facedir = 0, 23 do
	local turns = shapes.FACEDIR_TILE_TURNS[facedir + 1]
	assert(turns and #turns == 6,
			"shapes: facedir "..facedir.." has no six turns")
	for face = 1, 6 do
		assert(turns[face] >= 0 and turns[face] <= 3,
				"shapes: facedir "..facedir..", face "..face..
				" turns "..turns[face])
	end
end
for facedir = 0, 3 do
	local turns = shapes.FACEDIR_TILE_TURNS[facedir + 1]
	assert(turns[1] == (4 - facedir) % 4, "shapes: facedir "..facedir..
			" turns the top "..turns[1])
	assert(turns[2] == facedir % 4, "shapes: facedir "..facedir..
			" turns the bottom "..turns[2])
	-- The sides are upright whichever way it faces
	for face = 3, 6 do
		assert(turns[face] == 0, "shapes: facedir "..facedir..
				" turned a side")
	end
end
for face = 1, 6 do
	assert(shapes.FACEDIR_TILE_TURNS[21][face] == 2,
			"shapes: an upside-down voxel's face "..face.." is not turned")
end

-- A box turns with the voxel: the back half of a stair is at +Z to begin
-- with, and a quarter turn about Y puts it at +X
local turned_box = shapes.turn_box({-0.5, 0, 0, 0.5, 0.5, 0.5}, 1)
assert(math.abs(turned_box[1] - 0) < 1e-9 and
		math.abs(turned_box[4] - 0.5) < 1e-9,
		"shapes: a turned box runs from "..turned_box[1].." to "..
		turned_box[4].." in x")
assert(math.abs(turned_box[3] + 0.5) < 1e-9 and
		math.abs(turned_box[6] - 0.5) < 1e-9, "shapes: and covers z")
assert(math.abs(turned_box[2] - 0) < 1e-9 and
		math.abs(turned_box[5] - 0.5) < 1e-9,
		"shapes: a turn about Y leaves y alone")

-- A wallmounted node box is made of the box for the wall it is on
local wall_boxes = {
	top = {-0.5, 0.4, -0.5, 0.5, 0.5, 0.5},
	bottom = {-0.5, -0.5, -0.5, 0.5, -0.4, 0.5},
	side = {-0.5, -0.5, -0.5, -0.4, 0.5, 0.5},
}
local function box_of(quads)
	local lo, hi = {1e9, 1e9, 1e9}, {-1e9, -1e9, -1e9}
	for _, q in ipairs(quads) do
		for c = 0, 3 do
			for a = 1, 3 do
				lo[a] = math.min(lo[a], q.p[c * 3 + a])
				hi[a] = math.max(hi[a], q.p[c * 3 + a])
			end
		end
	end
	return lo, hi
end
local lo, hi = box_of(shapes.wall_quads(wall_boxes, 0))
assert(lo[2] > 0.39 and hi[2] > 0.49, "shapes: wallmounted on the ceiling")
lo, hi = box_of(shapes.wall_quads(wall_boxes, 1))
assert(hi[2] < -0.39, "shapes: wallmounted on the floor")
-- The side box is against -X to begin with; on the +X wall it is turned round
lo, hi = box_of(shapes.wall_quads(wall_boxes, 2))
assert(lo[1] > 0.39, "shapes: wallmounted on the +X wall is at "..lo[1])
lo, hi = box_of(shapes.wall_quads(wall_boxes, 3))
assert(hi[1] < -0.39, "shapes: wallmounted on the -X wall")
lo, hi = box_of(shapes.wall_quads(wall_boxes, 4))
assert(lo[3] > 0.39, "shapes: wallmounted on the +Z wall")
lo, hi = box_of(shapes.wall_quads(wall_boxes, 5))
assert(hi[3] < -0.39, "shapes: wallmounted on the -Z wall")

-- A wallmounted direction is the side of the node the wall is on, so a sign
-- faces the other way: one on the ceiling looks down
for wall, face in pairs({[0] = 2, [1] = 1, [2] = 4, [3] = 3, [4] = 6,
		[5] = 5}) do
	local q = shapes.sign_quads(1, wall)[1]
	assert(quad_face(q) == face, "shapes: a sign on wall "..wall..
			" faces "..tostring(quad_face(q)))
end

-- A torch on a wall wears the third tile and turns to face out of it; one on
-- the ceiling wears the second and leans, so it faces no axis at all
local q = shapes.torch_quads(1, 2, {})[1]
assert(q.tile == 3, "shapes: a torch on a wall wears tile "..q.tile)
assert(quad_face(q) == 6, "shapes: a torch on the +X wall faces "..
		tostring(quad_face(q)))
assert(quad_face(shapes.torch_quads(1, 3, {})[1]) == 5,
		"shapes: a torch on the -X wall faces the same way as one on +X")
local ceiling = shapes.torch_quads(1, 0, {})[1]
assert(ceiling.tile == 2,
		"shapes: a torch on the ceiling wears tile "..ceiling.tile)
assert(quad_face(ceiling) == nil, "shapes: a torch on the ceiling stands up")

print("shapes: ok")

-- objmesh.lua

-- A quad and a triangle, two materials, and texture coordinates that have to
-- be turned over: .obj counts its second coordinate from the bottom and a
-- voxel's shape counts it from the top
local quads, groups, skipped = objmesh.parse([[
# a comment
mtllib thing.mtl
o thing
v -0.5 -0.5 0.0
v 0.5 -0.5 0.0
v 0.5 0.5 0.0
v -0.5 0.5 0.0
vt 0.0 0.0
vt 1.0 0.0
vt 1.0 1.0
vt 0.0 1.0
usemtl first
f 1/1/1 2/2/1 3/3/1 4/4/1
usemtl second
f 1/1 2/2 3/3
f 1 2
]])
assert(groups == 2, "objmesh: two materials, got "..groups)
assert(skipped == 1, "objmesh: a two-corner face is not a face")
assert(#quads == 2, "objmesh: two faces, got "..#quads)
assert(quads[1].group == 1 and quads[2].group == 2,
		"objmesh: usemtl starts a group")
assert(quads[1].p[1] == -0.5 and quads[1].p[2] == -0.5 and
		quads[1].p[12] == 0.0, "objmesh: the corners go straight through")
-- vt 0,0 is the bottom left of the texture and 0,1 the top left
assert(quads[1].uv[1] == 0.0 and quads[1].uv[2] == 1.0,
		"objmesh: the second texture coordinate is turned over")
assert(quads[1].uv[7] == 0.0 and quads[1].uv[8] == 0.0,
		"objmesh: the fourth corner's texture coordinate")
-- A triangle is a quad with its last corner twice
local tri = quads[2]
assert(tri.p[7] == tri.p[10] and tri.p[8] == tri.p[11] and
		tri.p[9] == tri.p[12], "objmesh: a triangle repeats its last corner")
assert(tri.uv[5] == tri.uv[7] and tri.uv[6] == tri.uv[8],
		"objmesh: a triangle repeats its last texture coordinate")

-- A negative index counts back from the end of the list
local neg = objmesh.parse([[
v 0 0 0
v 1 0 0
v 1 1 0
v 0 1 0
f -4 -3 -2 -1
]])
assert(#neg == 1 and neg[1].p[1] == 0 and neg[1].p[10] == 0 and
		neg[1].p[11] == 1, "objmesh: a negative index counts back")

-- No texture coordinates: the whole tile over the whole face
assert(neg[1].uv[1] == 0 and neg[1].uv[2] == 0 and neg[1].uv[3] == 1 and
		neg[1].uv[5] == 1 and neg[1].uv[6] == 1 and neg[1].uv[7] == 0,
		"objmesh: a face with no vt gets the whole tile")

-- visual_scale multiplies every corner
objmesh.scale(neg, 2)
assert(neg[1].p[10] == 0 and neg[1].p[11] == 2,
		"objmesh: scale multiplies the corners")

-- A face naming a vertex that is not there is not a face
local bad = objmesh.parse("v 0 0 0\nf 1 2 3 9\n")
assert(#bad == 0, "objmesh: a face out of range is skipped")

-- The winding a shape wants: the cross product of two consecutive edges
-- points out of the shape. shapes.lua's own boxes are what the mesher is
-- known to draw right, so they are the reference; a .obj face is wound the
-- same way, counter-clockwise seen from outside, and goes through untouched.
local function quad_normal(q)
	local function corner(i)
		return {q.p[i * 3 + 1], q.p[i * 3 + 2], q.p[i * 3 + 3]}
	end
	local a, b, c = corner(0), corner(1), corner(2)
	local e1 = {b[1] - a[1], b[2] - a[2], b[3] - a[3]}
	local e2 = {c[1] - b[1], c[2] - b[2], c[3] - b[3]}
	return {e1[2] * e2[3] - e1[3] * e2[2], e1[3] * e2[1] - e1[1] * e2[3],
			e1[1] * e2[2] - e1[2] * e2[1]}
end

-- The reference: a whole cube's +Y face points +Y
local cube = shapes.box_quads({-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}, {})
local up = nil
for _, q in ipairs(cube) do
	if q.tile == 1 then up = quad_normal(q) end
end
assert(up and up[2] > 0, "shapes: a box's top face points up")

-- The same for a .obj face: a square in the y = 0.5 plane wound
-- counter-clockwise seen from above has to come out pointing up
local top = objmesh.parse([[
v -0.5 0.5 0.5
v 0.5 0.5 0.5
v 0.5 0.5 -0.5
v -0.5 0.5 -0.5
f 1 2 3 4
]])
local n = quad_normal(top[1])
assert(n[2] > 0, "objmesh: a face wound as .obj winds it points outwards")

print("objmesh: ok")

print("luanti_client/test.lua: ok")
