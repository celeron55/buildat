-- Buildat: extension/luanti_client/client.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- Luanti's client side of the login, on top of connection.lua:
--
--   client -> INIT (name, protocol range)
--   server -> HELLO (protocol version, which auth mechanisms it takes)
--   client -> SRP_BYTES_A or FIRST_SRP (a new player registers a verifier)
--   server -> SRP_BYTES_S_B (salt and B)
--   client -> SRP_BYTES_M (the proof)
--   server -> AUTH_ACCEPT, and then the definitions and the media
--   client -> INIT2, and CLIENT_READY once it has what it needs
--
-- Commands that are not handled yet are counted and logged; see
-- doc/luanti_client.txt for what is left.

local path = __buildat_extension_path("luanti_client")
local serialize = dofile(path.."/serialize.lua")
local connection = dofile(path.."/connection.lua")
local srp = dofile(path.."/srp.lua")

local M = {}

-- What this client tells the server it is
local SER_FMT_VER_HIGHEST_READ = 29
local CLIENT_PROTOCOL_VERSION_MIN = 37
local LATEST_PROTOCOL_VERSION = 52
local FORMSPEC_API_VERSION = 8
local VERSION = {major = 5, minor = 15, patch = 0, hash = "buildat"}

local TOSERVER = {
	INIT          = 0x02,
	INIT2         = 0x11,
	PLAYERPOS     = 0x23,
	GOTBLOCKS     = 0x24,
	REQUEST_MEDIA = 0x40,
	CLIENT_READY  = 0x43,
	FIRST_SRP     = 0x50,
	SRP_BYTES_A   = 0x51,
	SRP_BYTES_M   = 0x52,
}

-- The channel each command goes on, and whether it is sent reliably; from
-- Luanti's serverCommandFactoryTable
local TOSERVER_DELIVERY = {
	[TOSERVER.INIT]          = {1, false},
	[TOSERVER.INIT2]         = {1, true},
	[TOSERVER.PLAYERPOS]     = {0, false},
	[TOSERVER.GOTBLOCKS]     = {2, true},
	[TOSERVER.REQUEST_MEDIA] = {1, true},
	[TOSERVER.CLIENT_READY]  = {1, true},
	[TOSERVER.FIRST_SRP]     = {1, true},
	[TOSERVER.SRP_BYTES_A]   = {1, true},
	[TOSERVER.SRP_BYTES_M]   = {1, true},
}

local TOCLIENT = {
	HELLO          = 0x02,
	AUTH_ACCEPT    = 0x03,
	ACCESS_DENIED  = 0x0A,
	BLOCKDATA      = 0x20,
	TIME_OF_DAY    = 0x29,
	MOVE_PLAYER    = 0x34,
	MEDIA          = 0x38,
	NODEDEF        = 0x3A,
	ANNOUNCE_MEDIA = 0x3C,
	ITEMDEF        = 0x3D,
	SRP_BYTES_S_B  = 0x60,
}

-- 16x16x16 nodes to a mapblock, as everywhere in Luanti
local MAP_BLOCKSIZE = 16
local NODECOUNT = MAP_BLOCKSIZE * MAP_BLOCKSIZE * MAP_BLOCKSIZE
-- Luanti's BS: one node is this many of the units positions come in
local BS = 10.0

-- Node ids that mean something to everyone, whatever the game is; from
-- Luanti's mapnode.h. Everything else needs the node definitions.
M.CONTENT_UNKNOWN = 125
M.CONTENT_AIR = 126
M.CONTENT_IGNORE = 127

-- How often the server hears where we are. It sends blocks around the last
-- position it heard, so nothing arrives until this does.
local PLAYERPOS_INTERVAL = 0.1
-- How many blocks out to ask for. The server adds one and then clips this to
-- its own max_block_send_distance.
local WANTED_RANGE_BLOCKS = 6
-- The field of view we claim, in radians; the server culls blocks outside it
local FOV = 1.72

-- For logging what is not handled yet; from Luanti's ToClientCommand enum
local TOCLIENT_NAME = {
	[0x02] = "HELLO",
	[0x03] = "AUTH_ACCEPT",
	[0x04] = "ACCEPT_SUDO_MODE",
	[0x05] = "DENY_SUDO_MODE",
	[0x0a] = "ACCESS_DENIED",
	[0x20] = "BLOCKDATA",
	[0x21] = "ADDNODE",
	[0x22] = "REMOVENODE",
	[0x27] = "INVENTORY",
	[0x29] = "TIME_OF_DAY",
	[0x2a] = "CSM_RESTRICTION_FLAGS",
	[0x2b] = "PLAYER_SPEED",
	[0x2c] = "MEDIA_PUSH",
	[0x2f] = "CHAT_MESSAGE",
	[0x31] = "ACTIVE_OBJECT_REMOVE_ADD",
	[0x32] = "ACTIVE_OBJECT_MESSAGES",
	[0x33] = "HP",
	[0x34] = "MOVE_PLAYER",
	[0x35] = "ACCESS_DENIED_LEGACY",
	[0x36] = "FOV",
	[0x37] = "DEATHSCREEN_LEGACY",
	[0x38] = "MEDIA",
	[0x3a] = "NODEDEF",
	[0x3c] = "ANNOUNCE_MEDIA",
	[0x3d] = "ITEMDEF",
	[0x3f] = "PLAY_SOUND",
	[0x40] = "STOP_SOUND",
	[0x41] = "PRIVILEGES",
	[0x42] = "INVENTORY_FORMSPEC",
	[0x43] = "DETACHED_INVENTORY",
	[0x44] = "SHOW_FORMSPEC",
	[0x45] = "MOVEMENT",
	[0x46] = "SPAWN_PARTICLE",
	[0x47] = "ADD_PARTICLESPAWNER",
	[0x48] = "CAMERA",
	[0x49] = "HUDADD",
	[0x4a] = "HUDRM",
	[0x4b] = "HUDCHANGE",
	[0x4c] = "HUD_SET_FLAGS",
	[0x4d] = "HUD_SET_PARAM",
	[0x4e] = "BREATH",
	[0x4f] = "SET_SKY",
	[0x50] = "OVERRIDE_DAY_NIGHT_RATIO",
	[0x51] = "LOCAL_PLAYER_ANIMATIONS",
	[0x52] = "EYE_OFFSET",
	[0x53] = "DELETE_PARTICLESPAWNER",
	[0x54] = "CLOUD_PARAMS",
	[0x55] = "FADE_SOUND",
	[0x56] = "UPDATE_PLAYER_LIST",
	[0x57] = "MODCHANNEL_MSG",
	[0x58] = "MODCHANNEL_SIGNAL",
	[0x59] = "NODEMETA_CHANGED",
	[0x5a] = "SET_SUN",
	[0x5b] = "SET_MOON",
	[0x5c] = "SET_STARS",
	[0x5d] = "MOVE_PLAYER_REL",
	[0x60] = "SRP_BYTES_S_B",
	[0x61] = "FORMSPEC_PREPEND",
	[0x62] = "MINIMAP_MODES",
	[0x63] = "SET_LIGHTING",
	[0x64] = "SPAWN_PARTICLE_BATCH",
}

local AUTH_MECHANISM = {
	LEGACY_PASSWORD = 1,
	SRP             = 2,
	FIRST_SRP       = 4,
}

-- Parses one BLOCKDATA payload, the u16 command already read off it.
--
-- At serialization version 29 the whole block is one zstd frame, and inside it
--   u8 flags | u16 lighting_complete | u8 content_width | u8 params_width
--   | 4096 u16be param0 | 4096 u8 param1 | 4096 u8 param2 | node metadata
-- and after the frame a u8 of MapBlock::serializeNetworkSpecific. Blocks of one
-- node are expanded before being sent, so the bulk data is always 16384 bytes.
--
-- The three parameter arrays are handed on as they came, because that is what
-- buildat.pack_voxel_volume() takes. Node index order is x fastest, then y,
-- then z, which is also PolyVox's.
local function parse_blockdata(data)
	local r = serialize.reader(data)
	local x, y, z = r:v3s16()
	local raw = buildat.decompress(r:rest(), "zstd")
	local b = serialize.reader(raw)
	local flags = b:u8()
	local lighting_complete = b:u16()
	local content_width = b:u8()
	local params_width = b:u8()
	if content_width ~= 2 or params_width ~= 2 then
		error("luanti_client: mapblock has content_width "..content_width..
				" and params_width "..params_width..", expected 2 and 2")
	end
	return {
		x = x, y = y, z = z,
		is_underground = flags % 2 == 1,
		lighting_complete = lighting_complete,
		param0 = b:raw(NODECOUNT * 2),
		param1 = b:raw(NODECOUNT),
		param2 = b:raw(NODECOUNT),
	}
end

-- new(socket, options, log): options.name, options.password and
-- options.on_status(text), which is called with what is going on.
-- client.on_command(command, data) gets every command that arrives.
function M.new(socket, options, log)
	local self = {
			state = "connecting",
			protocol_version = nil,
			unhandled = {}, -- command -> how many arrived
			on_status = options.on_status,
			on_command = nil,
			-- on_block(block) for each mapblock that arrives; see
			-- parse_blockdata() for what a block holds
			on_block = nil,
			-- on_nodedef(data) with the decompressed NODEDEF payload;
			-- nodedef.lua is what reads it
			on_nodedef = nil,
			-- on_announce_media(files, remote_servers) and
			-- on_media(files, bunch, bunches); media.lua is what keeps them
			on_announce_media = nil,
			on_media = nil,
			-- Where the server last put us, in nodes, and where we tell it we
			-- are. The extension moves this; see set_position().
			position = {x = 0, y = 0, z = 0},
			pitch = 0,
			yaw = 0,
			-- The server's time of day, 0...23999, and how fast it runs
			time_of_day = nil,
			time_speed = 0,
			blocks_received = 0,
	}
	local name = options.name
	local password = options.password or ""
	local srp_client = nil
	local conn = connection.new(socket, log)
	self.connection = conn

	local function status(text)
		log:info(text)
		if self.on_status then
			self.on_status(text)
		end
	end

	local function send_command(command, data)
		local delivery = TOSERVER_DELIVERY[command]
		if not delivery then
			error("luanti_client: no channel known for command "..command)
		end
		local packet = serialize.writer():u16(command):raw(data or ""):data()
		conn:send(delivery[1], delivery[2], packet)
	end
	self.send_command = function(_, command, data)
		send_command(command, data)
	end

	local function send_init()
		local w = serialize.writer()
		w:u8(SER_FMT_VER_HIGHEST_READ)
		w:u16(0) -- Compression modes; never implemented
		w:u16(CLIENT_PROTOCOL_VERSION_MIN)
		w:u16(LATEST_PROTOCOL_VERSION)
		w:string(name)
		send_command(TOSERVER.INIT, w:data())
		self.state = "init_sent"
		status("Sent INIT as "..name)
	end

	-- The mechanisms come as a bit mask; no bit operations in plain Lua 5.1
	local function has_mechanism(mechanisms, mechanism)
		return mechanisms % (mechanism * 2) >= mechanism
	end

	local function start_auth(mechanisms)
		if has_mechanism(mechanisms, AUTH_MECHANISM.SRP) then
			-- A player the server knows: prove we know the password
			srp_client = srp.client(name, name:lower(), password)
			local w = serialize.writer()
			w:string(srp_client:bytes_A())
			w:u8(1) -- Based on the password itself, not the legacy hash
			send_command(TOSERVER.SRP_BYTES_A, w:data())
			self.state = "srp_a_sent"
			status("Logging in as "..name)
		elseif has_mechanism(mechanisms, AUTH_MECHANISM.FIRST_SRP) then
			-- A new player: register a verifier for the password
			local salt, verifier = srp.create_verifier(name:lower(), password)
			local w = serialize.writer()
			w:string(salt)
			w:string(verifier)
			w:u8(password == "" and 1 or 0)
			send_command(TOSERVER.FIRST_SRP, w:data())
			self.state = "first_srp_sent"
			status("Registering "..name)
		else
			status("The server offers no authentication this client can do "..
					"(mechanisms "..mechanisms..")")
			self.state = "failed"
		end
	end

	-- Positions of blocks that have arrived and not been acknowledged yet
	local gotblocks = {}

	local handlers = {}

	handlers[TOCLIENT.HELLO] = function(r)
		local serialization_version = r:u8()
		r:u16() -- Compression modes; never implemented
		self.protocol_version = r:u16()
		local auth_mechanisms = r:u32()
		status("Server speaks protocol "..self.protocol_version..
				" (serialization "..serialization_version..")")
		if self.protocol_version < CLIENT_PROTOCOL_VERSION_MIN then
			status("The server is too old for this client")
			self.state = "failed"
			return
		end
		-- Only serialization version 29 is parsed; older mapblocks compress
		-- their pieces separately and this client has no branch for that
		if serialization_version ~= SER_FMT_VER_HIGHEST_READ then
			status("The server serializes mapblocks as version "..
					serialization_version..", this client reads "..
					SER_FMT_VER_HIGHEST_READ)
			self.state = "failed"
			return
		end
		start_auth(auth_mechanisms)
	end

	handlers[TOCLIENT.SRP_BYTES_S_B] = function(r)
		local salt = r:string()
		local B = r:string()
		if not srp_client then
			status("Got an SRP challenge without having asked for one")
			return
		end
		local proof = srp_client:process_challenge(salt, B)
		if not proof then
			status("The server's SRP challenge failed the safety check")
			self.state = "failed"
			return
		end
		send_command(TOSERVER.SRP_BYTES_M, serialize.writer():string(proof)
				:data())
		self.state = "srp_m_sent"
	end

	handlers[TOCLIENT.AUTH_ACCEPT] = function(r)
		-- v3f unused, u64 map seed, f1000 send interval, u32 sudo mechanisms
		self.state = "authenticated"
		status("Logged in")
		send_command(TOSERVER.INIT2, serialize.writer():string(""):data())
	end

	-- CLIENT_READY is what makes the server spawn the player, and it waits for
	-- the definitions. Their contents are not used yet.
	local got_itemdef, got_nodedef, client_ready_sent = false, false, false

	local function maybe_send_client_ready()
		if client_ready_sent or not (got_itemdef and got_nodedef) then
			return
		end
		client_ready_sent = true
		self:send_client_ready()
		self.state = "spawning"
	end

	handlers[TOCLIENT.ITEMDEF] = function(r)
		-- What an item is is of no use until there is an inventory to show;
		-- the packet arriving is what CLIENT_READY waits for
		got_itemdef = true
		maybe_send_client_ready()
	end

	handlers[TOCLIENT.NODEDEF] = function(r)
		local data = buildat.decompress(r:longstring(), "zstd")
		got_nodedef = true
		if self.on_nodedef then
			self.on_nodedef(data)
		end
		maybe_send_client_ready()
	end

	-- ANNOUNCE_MEDIA at protocol 48 and up: a zstd frame of the file names,
	-- and then a raw 20-byte sha1 for each of them in the same order, in the
	-- rest of the packet.
	--
	-- The name table is Luanti's serializeString16Array, which is not a list
	-- of length-prefixed strings: it is a u32 count, then every length, then
	-- every string's bytes.
	handlers[TOCLIENT.ANNOUNCE_MEDIA] = function(r)
		local nr = serialize.reader(buildat.decompress(r:longstring(), "zstd"))
		local count = nr:u32()
		local sizes = {}
		for i = 1, count do
			sizes[i] = nr:u16()
		end
		local files = {}
		for i = 1, count do
			files[i] = {name = nr:raw(sizes[i])}
		end
		for i = 1, count do
			files[i].sha1 = r:raw(20)
		end
		-- Remote media servers, comma separated. Fetching over HTTP is not
		-- something this client does; the server sends what we ask it for.
		local remote = r:remaining() > 0 and r:string() or ""
		status("The server announced "..count.." media files")
		if self.on_announce_media then
			self.on_announce_media(files, remote)
		end
	end

	handlers[TOCLIENT.MEDIA] = function(r)
		local num_bunches = r:u16()
		local bunch_i = r:u16()
		local num_files = r:u32()
		local files = {}
		for i = 1, num_files do
			local name = r:string()
			files[i] = {
				name = name,
				data = buildat.decompress(r:longstring(), "zstd"),
			}
		end
		if self.on_media then
			self.on_media(files, bunch_i, num_bunches)
		end
	end

	handlers[TOCLIENT.MOVE_PLAYER] = function(r)
		local x, y, z = r:v3f()
		self.position = {x = x / BS, y = y / BS, z = z / BS}
		self.pitch = r:f32()
		self.yaw = r:f32()
		-- Nothing is told where we are until now, and PLAYERPOS would move us
		-- somewhere else if it went out before this
		if self.state ~= "ready" then
			self.state = "ready"
			status(string.format("Spawned at %.0f, %.0f, %.0f",
					self.position.x, self.position.y, self.position.z))
		end
	end

	handlers[TOCLIENT.TIME_OF_DAY] = function(r)
		self.time_of_day = r:u16() % 24000
		self.time_speed = r:f32()
	end

	handlers[TOCLIENT.BLOCKDATA] = function(r)
		local block = parse_blockdata(r:rest())
		self.blocks_received = self.blocks_received + 1
		-- The server throttles on unacknowledged blocks, so this has to go out
		-- whether anything makes use of the block or not
		gotblocks[#gotblocks + 1] = {block.x, block.y, block.z}
		if self.on_block then
			self.on_block(block)
		end
	end

	handlers[TOCLIENT.ACCESS_DENIED] = function(r)
		local reason = r:u8()
		local message = r:remaining() > 0 and r:string() or ""
		self.state = "denied"
		status("The server denied access (reason "..reason..
				(message ~= "" and ": "..message or "")..")")
	end

	local function handle_command(data, channel)
		local r = serialize.reader(data)
		local command = r:u16()
		local handler = handlers[command]
		if handler then
			handler(r)
		else
			self.unhandled[command] = (self.unhandled[command] or 0) + 1
			if self.unhandled[command] == 1 then
				log:verbose("Not handled yet: "..
						(TOCLIENT_NAME[command] or "command")..
						string.format(" (0x%02x), %d bytes", command, #data))
			end
		end
		if self.on_command then
			self.on_command(command, data)
		end
	end

	conn.on_data = function(data, channel)
		local ok, err = pcall(handle_command, data, channel)
		if not ok then
			log:warning("Failed to handle a command: "..tostring(err))
		end
	end

	conn.on_disconnect = function(reason)
		self.state = "disconnected"
		status("Disconnected: "..tostring(reason))
	end

	local function send_playerpos()
		local p = self.position
		local w = serialize.writer()
		-- Positions go as hundredths of a BS unit, so nodes * 1000
		w:v3s32(math.floor(p.x * BS * 100), math.floor(p.y * BS * 100),
				math.floor(p.z * BS * 100))
		w:v3s32(0, 0, 0) -- Speed; nothing moves yet
		w:s32(math.floor(self.pitch * 100))
		w:s32(math.floor(self.yaw * 100))
		w:u32(0) -- Keys pressed
		w:u8(math.floor(FOV * 80)) -- The server culls blocks outside this
		w:u8(WANTED_RANGE_BLOCKS)
		w:u8(0) -- Bits; the only one so far is an inverted camera
		-- The two f32 movement fields after this are optional and the server
		-- falls back to the keys when they are missing
		send_command(TOSERVER.PLAYERPOS, w:data())
	end

	-- One packet holds a u8 count, so the acknowledgements go in batches; 32
	-- positions and the command still fit one datagram
	local GOTBLOCKS_PER_PACKET = 32

	local function send_gotblocks()
		while #gotblocks > 0 do
			local count = math.min(#gotblocks, GOTBLOCKS_PER_PACKET)
			local w = serialize.writer():u8(count)
			for i = 1, count do
				local p = table.remove(gotblocks, 1)
				w:v3s16(p[1], p[2], p[3])
			end
			send_command(TOSERVER.GOTBLOCKS, w:data())
		end
	end

	local playerpos_timer = PLAYERPOS_INTERVAL

	function self:update(dtime)
		conn:update(dtime)
		if self.state ~= "ready" then
			return
		end
		playerpos_timer = playerpos_timer + dtime
		if playerpos_timer >= PLAYERPOS_INTERVAL then
			playerpos_timer = 0
			send_playerpos()
		end
		send_gotblocks()
	end

	-- Asks the server for media files by name. The list is usually far too big
	-- for one datagram, which is what connection.lua's outgoing split is for.
	function self:request_media(names)
		if #names == 0 then
			return
		end
		local w = serialize.writer():u16(#names)
		for _, name in ipairs(names) do
			w:string(name)
		end
		send_command(TOSERVER.REQUEST_MEDIA, w:data())
		status("Asked for "..#names.." media files")
	end

	-- Where the client says it is, in nodes. The server sends the blocks
	-- around this and moves the player to it, so it is both the camera's
	-- position and the player's.
	function self:set_position(x, y, z, pitch, yaw)
		self.position = {x = x, y = y, z = z}
		self.pitch = pitch or self.pitch
		self.yaw = yaw or self.yaw
	end

	function self:send_client_ready()
		local w = serialize.writer()
		w:u8(VERSION.major):u8(VERSION.minor):u8(VERSION.patch):u8(0)
		w:string(VERSION.hash)
		w:u16(FORMSPEC_API_VERSION)
		send_command(TOSERVER.CLIENT_READY, w:data())
		status("Sent CLIENT_READY")
	end

	function self:disconnect()
		conn:disconnect()
	end

	-- How many of each command arrived without being handled
	function self:unhandled_summary()
		local names = {}
		for command, count in pairs(self.unhandled) do
			names[#names + 1] = (TOCLIENT_NAME[command] or
					string.format("0x%02x", command)).." x"..count
		end
		table.sort(names)
		return table.concat(names, ", ")
	end

	send_init()
	return self
end

M.serialize = serialize
M.MAP_BLOCKSIZE = MAP_BLOCKSIZE
M.NODECOUNT = NODECOUNT
M.BS = BS
M.TOSERVER = TOSERVER
M.TOCLIENT = TOCLIENT
M.TOCLIENT_NAME = TOCLIENT_NAME

return M
-- vim: set noet ts=4 sw=4:
