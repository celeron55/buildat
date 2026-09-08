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
	INIT         = 0x02,
	INIT2        = 0x11,
	CLIENT_READY = 0x43,
	FIRST_SRP    = 0x50,
	SRP_BYTES_A  = 0x51,
	SRP_BYTES_M  = 0x52,
}

-- The channel each command goes on, and whether it is sent reliably; from
-- Luanti's serverCommandFactoryTable
local TOSERVER_DELIVERY = {
	[TOSERVER.INIT]         = {1, false},
	[TOSERVER.INIT2]        = {1, true},
	[TOSERVER.CLIENT_READY] = {1, true},
	[TOSERVER.FIRST_SRP]    = {1, true},
	[TOSERVER.SRP_BYTES_A]  = {1, true},
	[TOSERVER.SRP_BYTES_M]  = {1, true},
}

local TOCLIENT = {
	HELLO         = 0x02,
	AUTH_ACCEPT   = 0x03,
	ACCESS_DENIED = 0x0A,
	SRP_BYTES_S_B = 0x60,
}

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

	function self:update(dtime)
		conn:update(dtime)
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

M.TOSERVER = TOSERVER
M.TOCLIENT = TOCLIENT
M.TOCLIENT_NAME = TOCLIENT_NAME

return M
-- vim: set noet ts=4 sw=4:
