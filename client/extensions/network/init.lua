-- Buildat: extension/network/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- TCP and UDP sockets for scripts, with the user in the loop: the first
-- connection or datagram to an address in a week needs the user to accept the
-- address and name it. Answers are remembered in
-- user/network_addresses.csv, **one per asking server and address**
-- ([CONSENT_PER_SERVER]): what the user gave server A's scripts, server
-- B's ask for again. The client's own extensions (the `M.*` functions,
-- not `M.safe`) ask as the client, "".
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

-- The server whose scripts are asking: a server this client started is
-- its game's, "local:<app>", as its port changes every launch (the same
-- origin as game_storage_dir); any other its address. "" for none.
local function asking_server()
	local dir = __buildat_game_storage_dir()
	if not dir then
		return ""
	end
	local app = dir:match("/apps/([^/]+)/client$")
	return app and "local:"..app or __buildat_server_address() or ""
end

local function key(server, uri)
	return server.." "..uri
end

-- key(server, uri) -> {accepted=, uri=, description=, created=,
-- last_attempt=, name=, icon=, server=}
-- name is the player name last used on that server ([BOX_PLAYTEST_2] 4),
-- "" for none. A row with no server column is from before
-- [CONSENT_PER_SERVER] and is dropped: it was every server's.
local function load_store()
	local entries = {}
	local file = io.open(store_path, "r")
	if not file then
		return entries
	end
	for line in file:lines() do
		if line ~= "" and not line:match("^accepted,") then
			local f = csv.parse_line(line)
			if f[2] and f[2] ~= "" and f[8] then
				entries[key(f[8], f[2])] = {
					accepted = (f[1] == "true"),
					uri = f[2],
					description = f[3] or "",
					created = tonumber(f[4]) or 0,
					last_attempt = tonumber(f[5]) or 0,
					name = f[6] or "",
					-- [LAUNCH_WORLD] (4): the sha256 of the icon the
					-- server sent at its last connect, under the cache's
					-- server_icons/; "" for none
					icon = f[7] or "",
					server = f[8],
				}
			end
		end
	end
	file:close()
	return entries
end

local function save_store(entries)
	local keys = {}
	for k, _ in pairs(entries) do
		table.insert(keys, k)
	end
	table.sort(keys)
	local file, err = io.open(store_path, "w")
	if not file then
		log:error("Cannot write "..store_path..": "..tostring(err))
		return
	end
	file:write("accepted,address,description,created,last_attempt,name,icon,server\n")
	-- A row is a line: the reader splits on them, and a field with a line
	-- break in it -- a name a server's script set -- was a second row
	-- nobody accepted ([SECURITY_RUN_1])
	local function q(v)
		return csv.quote((tostring(v):gsub("[\r\n]", " ")))
	end
	for _, k in ipairs(keys) do
		local e = entries[k]
		file:write(table.concat({
			q(e.accepted and "true" or "false"),
			q(e.uri),
			q(e.description),
			q(math.floor(e.created)),
			q(math.floor(e.last_attempt)),
			q(e.name or ""),
			q(e.icon or ""),
			q(e.server),
		}, ",").."\n")
	end
	file:close()
end

local function store_answer(server, uri, accepted, description, old_entry)
	local entries = load_store()
	local now = os.time()
	entries[key(server, uri)] = {
		accepted = accepted,
		uri = uri,
		-- A description is one line of text
		description = tostring(description or ""):gsub("[\r\n]", " "),
		created = (old_entry and old_entry.created ~= 0) and old_entry.created or now,
		last_attempt = now,
		-- What the row had besides the answer is kept with it
		name = old_entry and old_entry.name or "",
		icon = old_entry and old_entry.icon or "",
		server = server,
	}
	save_store(entries)
end

local function touch_entry(server, uri)
	local entries = load_store()
	local e = entries[key(server, uri)]
	if e then
		e.last_attempt = os.time()
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

-- **What the user sees is what they answer** ([SECURITY_RUN_1]): a
-- dialog is in the UI tree every script shares and on the stack they
-- read, so a server's script could rewrite the address it shows, swap
-- the buttons' labels, or make Accept invisible over a Decline of its
-- own. The dialog is taken down to its raw elements once laid out --
-- what each shows, where, how visible, how many children -- and
-- compared every frame and at the answer; on_changed is called on any
-- change. Read fresh from the root each time, so an element a script
-- removed is never touched; a field's own text is the user's and not
-- read. -> {intact(), stop()}
local function guard_dialog(root, on_changed)
	local function picture()
		local m = getmetatable(root)
		if not m or m.dead or not m.unsafe then
			return nil
		end
		local out = {}
		local function walk(e, depth)
			local t = e:GetTypeName()
			local rec = {t, tostring(e:IsVisible()),
					string.format("%.3f", e:GetOpacity()), e:GetPriority(),
					e:GetNumChildren(false)}
			if depth >= 2 then
				-- The root fills the screen and the window is centred on
				-- it: those two move with a resize, what is in them does not
				local p = e:GetPosition()
				rec[#rec + 1] = p.x .. "," .. p.y
			end
			if depth >= 1 then
				rec[#rec + 1] = e:GetWidth() .. "x" .. e:GetHeight()
			end
			if t == "Text" then
				local c = e:GetColor(C_TOPLEFT)
				rec[#rec + 1] = string.format("%s %.2f,%.2f,%.2f,%.2f",
						e:GetText(), c.r, c.g, c.b, c.a)
			end
			out[#out + 1] = table.concat(rec, "|")
			if t == "LineEdit" then
				return
			end
			for i = 0, e:GetNumChildren(false) - 1 do
				walk(e:GetChild(i), depth + 1)
			end
		end
		walk(m.unsafe, 0)
		return table.concat(out, "\n")
	end
	local seen = nil  -- the picture once laid out
	local frames = 0
	local sub = nil
	local function stop()
		if sub then
			magic.UnsubscribeFromEvent("Update", sub)
			sub = nil
		end
	end
	sub = magic.SubscribeToEvent("Update", function()
		frames = frames + 1
		-- Laid out by then: a layout settles in the first frame or two
		if frames == 3 then
			seen = picture()
		elseif frames > 3 and picture() ~= seen then
			stop()
			on_changed()
		end
	end)
	return {
		intact = function() return seen ~= nil and picture() == seen end,
		stop = stop,
	}
end

-- Off the stack whatever was put over a dialog since: a script can push
-- a screen of its own on top, and pop() takes the top only
local function close_dialog(root)
	local st = uistack.main.stack
	if st[#st] == root then
		uistack.main:pop(root)
	else
		for _, e in ipairs(st) do
			if e == root then
				uistack.main:pop_to(root, true)
				break
			end
		end
	end
end

-- on_answer(accepted: boolean, description: string). suggested is the
-- caller's own description ([NET_DESC]): the field starts with it --
-- what the caller is asking for is what the caller knows -- editable,
-- and the accept or the decline is still the user's. An entry's own
-- description wins: that is what the user left there.
local function ask_user(server, uri, entry, on_answer, suggested)
	local answer
	local root = uistack.main:push({desc="network permission dialog"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "launch_menu/res/main_style.xml")
	-- Over whatever a server draws (a join window is at 100): the user has
	-- to see what they are asked
	root.priority = 1000

	local menu = ui_utils.vertical_menu(root, {min_width = 400})
	local window = menu.window

	local function add_text(text)
		local t = window:CreateChild("Text")
		t:SetStyleAuto()
		t.text = text
		t:SetTextAlignment(HA_LEFT)
		return t
	end

	-- **Who is asking** ([CONSENT_PER_SERVER]): the answer is that
	-- server's alone
	if server == "" then
		add_text("Buildat itself")
	elseif server:match("^local:") then
		add_text("Your local game "..server:sub(7))
	else
		add_text("A script of the server")
		add_text("  "..server)
	end
	add_text("wants to use the network:")
	add_text("  "..uri)
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
	-- Ctrl+C and Ctrl+V in the field, which Urho3D does itself ([NEW_WORLD_FORM])
	edit.textCopyable = true
	edit.textSelectable = true
	edit.minHeight = 24
	edit.minWidth = 380
	edit:SetText((entry and entry.description ~= "" and entry.description) or
			suggested or "")
	edit:SetFocus(true)

	local guard = guard_dialog(root, function()
		log:warning("The permission dialog for "..uri.." was changed "..
				"while it was up; declined")
		answer(false)
	end)

	local answered = false
	function answer(accepted)
		if answered then
			return
		end
		answered = true
		if accepted and not guard.intact() then
			log:warning("The permission dialog for "..uri.." was changed "..
					"while it was up; taken as declined")
			accepted = false
		end
		guard.stop()
		local description = edit:GetText()
		close_dialog(root)
		on_answer(accepted, description)
	end

	menu:add("Accept", function() answer(true) end)
	menu:add("Decline", function() answer(false) end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			answer(false)
			return true -- taken; the menu's own Escape = Back stands down
		end
	end)
end

-- **A file of <user>/exports, picked by the user** ([SECURITY_RUN_1]):
-- the folder holds what every server's game exported and whatever the
-- user put there, and a game listing and reading it all read another
-- server's exports. A game gets the one file the user picks here, the
-- web's file picker on native (buildat.safe.pick_file, client/api.lua).
-- Beside the network dialog for its guard. cb(name, data), or cb(nil,
-- why); accept is the end of a file's name (".fpplan"), "" for any.
-- simplified: every file is a row; a folder of hundreds wants a scroll
function M.pick_export(accept, cb)
	local root = uistack.main:push({desc="file picker"})
	root.defaultStyle = magic.cache:GetResource(
			"XMLFile", "launch_menu/res/main_style.xml")
	root.priority = 1000
	local menu = ui_utils.vertical_menu(root, {min_width = 400})
	local function add_text(text)
		local t = menu.window:CreateChild("Text")
		t:SetStyleAuto()
		t.text = text
		t:SetTextAlignment(HA_LEFT)
	end
	local guard
	local finished = false
	local function finish(name)
		if finished then
			return
		end
		finished = true
		if name and not guard.intact() then
			log:warning("The file picker was changed while it was up; "..
					"nothing picked")
			name = nil
		end
		guard.stop()
		close_dialog(root)
		if not name then
			return cb(nil, "no file picked")
		end
		log:info("The user picked "..name.." from the exports")
		local data, why = __buildat_read_exported(name)
		cb(data and name or nil, data or why)
	end
	add_text("A game asks for a file. Pick one from <user>/exports:")
	local files = __buildat_exported_files()
	table.sort(files)
	local any = false
	for _, f in ipairs(files) do
		if accept == "" or f:sub(-#accept) == accept then
			any = true
			menu:add(f, function() finish(f) end)
		end
	end
	if not any then
		add_text("(none" .. (accept ~= "" and " ending in " .. accept or "") ..
				")")
	end
	menu:add("Cancel", function() finish(nil) end)
	menu:on_key(function(key)
		if key == KEY_ESCAPE then
			finish(nil)
			return true
		end
	end)
	guard = guard_dialog(root, function()
		log:warning("The file picker was changed while it was up; closed")
		finish(nil)
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
local function connect(server, is_udp, host, port, cb, options)
	if type(host) ~= "string" or not tonumber(port) or type(cb) ~= "function" then
		error("network: connect(host: string, port: number, cb: function)")
	end
	local suggested = type(options) == "table" and
			type(options.description) == "string" and options.description or nil
	local uri = (is_udp and "udp://" or "tcp://")..host..":"..port
	local entry = load_store()[key(server, uri)]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(server, uri)
		open_socket(is_udp, host, port, cb)
		return
	end
	log:info("Asking the user about "..uri.." for \""..server.."\"")
	ask_user(server, uri, entry, function(accepted, description)
		store_answer(server, uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		open_socket(is_udp, host, port, cb)
	end, suggested)
end

function M.safe.tcp_connect(host, port, cb, options)
	connect(asking_server(), false, host, port, cb, options)
end

function M.safe.udp_connect(host, port, cb, options)
	connect(asking_server(), true, host, port, cb, options)
end

function M.tcp_connect(host, port, cb, options)
	connect("", false, host, port, cb, options)
end

function M.udp_connect(host, port, cb, options)
	connect("", true, host, port, cb, options)
end

-- http_get(url, cb): the body of a GET over HTTPS, cb(body) or
-- cb(nil, error), asked of the user through the same dialog and file as a
-- socket is -- the uri is the url's scheme and host ([SERVER_LIST]:
-- Luanti's official server list). Fetched on a thread in the client
-- (__buildat_http_get); read back on Update.
local http_pending = {}
local http_polling = false
-- **HTTPS through the server** ([STARPORT] 10c): the web client has no
-- HTTP of its own. Its server relays a TCP connection to a Starport it
-- announces to, and the TLS is this client's (Mbed TLS, __buildat_tls_*),
-- so the server carries bytes it cannot read. One request at a time.
-- BUILDAT_HTTP_RELAY=1 takes this way on a native client too, for a check.
-- simplified: for a Starport only, as the server relays to nothing else
local relay_queue = {}
local relay_busy = false
local relay_gen = 0
local ca_pem = nil

local function relay_next()
	if relay_busy or #relay_queue == 0 then
		return
	end
	relay_busy = true
	local job = table.remove(relay_queue, 1)
	-- The relay is one connection per peer, reused back to back. A finished
	-- connection's last relay_data/relay_closed can arrive after the next job
	-- has taken over the single packet handler; tag each job so the handler
	-- ignores what is not its own (else a prior call's "closed by the
	-- Starport" fails this one before its own response -- [WEB_ID_RELAY]).
	relay_gen = relay_gen + 1
	local gen = relay_gen
	local gen_hex = string.format("%08x", gen)
	local function done(body, err)
		relay_busy = false
		job.cb(body, err)
		relay_next()
	end
	if not __buildat_server_address() then
		return done(nil, "not connected to a server to relay through")
	end
	local scheme, host, port, path = job.url:match(
			"^(https?)://([^/:]+):?(%d*)(.*)$")
	if scheme ~= "https" then
		return done(nil, "the relay takes https only")
	end
	if not ca_pem then
		local f = io.open(__buildat_extension_path("network") ..
				"/ca-bundle.pem", "rb")
		ca_pem = f and f:read("*a") or ""
		if f then
			f:close()
		end
	end
	local h, err = __buildat_tls_new(host, ca_pem)
	if not h then
		return done(nil, err)
	end
	local origin = scheme .. "://" .. host .. (port ~= "" and ":" .. port or "")
	local request = (job.body and "POST " or "GET ") ..
			(path ~= "" and path or "/") .. " HTTP/1.1\r\n" ..
			"Host: " .. host .. "\r\n" ..
			"User-Agent: buildat (relay)\r\n" ..
			"Connection: close\r\n" ..
			(job.body and ("Content-Type: application/json\r\n" ..
			"Content-Length: " .. #job.body .. "\r\n") or "") ..
			"\r\n" .. (job.body or "")
	local sent_request = false
	local response = ""
	local finished = false
	-- The body of a whole response, or nil while more is to come
	local function parse(final)
		local head_end = response:find("\r\n\r\n", 1, true)
		if not head_end then
			return nil
		end
		local head = response:sub(1, head_end - 1)
		local rest = response:sub(head_end + 4)
		local status = tonumber(head:match("^HTTP/%d%.%d (%d+)"))
		local body = nil
		if head:lower():find("transfer%-encoding:%s*chunked") then
			local out, at = {}, 1
			while true do
				local line_end = rest:find("\r\n", at, true)
				if not line_end then
					break
				end
				local size = tonumber(rest:sub(at, line_end - 1):match(
						"^%x+"), 16)
				if not size then
					break
				end
				if size == 0 then
					body = table.concat(out)
					break
				end
				if #rest < line_end + 1 + size then
					break
				end
				out[#out + 1] = rest:sub(line_end + 2, line_end + 1 + size)
				at = line_end + 2 + size + 2
			end
		else
			local len = tonumber(head:lower():match(
					"content%-length:%s*(%d+)"))
			if len and #rest >= len then
				body = rest:sub(1, len)
			elseif final then
				body = rest
			end
		end
		if not body then
			return nil
		end
		return body, status
	end
	local function finish(body, why)
		if finished then
			return
		end
		finished = true
		log:info("relay " .. job.url .. ": " .. (why or ("ok, " .. #body ..
				" bytes")))
		__buildat_tls_free(h)
		buildat.send_packet("starport:relay_close", "")
		done(body, why)
	end
	local state_open = false
	local function pump(cipher_in)
		if finished then
			return
		end
		local out, plain, state = __buildat_tls_step(h, cipher_in or "",
				(state_open and not sent_request) and request or nil)
		if state_open and not sent_request then
			sent_request = true
		end
		if out ~= "" then
			buildat.send_packet("starport:relay_send", out)
		end
		response = response .. plain
		if state:sub(1, 6) == "error:" then
			return finish(nil, "TLS " .. state)
		end
		if state == "open" and not state_open then
			state_open = true
			return pump("")
		end
		local body, status = parse(state == "closed")
		if body then
			if status and status >= 200 and status < 300 then
				finish(body)
			else
				finish(nil, "HTTP " .. tostring(status))
			end
		elseif state == "closed" then
			finish(nil, "closed before a whole response")
		end
	end
	buildat.sub_packet("starport:relay_data", function(data)
		if data:sub(1, 8) ~= gen_hex then
			return
		end
		pump(data:sub(9))
	end)
	buildat.sub_packet("starport:relay_closed", function(why)
		if why:sub(1, 8) ~= gen_hex then
			return
		end
		why = why:sub(9)
		local body, status = parse(true)
		if body and status and status >= 200 and status < 300 then
			finish(body)
		else
			finish(nil, "relay: " .. tostring(why))
		end
	end)
	buildat.send_packet("starport:relay_open", gen_hex .. origin)
	pump("")
end

local function use_relay()
	return buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil or
			buildat.get_env("BUILDAT_HTTP_RELAY") == "1"
end

local function http_start(url, cb, body)
	if use_relay() then
		relay_queue[#relay_queue + 1] = {url = url, body = body, cb = cb}
		relay_next()
		return
	end
	local id = __buildat_http_get(url, body)
	http_pending[id] = cb
	if not http_polling then
		http_polling = true
		magic.SubscribeToEvent("Update", function()
			for jid, callback in pairs(http_pending) do
				local ok, body, redirect = __buildat_http_poll(jid)
				if ok ~= nil then
					http_pending[jid] = nil
					if ok then
						callback(body)
					else
						callback(nil, body, redirect)
					end
				end
			end
		end)
	end
end

-- The user's leave for the url's host, then the fetch: a GET, or with a
-- body a POST of JSON
local function gated_http(server, url, cb, options, body, hops)
	-- The authority is what libcurl connects to, so it is what the user is
	-- asked about, port included: a host and a port and nothing else. A
	-- `user@` part or a backslash was read as one host here and another
	-- by libcurl ([SECURITY_RUN_1]).
	local scheme, authority = url:match("^(https?)://([^/?#]*)")
	if not scheme or authority == "" or
			not authority:match("^[%w%.%-]+$") and
			not authority:match("^[%w%.%-]+:%d+$") and
			not authority:match("^%[[%x:%.]+%]$") and
			not authority:match("^%[[%x:%.]+%]:%d+$") then
		cb(nil, "not an http(s) url with a plain host: "..url)
		return
	end
	local uri = scheme.."://"..authority
	-- A redirect is the engine's to report and ours to follow, through
	-- this same gate: libcurl following it went to a host the user never
	-- saw ([SECURITY_RUN_1]). GETs only, 8 at most; a POST's is an error.
	local user_cb = cb
	cb = function(got, err, redirect)
		if got or not redirect or body or (hops or 0) >= 8 then
			return user_cb(got, err)
		end
		local to = redirect
		if not to:match("^https?://") then
			return user_cb(nil, "a redirect to "..to.." is not followed")
		end
		gated_http(server, to, user_cb, options, nil, (hops or 0) + 1)
	end
	local entry = load_store()[key(server, uri)]
	if entry and entry.accepted and
			os.time() - entry.last_attempt < ACCEPTANCE_VALID_S then
		touch_entry(server, uri)
		http_start(url, cb, body)
		return
	end
	log:info("Asking the user about "..uri.." for \""..server.."\"")
	ask_user(server, uri, entry, function(accepted, description)
		store_answer(server, uri, accepted, description, entry)
		if not accepted then
			cb(nil, "Declined by user: "..uri)
			return
		end
		http_start(url, cb, body)
	end, type(options) == "table" and options.description or nil)
end

local function http_get(server, url, cb, options)
	if type(url) ~= "string" or type(cb) ~= "function" then
		error("network: http_get(url: string, cb: function)")
	end
	gated_http(server, url, cb, options)
end
function M.safe.http_get(url, cb, options)
	http_get(asking_server(), url, cb, options)
end
function M.http_get(url, cb, options)
	http_get("", url, cb, options)
end

-- http_post(url, body, cb[, options]): http_get's, a POST of the JSON
-- `body` ([STARPORT]: a report)
local function http_post(server, url, body, cb, options)
	if type(url) ~= "string" or type(body) ~= "string" or
			type(cb) ~= "function" then
		error("network: http_post(url: string, body: string, cb: function)")
	end
	gated_http(server, url, cb, options, body)
end
function M.safe.http_post(url, body, cb, options)
	http_post(asking_server(), url, body, cb, options)
end
function M.http_post(url, body, cb, options)
	http_post("", url, body, cb, options)
end

-- The addresses this client has used, for a list to pick from: the
-- store's entries as {uri, description, created, last_attempt, accepted},
-- the last used first, an address once -- its last used row
-- simplified: an address another server's scripts were refused shows as
-- refused if that was the last asking; the list is the user's own, and
-- the consent is still asked per server.
function M.safe.known_addresses()
	local out = {}
	local latest = {}
	for _, e in pairs(load_store()) do
		local l = latest[e.uri]
		if not l or e.last_attempt > l.last_attempt then
			latest[e.uri] = e
		end
	end
	for uri, e in pairs(latest) do
		out[#out + 1] = {uri = uri, description = e.description or "",
				created = e.created or 0, last_attempt = e.last_attempt or 0,
				accepted = e.accepted and true or false, name = e.name or "",
				icon = e.icon or ""}
	end
	table.sort(out, function(a, b) return a.last_attempt > b.last_attempt end)
	return out
end

-- remember_server_icon(uri, sha): a native server's icon, which the
-- client kept under the cache at connect ([LAUNCH_WORLD] (4)); its row is
-- made if the address has none, the player having connected to it. The
-- trusted side's alone: a server's script must not name what a row wears.
function M.remember_server_icon(uri, sha)
	if type(uri) ~= "string" or not uri:match("^tcp://[%w%.%-:%[%]]+$") or
			type(sha) ~= "string" or not sha:match("^%x+$") or #sha ~= 64 then
		return false
	end
	local entries = load_store()
	local e = entries[key("", uri)]
	local now = os.time()
	if not e then
		e = {accepted = true, uri = uri, description = "", created = now,
				name = "", server = ""}
		entries[key("", uri)] = e
	end
	e.last_attempt = now
	e.icon = sha
	save_store(entries)
	return true
end

-- set_address_name(uri, name): the player name used on a server, kept on
-- its rows for the next connect screen; a uri with no row is ignored
function M.safe.set_address_name(uri, name)
	if type(uri) ~= "string" or type(name) ~= "string" or #name > 64 then
		return false
	end
	local entries = load_store()
	local found = false
	for _, e in pairs(entries) do
		if e.uri == uri then
			e.name = name
			found = true
		end
	end
	if found then
		save_store(entries)
	end
	return found
end

-- parse_json(text) -> table or nil, error: the module's own reader
-- (json.lua beside this file), which defines onto a `core` table
local parse_json, write_json
do
	local saved = rawget(_G, "core")
	rawset(_G, "core", {log = function(_, message) log:warning(message) end})
	dofile(__buildat_extension_path("network").."/json.lua")
	parse_json, write_json = core.parse_json, core.write_json
	rawset(_G, "core", saved)
end
function M.safe.parse_json(text)
	return parse_json(text, nil, true)
end
-- write_json(value[, styled]) -> text, or nil and why not; styled is
-- indented, for a file a person reads
function M.safe.write_json(value, styled)
	return write_json(value, styled == true)
end

-- LuaSocket's socket.gettime()
function M.safe.gettime()
	return buildat.get_time_us() / 1000000
end

M.gettime = M.safe.gettime
M.known_addresses = M.safe.known_addresses
M.set_address_name = M.safe.set_address_name
M.parse_json = M.safe.parse_json
M.write_json = M.safe.write_json

return M
-- vim: set noet ts=4 sw=4:
