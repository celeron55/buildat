-- Buildat: extension/network/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- TCP and UDP sockets for scripts, with the user in the loop: the first
-- connection or datagram to an address in a week needs the user to accept the
-- address and name it. Answers are remembered in
-- cache/network_addresses.csv.
--
--   local network = require("buildat/extension/network")
--   network.udp_connect("localhost", 30001, function(socket, err)
--       if not socket then log:error(err) return end
--       socket:send("hello")
--       local data = socket:receive() -- "" if nothing arrived yet
--   end)
--
-- The socket is connected to one peer; a UDP socket only receives datagrams
-- from the address it was opened for.

local log = buildat.Logger("extension/network")
local ui_utils = require("buildat/extension/ui_utils").safe
local uistack = require("buildat/extension/uistack")
local magic = require("buildat/extension/urho3d").safe
local M = {safe = {}}

local ACCEPTANCE_VALID_S = 7 * 24 * 3600

local store_path = __buildat_get_path("cache").."/network_addresses.csv"

-- Addresses this session has already notified about
local notified = {}

-- The store
--
-- CSV, because there are a handful of rows, they want to be readable and
-- editable by hand, and there is no schema to migrate. Every field is quoted so
-- that a description can contain a comma or a quote.

local csv = dofile(__buildat_extension_path("network").."/csv.lua")

-- uri -> {accepted=, uri=, description=, created=, last_attempt=}
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
	file:write("accepted,address,description,created,last_attempt\n")
	for _, uri in ipairs(uris) do
		local e = entries[uri]
		file:write(table.concat({
			csv.quote(e.accepted and "true" or "false"),
			csv.quote(e.uri),
			csv.quote(e.description),
			csv.quote(math.floor(e.created)),
			csv.quote(math.floor(e.last_attempt)),
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

-- Plain Lua wrapper; the socket object from C++ is not sandbox-safe, and this
-- is where the first-packet notification happens.
local function wrap_socket(socket, uri, is_udp)
	local function notify()
		if notified[uri] then
			return
		end
		notified[uri] = true
		ui_utils.show_notification("Connected to "..socket:address())
	end

	if not is_udp then
		notify()
	end

	local w = {}
	function w:send(data)
		local ok = socket:send(data)
		if ok then
			notify()
		end
		return ok
	end
	function w:receive()
		return socket:receive()
	end
	function w:good()
		return socket:good()
	end
	function w:error()
		return socket:error()
	end
	function w:address()
		return socket:address()
	end
	function w:close()
		socket:close()
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
	cb(wrap_socket(socket, (is_udp and "udp://" or "tcp://")..
			host..":"..port, is_udp))
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

M.tcp_connect = M.safe.tcp_connect
M.udp_connect = M.safe.udp_connect

return M
-- vim: set noet ts=4 sw=4:
