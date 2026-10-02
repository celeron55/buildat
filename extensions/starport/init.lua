-- Buildat: extensions/starport/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **The client's side of Starport** ([STARPORT] 4, 5, 5b, 5c;
-- doc/plan/starport_plan.md): the Starports this client asks, its key on
-- each, the filters and their lock, the list merged from all of them, and
-- reports with their receipts.
--
-- The safe half is what the connect screen (sandboxed) and any server's
-- Lua may call: fetch the list, and open this side's own dialogs. A
-- report and a setting are made only in those dialogs, which this side
-- draws, so a server's script cannot report in the player's name or turn
-- a filter off.
--
--   <user>/starport.json          the settings, the keys, the receipts
--   <user>/starport_keys.json     export and import of the keys (5c)
--   /etc/buildat/starport.json    the managed file (Windows:
--                                 %ProgramData%\buildat\starport.json;
--                                 BUILDAT_STARPORT_MANAGED overrides):
--                                 what it sets cannot be changed here
local log = buildat.Logger("extension/starport")
local network = require("buildat/extension/network")
local uistack = require("buildat/extension/uistack")
local magic = require("buildat/extension/urho3d").safe
local group = dofile(__buildat_extension_path("starport") .. "/group.lua")
local M = {safe = {}}

local DEFAULT_STARPORT = "https://starport.buildat.org"
local STATE_PATH = __buildat_get_path("user") .. "/starport.json"
local EXPORT_PATH = __buildat_get_path("user") .. "/starport_keys.json"
local STYLE = "launch_menu/res/main_style.xml"

local AUDIENCES = {"everyone", "teen", "adult"}
local KINDS = {"world", "arena", "app", "other"}
local ACCESSES = {"open", "registration", "invite", "password", "external"}
-- The last list each Starport gave, for when it cannot be reached
-- ([STARPORT] 4): {url = {ts, servers}}
local LIST_CACHE = __buildat_get_path("cache") .. "/starport_list.json"
-- A descriptor the filter can hide, and the values it hides at
local DESCRIPTORS = {
	{"violence", "realistic violence", {realistic = true}},
	{"chat", "unmoderated chat", {unmoderated = true}},
	{"ugc", "unmoderated content", {unmoderated = true}},
	{"language", "strong language", {yes = true}},
	{"sexual", "sexual content", {yes = true}},
	{"drugs", "drugs", {yes = true}},
	{"purchases", "purchases", {yes = true}},
	{"gambling", "gambling", {yes = true}},
	{"personal_data", "collects personal data", {yes = true}},
}
local REASONS = {
	{"category", "Wrong category or rating"},
	{"illegal", "Illegal content"},
	{"csam", "Child sexual abuse material"},
	{"harassment", "Harassment or abuse"},
	{"scam", "Scam, phishing or malware"},
	{"impersonation", "Impersonation"},
	{"spam", "Spam listing"},
	{"other", "Other"},
}

--
-- State
--

-- Everything an `everyone` audience and a teen one may see; adult hidden
-- until the user says they want it (a self-declared choice, not an age check)
local function default_filters()
	return {
		audience = {everyone = true, teen = true, adult = false},
		kind = {world = true, arena = true, app = true, other = true},
		access = {open = true, registration = true, invite = true,
			password = true, external = true},
		hide = {},
		languages = "",
	}
end

local function read_json(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local v = network.parse_json(text)
	return type(v) == "table" and v or nil
end

local function write_json_file(path, v)
	local text = assert(network.write_json(v))
	local f, err = io.open(path .. ".tmp", "wb")
	if not f then
		log:warning("Cannot write " .. path .. ": " .. tostring(err))
		return false
	end
	f:write(text)
	f:close()
	os.remove(path)
	return os.rename(path .. ".tmp", path)
end

local function managed_path()
	local env = buildat.get_env("BUILDAT_STARPORT_MANAGED")
	if env and env ~= "" then
		return env
	end
	local pd = os.getenv("ProgramData")
	if pd and pd ~= "" then
		return pd .. "\\buildat\\starport.json"
	end
	return "/etc/buildat/starport.json"
end

local state = nil

local function load_state()
	if state then
		return state
	end
	state = read_json(STATE_PATH) or {}
	state.starports = type(state.starports) == "table" and state.starports or
			{DEFAULT_STARPORT}
	state.filters = type(state.filters) == "table" and state.filters or
			default_filters()
	for k, v in pairs(default_filters()) do
		if state.filters[k] == nil then
			state.filters[k] = v
		elseif type(v) == "table" and type(state.filters[k]) == "table" then
			-- A value added since these were saved (access external) is
			-- the default's; a managed file's lists are taken as written
			for kk, vv in pairs(v) do
				if state.filters[k][kk] == nil then
					state.filters[k][kk] = vv
				end
			end
		end
	end
	if state.send_key == nil then
		state.send_key = true
	end
	if state.direct_connect == nil then
		state.direct_connect = true
	end
	state.keys = type(state.keys) == "table" and state.keys or {}
	state.receipts = type(state.receipts) == "table" and state.receipts or {}
	state.pin = state.pin or ""
	-- [STARPORT] 10: the Starport IDs logged in, by Starport: {session,
	-- name, band, key}
	state.ids = type(state.ids) == "table" and state.ids or {}
	return state
end

local function save_state()
	write_json_file(STATE_PATH, state)
end

-- The managed file's word over the user's, read every time: an
-- administrator's change counts without a restart
local function managed()
	return read_json(managed_path()) or {}
end

-- What is in effect: the user's settings, under the managed file's
local function effective()
	local s, m = load_state(), managed()
	local filters = s.filters
	if type(m.filters) == "table" then
		-- What the file leaves out is the default's, not the user's
		filters = default_filters()
		for k, v in pairs(m.filters) do
			filters[k] = v
		end
	end
	return {
		starports = type(m.starports) == "table" and m.starports or
				s.starports,
		filters = filters,
		direct_connect = (m.direct_connect == nil) and s.direct_connect or
				m.direct_connect == true,
		send_key = s.send_key,
		managed = {starports = m.starports ~= nil, filters = m.filters ~= nil,
			direct_connect = m.direct_connect ~= nil},
	}
end

local function hex(bytes)
	return (bytes:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end))
end

-- simplified: the PIN as an unsalted SHA-256; a four-digit PIN is found
-- by trying them all whatever the hash, and the lock is the client's
-- only ([STARPORT] 4 says so to the user)
local function pin_hash(pin)
	return hex(buildat.sha256("buildat starport pin:" .. pin))
end

-- This client's key on a Starport, made the first time it is needed
local function key_for(url)
	local s = load_state()
	-- [STARPORT] 10a: an ID holds the key, and logging in brings it
	local id = s.ids and s.ids[url]
	if id and type(id.key) == "string" and #id.key == 64 then
		return id.key
	end
	if not s.keys[url] then
		s.keys[url] = hex(buildat.random_bytes(32))
		save_state()
	end
	return s.keys[url]
end

--
-- The list
--

local last_rows = {}

-- The last fetch's row of an address
local function row_of(address)
	for _, x in ipairs(last_rows) do
		if x.address == address then
			return x
		end
	end
	return nil
end

-- Whether the filters let a listing through
-- [STARPORT] 10b: the youngest band of the IDs logged in caps what is
-- shown: under 13 sees `everyone`, 13 to 17 also `teen`
local function band_allows(audience)
	local s = load_state()
	for _, id in pairs(s.ids or {}) do
		-- Not said yet counts as the youngest
		if (id.band == "under 13" or id.band == "not said") and
				audience ~= "everyone" then
			return false
		end
		if id.band == "13-17" and audience == "adult" then
			return false
		end
	end
	return true
end

local function passes(f, x)
	if not f.audience[x.audience] or not f.kind[x.kind] or
			not f.access[x.access] or not band_allows(x.audience) then
		return false
	end
	for _, d in ipairs(DESCRIPTORS) do
		-- A server whose version does not know a descriptor says
		-- "unknown", which a filter hiding it hides too ([STARPORT] 3)
		local v = (x.descriptors or {})[d[1]] or "unknown"
		if f.hide[d[1]] and (d[3][v] or v == "unknown") then
			return false
		end
	end
	if f.languages ~= "" then
		local want = {}
		for l in f.languages:gmatch("[^,%s]+") do
			want[l:lower()] = true
		end
		local any = false
		for _, l in ipairs(x.languages or {}) do
			any = any or want[tostring(l):lower()] or false
		end
		if not any then
			return false
		end
	end
	-- A listing a moderator hid is left out of a filtered view: any
	-- filter that hides something
	if x.restricted then
		for _, a in ipairs(AUDIENCES) do
			if not f.audience[a] then
				return false
			end
		end
	end
	return true
end

-- simplified: one server on two Starports is one row by its address; its
-- listings there are separate keys, as each Starport made its own secret
local function merge(by_starport)
	local rows, at = {}, {}
	for _, pair in ipairs(by_starport) do
		local url, servers = pair[1], pair[2]
		for _, x in ipairs(servers) do
			if type(x) == "table" and x.host and x.port then
				local addr = tostring(x.host) .. ":" .. tostring(x.port)
				local row = at[addr]
				if not row then
					row = {}
					for k, v in pairs(x) do
						row[k] = v
					end
					row.address = addr
					row.ids = {}
					row.starports = {}
					at[addr] = row
					rows[#rows + 1] = row
				end
				row.ids[url] = x.id
				row.starports[#row.starports + 1] = url:gsub("^%a+://", "")
			end
		end
	end
	table.sort(rows, function(a, b)
		return (tonumber(a.players) or 0) > (tonumber(b.players) or 0)
	end)
	return rows
end

-- The outcome of this client's open reports, asked of each Starport by
-- the key that made them
local function poll_receipts()
	local s = load_state()
	if not s.send_key then
		return
	end
	local by_url = {}
	for _, r in ipairs(s.receipts) do
		if r.state ~= "upheld" and r.state ~= "rejected" and r.keyed then
			by_url[r.starport] = by_url[r.starport] or {}
			table.insert(by_url[r.starport], r.receipt)
		end
	end
	for url, ids in pairs(by_url) do
		network.http_post(url .. "/api/report_status", network.write_json(
				{key = key_for(url), receipts = ids}), function(body)
			local v = body and network.parse_json(body)
			if type(v) ~= "table" or type(v.reports) ~= "table" then
				return
			end
			for _, o in ipairs(v.reports) do
				for _, r in ipairs(s.receipts) do
					if r.receipt == o.receipt and r.starport == url then
						r.state, r.outcome = o.state, o.outcome
					end
				end
			end
			save_state()
		end, {description = "Starport"})
	end
end

-- Whether the network extension has the user's yes for a url's host
local function accepted(url)
	local origin = url:match("^(https?://[^/:]+)")
	for _, a in ipairs(network.known_addresses()) do
		if a.uri == origin and a.accepted then
			return true
		end
	end
	return false
end

-- fetch(cb[, ask]): cb(rows, info) once every Starport has answered or
-- failed; rows the merged list the filters let through, info {hidden = n,
-- unasked = n, errors = {"url: why", ...}}. Without `ask`, a Starport
-- whose host the user has not accepted yet is left out rather than put
-- in front of them as a permission dialog (as extensions/serverlist does)
function M.safe.fetch(cb, ask)
	local e = effective()
	local urls, unasked = {}, 0
	for _, url in ipairs(e.starports) do
		if ask or accepted(url) then
			urls[#urls + 1] = url
		else
			unasked = unasked + 1
		end
	end
	local results, errors, waiting = {}, {}, #urls
	local kept = read_json(LIST_CACHE) or {}
	-- The oldest kept list shown, in seconds; 0 when all are fresh
	local stale = 0
	local function use_kept(url)
		local k = kept[url]
		if type(k) == "table" and type(k.servers) == "table" then
			results[url] = k.servers
			stale = math.max(stale, os.time() - (tonumber(k.ts) or 0))
		end
	end
	-- One not asked yet shows what it said last time
	for _, url in ipairs(e.starports) do
		if not (ask or accepted(url)) then
			use_kept(url)
		end
	end
	if waiting == 0 then
		local ordered = {}
		for _, url in ipairs(e.starports) do
			if results[url] then
				ordered[#ordered + 1] = {url, results[url]}
			end
		end
		last_rows = merge(ordered)
		local shown, hidden = {}, 0
		for _, row in ipairs(last_rows) do
			if passes(e.filters, row) then
				local copy = {}
				for k, v in pairs(row) do
					copy[k] = v
				end
				shown[#shown + 1] = copy
			else
				hidden = hidden + 1
			end
		end
		cb(shown, {hidden = hidden, unasked = unasked, stale = stale,
				errors = #e.starports == 0 and
				{"No Starports in the settings"} or {}})
		return
	end
	local function done()
		waiting = waiting - 1
		if waiting > 0 then
			return
		end
		-- In the settings' order, whichever answered first
		local ordered = {}
		for _, url in ipairs(e.starports) do
			if results[url] then
				ordered[#ordered + 1] = {url, results[url]}
			end
		end
		write_json_file(LIST_CACHE, kept)
		last_rows = merge(ordered)
		local shown, hidden = {}, 0
		for _, row in ipairs(last_rows) do
			if passes(e.filters, row) then
				local copy = {}
				for k, v in pairs(row) do
					copy[k] = v
				end
				shown[#shown + 1] = copy
			else
				hidden = hidden + 1
			end
		end
		cb(shown, {hidden = hidden, unasked = unasked, stale = stale,
				errors = errors})
		poll_receipts()
	end
	for _, url in ipairs(urls) do
		local function got(body, err)
			local v = body and network.parse_json(body)
			if type(v) == "table" and v.ok and type(v.servers) == "table" then
				results[url] = v.servers
				kept[url] = {ts = os.time(), servers = v.servers}
			else
				errors[#errors + 1] = url .. ": " .. tostring(
						type(v) == "table" and v.error or err or "no answer")
				use_kept(url)
			end
			done()
		end
		local options = {description = "Starport (server list)"}
		if e.send_key then
			network.http_post(url .. "/api/list", network.write_json(
					{key = key_for(url)}), got, options)
		else
			network.http_get(url .. "/api/list", got, options)
		end
	end
end

-- Whether a server may be connected to by a typed address
function M.safe.direct_connect_allowed()
	return effective().direct_connect
end

--
-- Dialogs: this side's own, so only the player fills them in
--

local function open_window(desc, width)
	local root = uistack.main:push({desc = desc})
	root.defaultStyle = magic.cache:GetResource("XMLFile", STYLE)
	local w = root:CreateChild("Window")
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(12, 12, 12, 12))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w:SetFixedWidth(math.min(width, magic.ui.root.width - 16))
	-- Over whatever a server draws (its join window is at 100): this
	-- side's dialogs are the ones the player has to be able to trust
	root.priority = 1000
	root:SubscribeToStackEvent("KeyDown", function(_, data)
		if data:GetInt("Key") == magic.KEY_ESCAPE then
			uistack.main:pop(root)
			return true
		end
	end)
	return root, w
end

local function add_text(parent, text, color)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t.text = text
	if color then
		t.color = color
	end
	return t
end

-- A label in a row: one line, at least min_width wide
local function add_label(parent, text, min_width)
	local t = add_text(parent, text)
	t:SetWordwrap(false)
	t.minWidth = min_width or 0
	return t
end

local function add_row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

local function add_button(parent, label, on_click, enabled)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 24
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t.text = label
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 16
	if enabled == false then
		t.color = magic.Color(0.5, 0.5, 0.5)
	else
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	return b
end

local function add_edit(parent, value, secret)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 24
	e.minWidth = 200
	e.textSelectable = true
	if secret then
		e.echoCharacter = string.byte("*")
	else
		e.textCopyable = true
	end
	e:SetText(value or "")
	return e
end

local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)

local settings_page
local settings_root = nil

-- The PIN, when one is set, before anything the lock covers is changed
local function ask_pin(on_done)
	local s = load_state()
	if s.pin == "" then
		on_done(true)
		return
	end
	local root, w = open_window("starport pin", 420)
	add_text(w, "These settings are locked with a PIN.")
	local e = add_edit(w, "", true)
	e:SetFocus(true)
	local function go(try)
		local ok = try and pin_hash(e:GetText()) == s.pin
		uistack.main:pop(root)
		on_done(ok)
	end
	magic.SubscribeToEvent(e, "TextFinished", function() go(true) end)
	local r = add_row(w)
	add_button(r, "Unlock", function() go(true) end)
	add_button(r, "View only", function() go(false) end)
end

local function toggle_row(w, label, set, values, can)
	local r = add_row(w)
	add_label(r, label, 90)
	for _, v in ipairs(values) do
		local name, shown = v, v
		if type(v) == "table" then
			name, shown = v[1], v[2]
		end
		add_button(r, (set[name] and "[x] " or "[ ] ") .. shown, function()
			set[name] = not set[name]
			save_state()
			settings_page(can, true)
		end, can)
	end
end

-- can: the PIN was given (or there is none); `again`: redrawn in place
settings_page = function(can, again, message)
	if again and settings_root then
		uistack.main:pop(settings_root)
	end
	local s, e = load_state(), effective()
	local root, w = open_window("starport settings", 900)
	settings_root = root
	add_text(w, "Starport: the lists of public servers")
	if message then
		add_text(w, message, YELLOW)
	end
	if e.managed.starports or e.managed.filters or e.managed.direct_connect then
		add_text(w, "Some of these are set by " .. managed_path() ..
				" and cannot be changed here.", GREY)
	end
	local lock_starports = can and not e.managed.starports
	for i, url in ipairs(e.starports) do
		local r = add_row(w)
		add_label(r, url, 360)
		-- [STARPORT] 10: this Starport's ID, or the way to one
		local id = s.ids[url]
		add_button(r, id and "ID: " .. tostring(id.name) .. "..." or
				"Starport ID...", function()
			if id then
				M.id_page(url)
			else
				M.id_login(url)
			end
		end)
		add_button(r, "Remove", function()
			table.remove(s.starports, i)
			save_state()
			settings_page(can, true)
		end, lock_starports)
	end
	local r = add_row(w)
	local new = add_edit(r, "https://")
	add_button(r, "Add Starport", function()
		local url = new:GetText():gsub("/+$", "")
		if not url:match("^https?://[%w%.%-]+[:%d]*$") then
			return settings_page(can, true, "A Starport is an https:// address")
		end
		table.insert(s.starports, url)
		save_state()
		settings_page(can, true)
	end, lock_starports)

	add_text(w, "Show servers:")
	local fc = can and not e.managed.filters
	local f = e.filters
	toggle_row(w, "Audience", f.audience, AUDIENCES, fc)
	toggle_row(w, "Kind", f.kind, KINDS, fc)
	toggle_row(w, "Access", f.access, ACCESSES, fc)
	local hides = {}
	for _, d in ipairs(DESCRIPTORS) do
		hides[#hides + 1] = {d[1], d[2]}
	end
	toggle_row(w, "Hide", f.hide, {hides[1], hides[2], hides[3]}, fc)
	toggle_row(w, "", f.hide, {hides[4], hides[5], hides[6]}, fc)
	toggle_row(w, "", f.hide, {hides[7], hides[8], hides[9]}, fc)
	r = add_row(w)
	add_label(r, "Languages (en, fi; empty: all)", 240)
	local langs = add_edit(r, f.languages)
	add_button(r, "Set", function()
		f.languages = langs:GetText()
		save_state()
		settings_page(can, true)
	end, fc)
	add_button(w, "Connecting by a typed address: " ..
			(e.direct_connect and "allowed" or "not allowed"), function()
		s.direct_connect = not s.direct_connect
		save_state()
		settings_page(can, true)
	end, can and not e.managed.direct_connect)

	-- 2b: a pool's server in the same region goes first
	r = add_row(w)
	add_label(r, "My region (e.g. eu)", 240)
	local region = add_edit(r, s.region or "")
	add_button(r, "Set", function()
		s.region = region:GetText()
		save_state()
		settings_page(can, true)
	end)
	-- 5b
	add_button(w, "Send my Starport key: " .. (s.send_key and "on" or "off"),
			function()
		s.send_key = not s.send_key
		save_state()
		settings_page(can, true)
	end)
	add_text(w, (s.send_key and
			"Your key builds the standing your reports are weighed by, and "..
			"brings you their outcomes." or
			"Off: your key is not sent, so Starports keep nothing new of "..
			"your use; your reports weigh as a new key's and get no "..
			"outcomes. The key is kept: turned on again, it is sent with "..
			"its standing as it was."), GREY)
	if not s.send_key then
		add_text(w, "The keys are in " .. STATE_PATH .. " (\"keys\"). "..
				"Deleting them there starts over with new ones.", GREY)
	end
	-- 5c
	r = add_row(w)
	add_button(r, "Export keys", function()
		write_json_file(EXPORT_PATH, {what = "Buildat Starport keys. "..
			"Whoever has this file reports as you.", keys = s.keys})
		settings_page(can, true, "Saved to " .. EXPORT_PATH)
	end)
	add_button(r, "Import keys", function()
		local v = read_json(EXPORT_PATH)
		if not v or type(v.keys) ~= "table" then
			return settings_page(can, true, "Nothing to import at " ..
					EXPORT_PATH)
		end
		local n = 0
		for url, k in pairs(v.keys) do
			if type(k) == "string" and k:match("^%x+$") and #k == 64 then
				s.keys[url] = k:lower()
				n = n + 1
			end
		end
		save_state()
		settings_page(can, true, n .. " key(s) imported from " .. EXPORT_PATH)
	end)

	-- The lock
	r = add_row(w)
	add_label(r, s.pin ~= "" and "PIN: set" or "PIN: none", 90)
	local pin = add_edit(r, "", true)
	add_button(r, s.pin ~= "" and "Change PIN" or "Set PIN", function()
		local p = pin:GetText()
		if #p < 4 then
			return settings_page(can, true, "A PIN of at least 4 characters")
		end
		s.pin = pin_hash(p)
		save_state()
		settings_page(can, true, "PIN set")
	end, can)
	add_button(r, "Remove PIN", function()
		s.pin = ""
		save_state()
		settings_page(can, true)
	end, can and s.pin ~= "")
	add_text(w, "The lock covers this client only: not someone with the "..
			"computer's administrator rights.", GREY)

	if #s.receipts > 0 then
		add_text(w, "Your reports:")
		for i = #s.receipts, math.max(1, #s.receipts - 4), -1 do
			local x = s.receipts[i]
			add_text(w, x.name .. ": " .. x.reason .. ": " ..
					(x.outcome and x.outcome ~= "" and x.outcome or
					x.state or "sent"), GREY)
		end
	end
	add_button(w, "Back", function() uistack.main:pop(root) end)
end

--
-- **Starport ID** ([STARPORT] 10): logging in, registering and the account,
-- over the Starport's HTTPS API (POST /api/id/<call>). The password goes to
-- the Starport only; a server gets a token for itself (id_token_here).
--

local function id_call(url, what, body, cb)
	network.http_post(url .. "/api/id/" .. what, network.write_json(body),
			function(answer, err)
		local v = answer and network.parse_json(answer)
		if type(v) ~= "table" then
			cb(nil, tostring(err or "no answer"))
		elseif not v.ok then
			-- A session that ended is forgotten here too
			if v.error == "session" then
				load_state().ids[url] = nil
				save_state()
			end
			cb(nil, tostring(v.error))
		else
			cb(v.result)
		end
	end, {description = "Starport"})
end

-- What is kept of a logged-in ID: enough to log in to servers and to cap
-- the filters, nothing a server should see
local function keep_id(url, session, me)
	local s = load_state()
	s.ids[url] = {session = session, name = me.name, band = me.band,
		key = me.key}
	save_state()
end

local function id_refresh(url, cb)
	local id = load_state().ids[url]
	if not id then
		return cb(nil, "not logged in")
	end
	id_call(url, "me", {session = id.session}, function(me, err)
		if me then
			keep_id(url, id.session, me)
		end
		cb(me, err)
	end)
end

local function close_and(root, f)
	return function()
		uistack.main:pop(root)
		if f then
			f()
		end
	end
end

-- id_login(url[, then_cb]): the login dialog; then_cb() once logged in
function M.id_login(url, then_cb, message)
	local root, w = open_window("starport id login", 520)
	add_text(w, "Starport ID at " .. url)
	if message then
		add_text(w, message, YELLOW)
	end
	local r = add_row(w)
	add_label(r, "Name", 120)
	local name = add_edit(r, "")
	r = add_row(w)
	add_label(r, "Password", 120)
	local password = add_edit(r, "", true)
	local totp_row = add_row(w)
	add_label(totp_row, "TOTP code (if on)", 120)
	local totp = add_edit(totp_row, "")
	local status = add_text(w, "")
	local function go()
		status.text = "Logging in..."
		id_call(url, "login", {name = name:GetText(),
			password = password:GetText(), totp = totp:GetText()},
				function(res, err)
			if not res then
				status.text = err == "totp" and
						"Enter the code from your authenticator app" or err
				return
			end
			keep_id(url, res.session, res.me)
			uistack.main:pop(root)
			if res.remind_email then
				M.id_page(url, "This ID has no recovery e-mail: a forgotten "..
						"password is the end of it. You can add one here.")
			elseif then_cb then
				then_cb()
			end
		end)
	end
	magic.SubscribeToEvent(password, "TextFinished", go)
	magic.SubscribeToEvent(totp, "TextFinished", go)
	r = add_row(w)
	add_button(r, "Log in", go)
	add_button(r, "Make an ID...", function()
		uistack.main:pop(root)
		M.id_register(url, then_cb)
	end)
	add_button(r, "Forgot password...", function()
		uistack.main:pop(root)
		M.id_reset(url, name:GetText())
	end)
	add_button(r, "Close", close_and(root))
	name:SetFocus(true)
end

function M.id_reset(url, name_text)
	local root, w = open_window("starport id reset", 520)
	add_text(w, "A new password: a code goes to the ID's recovery e-mail.")
	local r = add_row(w)
	add_label(r, "Name", 120)
	local name = add_edit(r, name_text or "")
	local status = add_text(w, "")
	add_button(w, "Send the code", function()
		id_call(url, "reset_request", {name = name:GetText()},
				function(res, err)
			status.text = res or err
		end)
	end)
	r = add_row(w)
	add_label(r, "Code", 120)
	local code = add_edit(r, "")
	r = add_row(w)
	add_label(r, "New password", 120)
	local pw = add_edit(r, "", true)
	r = add_row(w)
	add_button(r, "Set the password", function()
		id_call(url, "reset", {name = name:GetText(), code = code:GetText(),
			password = pw:GetText()}, function(res, err)
			if res then
				uistack.main:pop(root)
				M.id_login(url, nil, "Password set: log in with it")
			else
				status.text = err
			end
		end)
	end)
	add_button(r, "Close", close_and(root))
end

-- The age, as 10b has it: "18 or over" and nothing more, or a birth year
-- and, under 13, a parent's consent. Under the lock (4): a PIN set, the
-- PIN first
local function age_rows(w)
	local age = {adult = nil, year = "", consent = false}
	local r = add_row(w)
	add_label(r, "Are you 18 or over?", 200)
	local yes, no
	local year_row, consent_b
	local function draw()
		yes:GetChild(0).text = (age.adult == true and "[x]" or "[ ]") .. " Yes"
		no:GetChild(0).text = (age.adult == false and "[x]" or "[ ]") .. " No"
		year_row.visible = age.adult == false
		consent_b.visible = age.adult == false
		consent_b:GetChild(0).text = (age.consent and "[x]" or "[ ]") ..
				" Under 13: I have a parent's consent"
	end
	yes = add_button(r, "Yes", function() age.adult = true draw() end)
	no = add_button(r, "No", function() age.adult = false draw() end)
	year_row = add_row(w)
	add_label(year_row, "Birth year", 200)
	local year = add_edit(year_row, "")
	consent_b = add_button(w, "", function()
		age.consent = not age.consent
		draw()
	end)
	draw()
	return function()
		if age.adult == nil then
			return nil, "Say whether you are 18 or over"
		end
		if age.adult then
			return {adult = true}
		end
		local y = tonumber(year:GetText())
		if not y then
			return nil, "The year you were born"
		end
		return {adult = false, birth_year = y, consent = age.consent}
	end
end

function M.id_register(url, then_cb)
	ask_pin(function(can)
		if not can then
			return
		end
		local root, w = open_window("starport id register", 640)
		add_text(w, "A Starport ID at " .. url)
		-- 10a: what it holds, said where it is made
		add_text(w, "It holds: a name, a password (as a hash), a recovery "..
				"e-mail if you give one, \"18 or over\" or a birth year under "..
				"that, a parent's consent under 13, how many times you have "..
				"logged in, your report key, and a separate identity for "..
				"each community you join. That is all, on purpose: it is "..
				"made for privacy, and nothing more is asked or kept than "..
				"logging in, the age limits and moderation need.", GREY)
		local r = add_row(w)
		add_label(r, "Name", 200)
		local name = add_edit(r, "")
		r = add_row(w)
		add_label(r, "Password", 200)
		local pw = add_edit(r, "", true)
		r = add_row(w)
		add_label(r, "Password again", 200)
		local pw2 = add_edit(r, "", true)
		r = add_row(w)
		add_label(r, "Recovery e-mail (optional)", 200)
		local email = add_edit(r, "")
		add_text(w, "Without one, a forgotten password is the end of the ID "..
				"and its standing. You can add it later.", GREY)
		local get_age = age_rows(w)
		local status = add_text(w, "")
		r = add_row(w)
		add_button(r, "Make the ID", function()
			if pw:GetText() ~= pw2:GetText() then
				status.text = "The passwords differ"
				return
			end
			local a, why = get_age()
			if not a then
				status.text = why
				return
			end
			local body = {name = name:GetText(), password = pw:GetText(),
				email = email:GetText(), adult = a.adult,
				birth_year = a.birth_year, consent = a.consent,
				-- The key this client has used there: its standing comes
				key = load_state().keys[url]}
			status.text = "Making it..."
			id_call(url, "register", body, function(res, err)
				if not res then
					status.text = err
					return
				end
				keep_id(url, res.session, res.me)
				uistack.main:pop(root)
				if then_cb then
					then_cb()
				else
					M.id_page(url, res.email_error)
				end
			end)
		end)
		add_button(r, "Close", close_and(root))
	end)
end

-- The ID's own page: e-mail, TOTP, password, age, log out, delete
function M.id_page(url, message)
	id_refresh(url, function(me, err)
		local root, w = open_window("starport id", 680)
		if not me then
			add_text(w, "Starport ID at " .. url .. ": " .. tostring(err))
			add_button(w, "Log in...", function()
				uistack.main:pop(root)
				M.id_login(url)
			end)
			add_button(w, "Close", close_and(root))
			return
		end
		local function again(text)
			uistack.main:pop(root)
			M.id_page(url, text)
		end
		local session = load_state().ids[url].session
		add_text(w, "Starport ID " .. me.name .. " at " .. url .. " (age " ..
				me.band .. ", " .. me.logins .. " logins)")
		if message and message ~= "" then
			add_text(w, message, YELLOW)
		end
		for _, st in ipairs(me.statements or {}) do
			add_text(w, tostring(st.action) .. " for " .. tostring(st.reason) ..
					": " .. tostring(st.text), YELLOW)
		end
		-- The e-mail
		local r = add_row(w)
		add_label(r, "Recovery e-mail", 160)
		local email = add_edit(r, me.email_pending ~= "" and me.email_pending
				or me.email)
		add_button(r, "Set", function()
			id_call(url, "email", {session = session, email = email:GetText()},
					function(res, e2)
				again(res == "sent" and "A code went to the address" or
						res and "Set" or e2)
			end)
		end)
		if me.email_pending ~= "" then
			r = add_row(w)
			add_label(r, "Code from the mail", 160)
			local code = add_edit(r, "")
			add_button(r, "Confirm", function()
				id_call(url, "confirm_email", {session = session,
					code = code:GetText()}, function(res, e2)
					again(res and "Confirmed" or e2)
				end)
			end)
		end
		-- TOTP
		r = add_row(w)
		add_label(r, me.totp and "TOTP: on" or "TOTP: off", 160)
		local code = add_edit(r, "")
		if me.totp then
			add_button(r, "Turn off (code)", function()
				id_call(url, "totp", {session = session, cmd = "off",
					code = code:GetText()}, function(res, e2)
					again(res and "TOTP is off" or e2)
				end)
			end)
		else
			add_button(r, "Turn on...", function()
				id_call(url, "totp", {session = session, cmd = "begin"},
						function(res, e2)
					if not res then
						return again(e2)
					end
					uistack.main:pop(root)
					local root2, w2 = open_window("starport id totp", 620)
					add_text(w2, "Add this key to an authenticator app, then "..
							"enter the code it shows:")
					local k = add_edit(w2, res.secret)
					k.minWidth = 400
					add_text(w2, res.uri, GREY)
					local c = add_edit(w2, "")
					local rr = add_row(w2)
					add_button(rr, "Turn on", function()
						id_call(url, "totp", {session = session,
							cmd = "confirm", code = c:GetText()},
								function(res2, e3)
							uistack.main:pop(root2)
							M.id_page(url, res2 and "TOTP is on" or e3)
						end)
					end)
					add_button(rr, "Close", close_and(root2))
				end)
			end)
		end
		-- The password
		r = add_row(w)
		add_label(r, "Password: old, new", 160)
		local old = add_edit(r, "", true)
		local new = add_edit(r, "", true)
		add_button(r, "Change", function()
			id_call(url, "password", {session = session, old = old:GetText(),
				new = new:GetText()}, function(res, e2)
				again(res and "Password changed" or e2)
			end)
		end)
		-- The age, under the lock
		add_button(w, "Change the age...", function()
			ask_pin(function(can)
				if not can then
					return
				end
				uistack.main:pop(root)
				local root2, w2 = open_window("starport id age", 560)
				local get_age = age_rows(w2)
				local st = add_text(w2, "")
				local rr = add_row(w2)
				add_button(rr, "Save", function()
					local a, why = get_age()
					if not a then
						st.text = why
						return
					end
					a.session = session
					id_call(url, "age", a, function(res, e3)
						uistack.main:pop(root2)
						M.id_page(url, res and "Saved" or e3)
					end)
				end)
				add_button(rr, "Close", close_and(root2))
			end)
		end)
		r = add_row(w)
		add_button(r, "Log out", function()
			id_call(url, "logout", {session = session}, function() end)
			load_state().ids[url] = nil
			save_state()
			uistack.main:pop(root)
		end)
		local dpw = add_edit(r, "", true)
		add_button(r, "Delete the ID (password)", function()
			id_call(url, "delete", {session = session,
				password = dpw:GetText()}, function(res, e2)
				if res then
					load_state().ids[url] = nil
					save_state()
					uistack.main:pop(root)
				else
					again(e2)
				end
			end)
		end)
		add_button(w, "Close", close_and(root))
	end)
end

-- id_token_here(cb): a token for the server this client is on, from the
-- Starport ID of a Starport that lists it ([STARPORT] 10c); cb(token) or
-- cb(nil, why). The name used in the server's community is asked the
-- first time, in this side's own dialog.
function M.safe.id_token_here(cb)
	local address = __buildat_server_address()
	if not address then
		return cb(nil, "not connected")
	end
	local function with_row(row)
		if not row then
			return cb(nil, address .. " is not listed on your Starports")
		end
		local s = load_state()
		local url, listing = nil, nil
		for u, l in pairs(row.ids) do
			if s.ids[u] then
				url, listing = u, l
			end
		end
		if not url then
			-- Not logged in to any of them: the first one's login
			for u, l in pairs(row.ids) do
				url, listing = u, l
			end
			return M.id_login(url, function() M.safe.id_token_here(cb) end)
		end
		local function ask(name)
			id_call(url, "token", {session = s.ids[url].session,
				listing = listing, name = name}, function(res, err)
				if not res then
					if err == "session" then
						return M.id_login(url, function()
							M.safe.id_token_here(cb)
						end, "Log in again")
					end
					return cb(nil, err)
				end
				if res.need_name then
					local root, w = open_window("starport id name", 520)
					add_text(w, "The name to use in " .. tostring(
							type(row.fleet) == "table" and row.fleet.name or
							row.name) .. ". Only this community sees it; "..
							"others do not see which name you use here.")
					local e = add_edit(w, res.suggest or "")
					local rr = add_row(w)
					add_button(rr, "Use it", function()
						local n = e:GetText()
						uistack.main:pop(root)
						ask(n)
					end)
					add_button(rr, "Cancel", close_and(root, function()
						cb(nil, "cancelled")
					end))
					return
				end
				cb(res.token)
			end)
		end
		ask(nil)
	end
	local row = row_of(address)
	if row then
		with_row(row)
	else
		M.safe.fetch(function() with_row(row_of(address)) end, true)
	end
end

-- open_settings(): the settings dialog, behind the PIN where one is set
function M.safe.open_settings()
	ask_pin(function(ok)
		settings_page(ok)
	end)
end

-- Base64, for the evidence a report carries in its JSON
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function base64(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local q = {}
		for k = 4, 1, -1 do
			q[k] = n % 64 + 1
			n = math.floor(n / 64)
		end
		out[#out + 1] = B64:sub(q[1], q[1]) .. B64:sub(q[2], q[2]) ..
				(b and B64:sub(q[3], q[3]) or "=") ..
				(c and B64:sub(q[4], q[4]) or "=")
	end
	return table.concat(out)
end
assert(base64("Ma") == "TWE=" and base64("Man") == "TWFu" and
		base64("M") == "TQ==")

local MAX_EVIDENCE = 48 * 1024

-- **The evidence**: the newest screenshot the player took in the last ten
-- minutes (the screenshot key, before opening the report), made small
-- enough for a report. -> base64 JPEG and the file's name, or nil and why
-- simplified: found by trying the names the client gives a screenshot,
-- second by second, as there is no directory listing here; one taken
-- twice in a second is found by its first name only
local function latest_screenshot_evidence()
	local dir = __buildat_get_path("user") .. "/screenshots/"
	local now = os.time()
	local path, name = nil, nil
	for t = now, now - 600, -1 do
		local n = os.date("screenshot_%Y%m%d_%H%M%S.png", t)
		local f = io.open(dir .. n, "rb")
		if f then
			f:close()
			path, name = dir .. n, n
			break
		end
	end
	if not path then
		return nil, "No screenshot from the last ten minutes: take one "..
				"with the screenshot key, then attach it"
	end
	local img = Image:new()
	if not img:Load(path) or img.width == 0 then
		return nil, "Could not read " .. name
	end
	local tmp = __buildat_get_path("user") .. "/starport_evidence.jpg"
	for _, try in ipairs({{640, 60}, {480, 50}, {360, 40}, {240, 35}}) do
		local w = math.min(try[1], img.width)
		local h = math.max(1, math.floor(img.height * w / img.width))
		img:Resize(w, h)
		if img:SaveJPG(tmp, try[2]) then
			local f = io.open(tmp, "rb")
			local data = f and f:read("*a") or ""
			if f then
				f:close()
			end
			os.remove(tmp)
			local b64 = base64(data)
			if #b64 <= MAX_EVIDENCE and #data > 0 then
				return b64, name
			end
		end
	end
	return nil, "Could not make " .. name .. " small enough"
end

local function open_report_row(row)
	local root, w = open_window("starport report", 620)
	add_text(w, "Report " .. tostring(row.name) .. " (" .. row.address .. ")")
	local reason = nil
	local buttons = {}
	for _, r in ipairs(REASONS) do
		buttons[r[1]] = add_button(w, r[2], function()
			reason = r[1]
			for k, b in pairs(buttons) do
				b:GetChild(0).color = k == reason and YELLOW or
						magic.Color(1, 1, 1)
			end
		end)
	end
	local sr = add_row(w)
	add_label(sr, "Wrong rating: audience should be", 240)
	local suggest = add_edit(sr, "")
	add_text(w, "What is wrong (optional):")
	local text = add_edit(w, "")
	-- 2b: the whole fleet, where the server is in one
	local whole_fleet = false
	if type(row.fleet) == "table" and row.fleet.name then
		local fb
		fb = add_button(w, "[ ] The whole fleet: " .. tostring(row.fleet.name),
				function()
			whole_fleet = not whole_fleet
			fb:GetChild(0).text = (whole_fleet and "[x]" or "[ ]") ..
					" The whole fleet: " .. tostring(row.fleet.name)
		end)
	end
	local evidence = nil
	local er = add_row(w)
	local ev_text
	add_button(er, "Attach my latest screenshot", function()
		local b64, what = latest_screenshot_evidence()
		evidence = b64
		ev_text.text = b64 and "Attached: " .. what or what
	end)
	ev_text = add_label(er, "", 0)
	local status = add_text(w, "")
	local r = add_row(w)
	add_button(r, "Send", function()
		if not reason then
			status.text = "Choose a reason"
			return
		end
		local s = load_state()
		local n = 0
		for url, id in pairs(row.ids) do
			n = n + 1
			local body = {listing = id, reason = reason, text = text:GetText(),
				whole_fleet = whole_fleet, evidence = evidence}
			local a = suggest:GetText()
			if reason == "category" and a ~= "" then
				body.suggest = {audience = a}
			end
			if s.send_key then
				body.key = key_for(url)
			end
			network.http_post(url .. "/api/report", network.write_json(body),
					function(answer, err)
				local v = answer and network.parse_json(answer)
				if type(v) == "table" and v.ok then
					table.insert(s.receipts, {starport = url,
						receipt = v.receipt, name = tostring(row.name),
						reason = reason, ts = os.time(), keyed = s.send_key,
						state = "open"})
					save_state()
					status.text = "Sent; receipt " .. v.receipt ..
							(s.send_key and ". The outcome shows in the "..
							"Starport settings." or ".")
				else
					status.text = "Not sent: " .. tostring(type(v) == "table"
							and v.error or err)
				end
			end, {description = "Starport"})
		end
		status.text = "Sending to " .. n .. " Starport(s)..."
	end)
	add_button(r, "Close", function() uistack.main:pop(root) end)
end

-- open_report(address): the report dialog for a listing of the last fetch
function M.safe.open_report(address)
	local row = row_of(address)
	if not row then
		return false
	end
	open_report_row(row)
	return true
end

-- open_report_here(): the report dialog for the server this client is on,
-- for a server's own page ([STARPORT] 5); found in the Starports' lists,
-- which are fetched when the last fetch does not have it
-- simplified: by the address connected to, which is the listing's only
-- when the player connected by the address the listing has
function M.safe.open_report_here()
	local address = __buildat_server_address()
	if not address then
		return false
	end
	local function go()
		local row = row_of(address)
		if row then
			open_report_row(row)
		else
			local root, w = open_window("starport report", 520)
			add_text(w, address .. " is not listed on your Starports, so "..
					"there is nobody to report it to.")
			add_button(w, "Close", function() uistack.main:pop(root) end)
		end
	end
	if row_of(address) then
		go()
	else
		M.safe.fetch(function() go() end, true)
	end
	return true
end

-- group(servers[, fleet_id]): a fetch's servers as fleet, pool and
-- server rows (group.lua), a pool's servers in the user's region first
function M.safe.group(servers, fleet_id)
	return group.group(servers, fleet_id, load_state().region or "")
end

M.fetch = M.safe.fetch
M.direct_connect_allowed = M.safe.direct_connect_allowed
M.open_settings = M.safe.open_settings
M.open_report = M.safe.open_report
M.open_report_here = M.safe.open_report_here
M.id_token_here = M.safe.id_token_here
M.group = M.safe.group
return M
-- vim: set noet ts=4 sw=4:
