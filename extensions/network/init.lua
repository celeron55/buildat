-- Buildat: extension/network/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- TCP and UDP sockets for scripts, with the user in the loop: the first
-- connection or datagram to an address in a week needs the user to accept the
-- address and name it. Answers are remembered in
-- user/network_addresses.csv.
--
--   local socket = require("buildat/extension/network")
--   socket.udp_connect("localhost", 30001, function(sock, err)
--       if not sock then log:error(err) return end
--       sock:send("hello")
--       local data, err = sock:receive() -- nil, "timeout" if nothing yet
--   end)
--
-- The socket objects are LuaSocket's, as far as the safety layer allows:
--
-- * Opening a socket takes a callback, because the user has to answer the
--   dialog first, and the address comes with it: there is no socket.tcp() /
--   socket.udp() followed by connect() or setpeername().
-- * A socket only talks to the one address the user accepted. Listening
--   sockets and unconnected UDP do not exist here.
-- * The sockets are always non-blocking, as with settimeout(0); settimeout()
--   accepts 0 and warns about anything else.
-- * socket.select(), socket.sleep(), socket.dns and socket.bind() are not
--   provided. A game polls its sockets from an Update handler instead.

local log = buildat.Logger("extension/network")
local ui_utils = require("buildat/extension/ui_utils").safe
local uistack = require("buildat/extension/uistack")
local magic = require("buildat/extension/urho3d").safe
local M = {safe = {}}

local ACCEPTANCE_VALID_S = 7 * 24 * 3600

local store_path = __buildat_get_path("user").."/network_addresses.csv"

-- Addresses this session has already notified about
local notified = {}

-- The store
--
-- CSV, because there are a handful of rows, they want to be readable and
-- editable by hand, and there is no schema to migrate. Every field is quoted so
-- that a description can contain a comma or a quote.

local csv = dofile(__buildat_extension_path("network").."/csv.lua")

-- uri -> {accepted=, uri=, description=, created=, last_attempt=, name=}
-- name is the player name last used on that server ([BOX_PLAYTEST_2] 4),
-- "" for none; a row written before the column has none.
local function load_store()
	local entries = {}
	local file = io.open(store_path, "r")
	if not file then
		return entries
	end
	for line in file:lines() do
		if line ~= "" and not line:match("^accepted,") then
			local f = csv.parse_line(line)
			if f[2] and f[2] ~= "" then
				entries[f[2]] = {
					accepted = (f[1] == "true"),
					uri = f[2],
					description = f[3] or "",
					created = tonumber(f[4]) or 0,
					last_attempt = tonumber(f[5]) or 0,
					name = f[6] or "",
				}
			end
		end
	end
	file:close()
	return entries
end

local function save_store(entries)
	local uris = {}
	for uri, _ in pairs(entries) do
		table.insert(uris, uri)
	end
	table.sort(uris)
	local file, err = io.open(store_path, "w")
	if not file then
		log:error("Cannot write "..store_path..": "..tostring(err))
		return
	end
	file:write("accepted,address,description,created,last_attempt,name\n")
	for _, uri in ipairs(uris) do
		local e = entries[uri]
		file:write(table.concat({
			csv.quote(e.accepted and "true" or "false"),
			csv.quote(e.uri),
			csv.quote(e.description),
			csv.quote(math.floor(e.created)),
			csv.quote(math.floor(e.last_attempt)),
			csv.quote(e.name or ""),
		}, ",").."\n")
	end
	file:close()
end

local function store_answer(uri, accepted, description, old_entry)
	local entries = load_store()
	local now = os.time()
	entries[uri] = {
		accepted = accepted,
		uri = uri,
		-- A description is one line of text
		description = tostring(description or ""):gsub("[\r\n]", " "),
		created = (old_entry and old_entry.created ~= 0) and old_entry.created or now,
		last_attempt = now,
	}
	save_store(entries)
end

local function touch_entry(uri)
	local entries = load_store()
	if entries[uri] then
		entries[uri].last_attempt = os.time()
		save_store(entries)
	end
end

-- The dialog

local function format_time(t)
	if not t or t == 0 then
		return "never"
	end
	return os.date("%Y-%m-%d %H:%M", t)
end

-- on_answer(accepted: boolean, description: string)
local function ask_user(uri, entry, on_answer)
	local root = uistack.main:push({desc="network permission dialog"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "__menu/res/main_style.xml")

	local menu = ui_utils.vertical_menu(root, {min_width = 400})
	local window = menu.window

	local function add_text(text)
		local t = window:CreateChild("Text")
		t:SetStyleAuto()
		t.text = text
		t:SetTextAlignment(HA_LEFT)
		return t
	end

	add_text("A script wants to use the network:")
	add_text(uri)
	if entry then
		add_text("You have seen this address before:")
		add_text("  Answer: "..(entry.accepted and "accepted" or "declined"))
		add_text("  Description: "..entry.description)
		add_text("  First asked: "..format_time(entry.created))
		add_text("  Last attempt: "..format_time(entry.last_attempt))
	end
	add_text("Description (what is this peer?):")

	local edit = window:CreateChild("LineEdit")
	edit:SetStyleAuto()
	edit.minHeight = 24
	edit.minWidth = 380
	edit:SetText(entry and entry.description or "")
	edit:SetFocus(true)

	local answered = false
	local function answer(accepted)
		if answered then
			return
		end
		answered = true
		local description = edit:GetText()
		uistack.main:pop(root)
		on_answer(accepted, description)
	end

	menu:add("Accept", function() answer(true) end)
	menu:add("Decline", function() answer(false) end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			answer(false)
		end
	end)
end

-- The sockets
--
-- The interface is LuaSocket's, as far as the safety layer allows: opening a
-- socket takes a callback because the user has to answer first, and there are
-- no listening sockets and no unconnected UDP. Everything after opening --
-- send, receive, patterns, error strings, timeouts -- works like LuaSocket
-- with settimeout(0).

-- LuaSocket's word for why receive() or send() got nothing done
local function socket_error(socket)
	if socket:good() then
		return "timeout"
	end
	local err = socket:error()
	if err == "" then
		return "closed"
	end
	return err
end

-- Plain Lua wrapper; the socket object from C++ is not sandbox-safe, and this
-- is where the first-packet notification happens.
local function wrap_common(socket, uri, is_udp)
	local w = {}

	local function notify()
		if notified[uri] then
			return
		end
		notified[uri] = true
		ui_utils.show_notification("Connected to "..socket:address())
	end
	if not is_udp then
		notify() -- The connection itself is the event for TCP
	end

	-- send(data [, i [, j]]) -> index of the last byte sent
	function w:send(data, i, j)
		local first = i or 1
		if first < 0 then
			first = #data + first + 1
		end
		local part = data:sub(first, j or -1)
		local sent = socket:send(part)
		if sent > 0 then
			notify()
		end
		if sent < 0 then
			return nil, socket_error(socket)
		end
		if is_udp then
			-- A datagram goes whole or not at all
			if sent < #part then
				return nil, socket_error(socket)
			end
			return 1
		end
		if sent == #part then
			return first + sent - 1
		end
		return nil, "timeout", first + sent - 1
	end

	function w:close()
		socket:close()
		return 1
	end

	function w:getpeername()
		return socket:peer_ip(), socket:peer_port()
	end

	function w:getsockname()
		return socket:local_ip(), socket:local_port()
	end

	-- simplified: the sockets are always non-blocking, which is what
	-- settimeout(0) asks for. Upgrade path if a script needs to wait: select()
	-- around the recv() in src/lua_bindings/network.cpp.
	function w:settimeout(value, mode)
		if value ~= nil and value ~= 0 then
			log:warning("settimeout("..tostring(value)..
					"): only 0 is supported; staying non-blocking")
		end
		return 1
	end

	function w:setoption(option, value)
		return nil, "setoption() is not supported"
	end

	-- Not LuaSocket's, but the address as the user accepted it
	function w:address()
		return socket:address()
	end

	return w
end

local function wrap_tcp(socket, uri)
	local w = wrap_common(socket, uri, false)
	local buffer = ""

	local function pump()
		while true do
			local data = socket:receive()
			if data == "" then
				return
			end
			buffer = buffer..data
		end
	end

	local function take_all()
		local data = buffer
		buffer = ""
		return data
	end

	-- receive([pattern [, prefix]]): a number of bytes, "*a" until the peer
	-- closes the connection, or "*l" one line (the default). What was read
	-- before a timeout comes back as the third value; pass it back as prefix.
	function w:receive(pattern, prefix)
		prefix = prefix or ""
		pattern = pattern or "*l"
		pump()
		if type(pattern) == "number" then
			if #buffer >= pattern then
				local data = buffer:sub(1, pattern)
				buffer = buffer:sub(pattern + 1)
				return prefix..data
			end
			return nil, socket_error(socket), prefix..take_all()
		end
		if pattern == "*a" then
			local data = prefix..take_all()
			if socket:good() then
				return nil, "timeout", data
			end
			if socket:error() == "closed" then
				return data
			end
			return nil, socket:error(), data
		end
		if pattern == "*l" then
			local i = buffer:find("\n", 1, true)
			if i then
				local line = buffer:sub(1, i - 1)
				buffer = buffer:sub(i + 1)
				if line:sub(-1) == "\r" then
					line = line:sub(1, -2)
				end
				return prefix..line
			end
			return nil, socket_error(socket), prefix..take_all()
		end
		error("receive(): unknown pattern "..tostring(pattern))
	end

	return w
end

local function wrap_udp(socket, uri)
	local w = wrap_common(socket, uri, true)

	-- receive([size]): one datagram, truncated to size if given. An empty
	-- datagram is indistinguishable from no datagram.
	function w:receive(size)
		local data = socket:receive()
		if data == "" then
			return nil, socket_error(socket)
		end
		if size and #data > size then
			return data:sub(1, size)
		end
		return data
	end

	function w:receivefrom(size)
		local data, err = w.receive(self, size)
		if not data then
			return nil, err
		end
		return data, socket:peer_ip(), socket:peer_port()
	end

	-- The socket only talks to the address the user accepted
	function w:sendto(data, ip, port)
		if ip ~= socket:peer_ip() or tonumber(port) ~= socket:peer_port() then
			return nil, "this socket is connected to "..socket:address()
		end
		return w.send(self, data)
	end

	function w:setpeername(ip, port)
		return nil, "the peer is set when the socket is opened"
	end

	function w:setsockname(ip, port)
		return nil, "listening sockets are not supported"
	end

	return w
end

local function open_socket(is_udp, host, port, cb)
	local socket = is_udp and
			__buildat_udp_connect(host, tostring(port)) or
			__buildat_tcp_connect(host, tostring(port))
	if not socket:good() then
		cb(nil, socket:error())
		return
	end
	local uri = (is_udp and "udp://" or "tcp://")..host..":"..port
	cb(is_udp and wrap_udp(socket, uri) or wrap_tcp(socket, uri))
end

-- cb(socket, error): socket is nil if the connection was not made or the user
-- declined the address
local function connect(is_udp, host, port, cb)
	if type(host) ~= "string" or not tonumber(port) or type(cb) ~= "function" then
		error("network: connect(host: string, port: number, cb: function)")
	end
	local uri = (is_udp and "udp://" or "tcp://")..host..":"..port
	local entry = load_store()[uri]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(uri)
		open_socket(is_udp, host, port, cb)
		return
	end
	log:info("Asking the user about "..uri)
	ask_user(uri, entry, function(accepted, description)
		store_answer(uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		open_socket(is_udp, host, port, cb)
	end)
end

function M.safe.tcp_connect(host, port, cb)
	connect(false, host, port, cb)
end

function M.safe.udp_connect(host, port, cb)
	connect(true, host, port, cb)
end

-- http_get(url, cb): the body of a GET over HTTPS, cb(body) or
-- cb(nil, error), asked of the user through the same dialog and file as a
-- socket is -- the uri is the url's scheme and host ([SERVER_LIST]:
-- Luanti's official server list). Fetched on a thread in the client
-- (__buildat_http_get); read back on Update.
local http_pending = {}
local http_polling = false
local function http_start(url, cb)
	local id = __buildat_http_get(url)
	http_pending[id] = cb
	if not http_polling then
		http_polling = true
		magic.SubscribeToEvent("Update", function()
			for jid, callback in pairs(http_pending) do
				local ok, body = __buildat_http_poll(jid)
				if ok ~= nil then
					http_pending[jid] = nil
					if ok then
						callback(body)
					else
						callback(nil, body)
					end
				end
			end
		end)
	end
end

function M.safe.http_get(url, cb)
	if type(url) ~= "string" or type(cb) ~= "function" then
		error("network: http_get(url: string, cb: function)")
	end
	local scheme, host = url:match("^(https?)://([^/:]+)")
	if not scheme then
		cb(nil, "not an http(s) url: "..url)
		return
	end
	local uri = scheme.."://"..host
	local entry = load_store()[uri]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(uri)
		http_start(url, cb)
		return
	end
	log:info("Asking the user about "..uri)
	ask_user(uri, entry, function(accepted, description)
		store_answer(uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		http_start(url, cb)
	end)
end

-- The addresses this client has used, for a list to pick from: the
-- store's entries as {uri, description, created, last_attempt, accepted},
-- the last used first
function M.safe.known_addresses()
	local out = {}
	for uri, e in pairs(load_store()) do
		out[#out + 1] = {uri = uri, description = e.description or "",
				created = e.created or 0, last_attempt = e.last_attempt or 0,
				accepted = e.accepted and true or false, name = e.name or ""}
	end
	table.sort(out, function(a, b) return a.last_attempt > b.last_attempt end)
	return out
end

-- set_address_name(uri, name): the player name used on a server, kept on
-- its row for the next connect screen; a uri with no row is ignored
function M.safe.set_address_name(uri, name)
	if type(uri) ~= "string" or type(name) ~= "string" or #name > 64 then
		return false
	end
	local entries = load_store()
	local e = entries[uri]
	if not e then
		return false
	end
	e.name = name
	save_store(entries)
	return true
end

-- parse_json(text) -> table or nil, error: the module's own reader
-- (json.lua beside this file), which defines onto a `core` table
local parse_json
do
	local saved = rawget(_G, "core")
	rawset(_G, "core", {log = function(_, message) log:warning(message) end})
	dofile(__buildat_extension_path("network").."/json.lua")
	parse_json = core.parse_json
	rawset(_G, "core", saved)
end
function M.safe.parse_json(text)
	return parse_json(text, nil, true)
end

-- LuaSocket's socket.gettime()
function M.safe.gettime()
	return buildat.get_time_us() / 1000000
end

M.tcp_connect = M.safe.tcp_connect
M.udp_connect = M.safe.udp_connect
M.gettime = M.safe.gettime
M.http_get = M.safe.http_get
M.known_addresses = M.safe.known_addresses
M.set_address_name = M.safe.set_address_name
M.parse_json = M.safe.parse_json

return M
-- vim: set noet ts=4 sw=4:
