-- Buildat: apps/starport/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Starport's own pages** ([STARPORT] 1, 2a, 6): what an operator, a
-- moderator and the admin see after joining. Every page asks the server
-- with a JSON "sp:req" {id, cmd, ...} and draws its "sp:res"; the server
-- (main.cpp) decides who may do what.
--
-- **One window** ([STARPORT_UI]): a sidebar of every page, grouped under
-- grey headers, on the left; the page on the right, scrolling inside the
-- window, which keeps its size. Under 560 px the sidebar is a screen of
-- its own. The Overview comes first.
--
-- A scripted client sends BUILDAT_SP_REQS, JSON requests a line each, in
-- order after the join, and logs each answer as "sp: <json>".
local log = buildat.Logger("starport")
local magic = require("buildat/extension/urho3d")

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("starport: could not load accounts.lua: " .. tostring(accounts_err))
end
accounts.on_kicked = function()
	buildat.disconnect()
end

--
-- JSON out; in is buildat.parse_json.
-- simplified: an empty table goes as [], which every list the server
-- takes is, and no object it takes is ever empty
--
local function encode(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c)
			local map = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
				['\r'] = '\\r', ['\t'] = '\\t'}
			return map[c] or string.format("\\u%04x", c:byte())
		end) .. '"'
	end
	local out = {}
	if next(v) == nil or v[1] ~= nil then
		for _, x in ipairs(v) do
			out[#out + 1] = encode(x)
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	for k, x in pairs(v) do
		out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x)
	end
	return "{" .. table.concat(out, ",") .. "}"
end
assert(encode({a = {1, "x\n"}}) == '{"a":[1,"x\\n"]}')

--
-- Requests
--
local next_id = 1
local waiting = {}

-- on(result) on success; a failure is shown on the page that asked
local function req(cmd, args, on)
	local q = args or {}
	q.cmd = cmd
	q.id = next_id
	waiting[next_id] = on or function() end
	next_id = next_id + 1
	buildat.send_packet("sp:req", encode(q))
end

local page = nil
local redraw = nil   -- the page open, drawn again
local message = nil  -- a line for the top of the next page drawn

buildat.sub_packet("sp:res", function(data)
	local res = buildat.parse_json(data)
	if type(res) ~= "table" then
		return
	end
	local on = waiting[res.id]
	waiting[res.id] = nil
	if (buildat.get_env("BUILDAT_SP_REQS") or "") ~= "" then
		log:info("sp: " .. data)
	end
	if not res.ok then
		message = tostring(res.error)
		if redraw then
			redraw()
		end
		return
	end
	if on then
		on(res.result)
	end
end)

--
-- Pages
--
local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)
local text = accounts.page_text
local button = accounts.page_button

local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

local function edit(parent, label, value)
	local r = row(parent)
	local l = text(r, label)
	l:SetWordwrap(false)
	l.minWidth = 120
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.minWidth = 200
	e.textSelectable = true
	e.textCopyable = true
	e:SetText(value or "")
	return e
end

local frame, sidebar, view = nil, nil, nil
local narrow = magic.ui.root.width < 560
local page_width = 100

local function build_frame()
	frame = accounts.page_window(880)
	frame:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(8, 8, 8, 8))
	frame:SetFixedHeight(math.floor(magic.ui.root.height * 0.8))
	local inner = frame.width - 16
	sidebar = frame:CreateChild("UIElement")
	sidebar:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	sidebar:SetFixedWidth(narrow and inner or 150)
	view = frame:CreateChild("ScrollView")
	view:SetStyleAuto()
	view:SetFixedWidth(narrow and inner or inner - 150 - 8)
	view.scrollBarsAutoVisible = true
	-- Less the vertical bar and a margin
	page_width = view.width - 24
	if narrow then
		view.visible = false
	end
end

-- On a narrow screen, the sidebar's screen again
local function show_sidebar()
	sidebar.visible = true
	view.visible = false
end

-- A page: drawn into the window's right side, with the title, a Back for
-- a step inside a page (`back`), and the message the last request left.
-- `draw` draws it again, as after a failed request
local function page_element()
	if not frame then
		build_frame()
	end
	-- builtin/accounts removes the pages it drew itself
	if page then
		pcall(function() page:Remove() end)
	end
	page = view:CreateChild("UIElement")
	page:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(4, 4, 4, 4))
	page:SetFixedWidth(page_width)
	view.contentElement = page
	view.viewPosition = magic.IntVector2(0, 0)
	if narrow then
		sidebar.visible = false
		view.visible = true
	end
	return page
end

local function open(title, draw, back)
	local w = page_element()
	redraw = draw
	if back or narrow then
		button(row(w), "Back", back or show_sidebar)
	end
	text(w, title)
	if message then
		text(w, message, YELLOW)
		message = nil
	end
	return w
end

-- A list that scrolls, rows wrapping to its width
local function list(w, height_share)
	local l = w:CreateChild("ListView")
	l:SetStyleAuto()
	l:SetFixedHeight(math.max(120,
			math.floor(magic.ui.root.height * (height_share or 0.55))))
	local width = math.max(100, w.width - 32 - 28)
	local add = {}
	function add.text(t, color)
		local x = l:CreateChild("Text")
		x:SetStyleAuto()
		x:SetWordwrap(true)
		x:SetFixedWidth(width)
		x:SetText(t)
		if color then
			x:SetColor(color)
		end
		l:AddItem(x)
		return x
	end
	function add.button(t, on)
		local r = l:CreateChild("UIElement")
		r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
		button(r, t, on)
		l:AddItem(r)
		return r
	end
	function add.row()
		local r = l:CreateChild("UIElement")
		r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
		l:AddItem(r)
		return r
	end
	return add
end

local function s(v)
	return v == nil and "" or tostring(v)
end
-- "YYYY-MM-DD HH:MM" in UTC; the sandbox has no os.date (days to a date:
-- Howard Hinnant's civil_from_days)
local function when(ts)
	ts = math.floor(tonumber(ts) or 0)
	local z = math.floor(ts / 86400) + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) +
			math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	local y = yoe + era * 400 + (m <= 2 and 1 or 0)
	local sec = ts % 86400
	return string.format("%04d-%02d-%02d %02d:%02d", y, m, d,
			math.floor(sec / 3600), math.floor(sec % 3600 / 60))
end
assert(when(0) == "1970-01-01 00:00" and
		when(1790926649) == "2026-10-02 07:37" and
		when(951782400) == "2000-02-29 00:00")

-- The evidence a report carries, back to the JPEG it was
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_AT = {}
for i = 1, 64 do
	B64_AT[B64:sub(i, i)] = i - 1
end
local function unbase64(text)
	local out = {}
	local n, bits = 0, 0
	for c in text:gmatch("[%w%+/]") do
		n = n * 64 + B64_AT[c]
		bits = bits + 6
		if bits >= 8 then
			bits = bits - 8
			local byte = math.floor(n / 2 ^ bits)
			out[#out + 1] = string.char(byte)
			n = n - byte * 2 ^ bits
		end
	end
	return table.concat(out)
end
assert(unbase64("TWFu") == "Man" and unbase64("TWE=") == "Ma" and
		unbase64("TQ==") == "M")

local function categories(l)
	local d = {}
	for k, v in pairs(l.descriptors or {}) do
		if v ~= "no" and v ~= "none" then
			d[#d + 1] = k .. ": " .. s(v)
		end
	end
	table.sort(d)
	return s(l.kind) .. ", " .. s(l.audience) .. ", " .. s(l.access) ..
			(#d > 0 and " (" .. table.concat(d, ", ") .. ")" or "")
end

local home, queue_page, group_page, listings_page, listing_page
local audit_page, appeals_page, settings_page, appeal_page, fleets_page
local blocklists_page

-- What a moderator does to a listing ([STARPORT] 6), for a group's
-- reports (decide) or on its own (act)
local function action_rows(w, on_action)
	local why = edit(w, "Statement", "")
	local days = edit(w, "Days (0: open)", "0")
	local audience = edit(w, "Relabel audience", "")
	local r = row(w)
	local function go(action, extra)
		local q = {action = action, text = why:GetText(),
			days = tonumber(days:GetText()) or 0}
		for k, v in pairs(extra or {}) do
			q[k] = v
		end
		on_action(q)
	end
	button(r, "Relabel", function()
		go("relabel", {fields = {audience = audience:GetText()}})
	end)
	button(r, "Hide", function() go("hide") end)
	button(r, "Delist", function() go("delist") end)
	button(r, "Ban", function() go("ban") end)
	button(r, "Ban + account", function() go("ban", {ban_account = true}) end)
	button(r, "Illegal (CSAM)", function() go("csam") end)
	button(r, "Restore", function() go("restore") end)
end

-- The last "me": the sidebar's entries and counts, and the Overview's
local me = {}
local current = "overview"
local overview_page, servers_page, account_page, pages

local function side_button(label, color, on_click)
	local b = sidebar:CreateChild("Button")
	b:SetStyleAuto()
	b:SetFixedHeight(26)
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(label)
	t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	t.position = magic.IntVector2(8, 0)
	if color then
		t:SetColor(color)
	end
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
end

-- A sidebar entry carries a count of what waits on it, in the highlight
-- colour while there is any. simplified: "any" stands for "any unseen";
-- per-item seen times are the upgrade
local function draw_sidebar()
	sidebar:RemoveAllChildren()
	local function entry(label, key, count)
		count = tonumber(count) or 0
		side_button((key == current and "> " or "") .. label ..
				(count > 0 and " (" .. count .. ")" or ""),
				count > 0 and YELLOW or nil, function()
			current = key
			draw_sidebar()
			pages[key]()
		end)
	end
	local function header(t)
		text(sidebar, t, GREY)
	end
	entry("Overview", "overview", me.unseen_events)
	header("Mine")
	entry("Servers", "servers", 0)
	entry("Fleets", "fleets", 0)
	entry("Blocklists", "blocklists", me.blocklist_offers)
	entry("Account", "account", 0)
	if me.moderator then
		header("Moderation")
		entry("Queue", "queue", me.queue)
		entry("Listings", "listings", 0)
		entry("Appeals", "appeals", me.open_appeals)
		entry("Audit log", "audit", 0)
	end
	if me.admin then
		header("Admin")
		entry("Settings", "settings", 0)
		entry("Accounts", "accounts", 0)
	end
end

-- "me" asked again, the sidebar drawn with it, and `draw` after
local function refresh(draw)
	req("me", {}, function(r)
		me = r
		if not frame then
			build_frame()
		end
		draw_sidebar()
		if draw then
			draw()
		end
	end)
end

-- The page open drawn again, with "me" asked again first
home = function()
	refresh(pages[current])
end

overview_page = function()
	req("overview", {}, function(ov)
		local w = open("Overview", overview_page)
		local n = me.notice
		if type(n) == "table" and s(n.text) ~= "" then
			text(w, "Admin notice: " .. n.text,
					n.priority == "high" and YELLOW or nil)
		end
		-- The standing
		text(w, s(me.starport) .. " account " .. s(me.name) ..
				(me.suspended and ", suspended until " ..
				when(me.suspended_until) or ", in good standing") ..
				". Two-step login " .. (me.totp and "on" or "off") ..
				". E-mail " .. (s(me.email_pending) ~= "" and
				"not confirmed yet" or s(me.email) ~= "" and "confirmed" or
				"not set") .. ".", GREY)
		-- What waits: while it lasts, never as an event
		local waiting = {}
		local function wait(t, key, open_it)
			waiting[#waiting + 1] = {t, open_it or function()
				current = key
				draw_sidebar()
				pages[key]()
			end}
		end
		for _, st in ipairs(me.statements or {}) do
			if not st.appealed then
				wait(s(st.listing_name) .. ": " .. s(st.action) ..
						" -- a statement you may appeal", nil, function()
					appeal_page(st)
				end)
			end
		end
		if (tonumber(me.blocklist_offers) or 0) > 0 then
			wait(me.blocklist_offers .. " offer(s) to your blocklists",
					"blocklists")
		end
		if s(me.email_pending) ~= "" then
			wait("Your e-mail is not confirmed", "account")
		end
		for _, x in ipairs(me.listings or {}) do
			if s(x.served) ~= "listed" or x.pool_mismatch then
				wait(s(x.name) .. ": " .. (x.pool_mismatch and
						"differs from its pool" or s(x.served)), "servers")
			end
		end
		if me.moderator then
			if (tonumber(me.queue) or 0) > 0 then
				wait(me.queue .. " report group(s) in the queue", "queue")
			end
			if (tonumber(me.open_appeals) or 0) > 0 then
				wait(me.open_appeals .. " open appeal(s)", "appeals")
			end
			if not me.totp then
				-- [STARPORT] 10a: recommended to whoever moderates
				wait("Turn two-step login on", "account")
			end
		end
		if #waiting > 0 then
			text(w, "Waiting for you")
			for _, x in ipairs(waiting) do
				button(row(w), x[1], x[2])
			end
		end
		text(w, "Recent events")
		local l = list(w, 0.4)
		for _, e in ipairs(ov.events or {}) do
			l.text(when(e.ts) .. "  " .. s(e.text),
					(tonumber(e.ts) or 0) > (tonumber(ov.seen) or 0) and
					YELLOW or nil)
		end
		if #(ov.events or {}) == 0 then
			l.text("Nothing yet.", GREY)
		end
		if (tonumber(me.unseen_events) or 0) > 0 then
			me.unseen_events = 0
			draw_sidebar()
		end
	end)
end

-- The operator's servers ([STARPORT] 2a): claiming, the listings and
-- their statements
servers_page = function()
	local w = open("Servers", servers_page)
	text(w, "Claiming a listing: its id and claim code are in "..
			"starport_claim.txt beside the server's starport.json.", GREY)
	text(w, "A server with a new key: the listing it replaces too.",
			GREY)
	local cl = edit(w, "Listing id", "")
	local cc = edit(w, "Claim code", "")
	local cr = edit(w, "Replaces (optional)", "")
	button(row(w), "Claim", function()
		req("claim", {listing = cl:GetText(), code = cc:GetText(),
			replaces = cr:GetText()}, function()
			message = "Claimed."
			home()
		end)
	end)
	local l = list(w, 0.3)
	for _, x in ipairs(me.listings or {}) do
		l.text(s(x.name) .. " (" .. s(x.id) .. ", " .. s(x.host) .. ":" ..
				s(x.port) .. "): " .. s(x.served) ..
				(s(x.fleet) ~= "" and "; fleet " .. x.fleet ..
				(s(x.pool) ~= "" and ", pool " .. x.pool or "") ..
				(x.pool_mismatch and " (differs from its pool)" or "")
				or ""))
		if s(x.fleet) ~= "" then
			l.button("Remove from the fleet", function()
				req("fleet_remove_server", {listing = x.id}, home)
			end)
		end
	end
	for _, st in ipairs(me.statements or {}) do
		l.text(when(st.ts) .. " " .. s(st.listing_name) .. ": " ..
				s(st.action) .. " for " .. s(st.reason) .. ". " ..
				s(st.text), YELLOW)
		l.button(st.appealed and "Appeal again" or "Appeal", function()
			appeal_page(st)
		end)
	end
end

-- The account: the contact e-mail ([STARPORT] 2a), the password and
-- two-step login (builtin/accounts' pages, drawn in this window)
account_page = function()
	local w = open("Account", account_page)
	if s(me.email) ~= "" then
		text(w, "Contact e-mail (not shown to users): " .. me.email, GREY)
	end
	local email = edit(w, "Contact e-mail", s(me.email_pending) ~= "" and
			me.email_pending or me.email)
	button(row(w), "Set e-mail", function()
		req("set_email", {email = email:GetText()}, function(how)
			message = how == "sent" and "A code went to that address;"..
					" enter it below." or "Set."
			home()
		end)
	end)
	if s(me.email_pending) ~= "" then
		local code = edit(w, "Code from the mail", "")
		button(row(w), "Confirm", function()
			req("confirm_email", {code = code:GetText()}, function()
				message = "Confirmed."
				home()
			end)
		end)
	end
	local r = row(w)
	button(r, "Change password...", function()
		accounts.password_page(account_page)
	end)
	-- [STARPORT] 10a: recommended to whoever moderates
	button(r, "Two-step login...", function()
		accounts.totp_page(home)
	end)
	button(r, "Log out", accounts.logout)
end

-- An operator's fleets ([STARPORT] 2b): a server joins one by the line
-- shown here in its starport.json
fleets_page = function(me)
	local w = open("Fleets", function() fleets_page(me) end)
	text(w, "A server joins a fleet by a line in its starport.json; "..
			"servers that only split the load also name the same pool.",
			GREY)
	local l = list(w, 0.3)
	for _, f in ipairs(me.fleets or {}) do
		l.text(s(f.name) .. ": " .. s(f.description) .. " " .. s(f.link))
		l.text('"fleet": "' .. s(f.id) .. ":" .. s(f.code) ..
				'", "pool": "main"', YELLOW)
		local r = l.row()
		button(r, "New code (servers with the old one leave)", function()
			req("fleet_new_code", {fleet = f.id}, function()
				req("me", {}, fleets_page)
			end)
		end)
	end
	local name = edit(w, "Name", "")
	local description = edit(w, "Description", "")
	local link = edit(w, "Link", "")
	local r = row(w)
	button(r, "Make a fleet", function()
		req("fleet_create", {name = name:GetText(),
			description = description:GetText(), link = link:GetText()},
				function()
			req("me", {}, fleets_page)
		end)
	end)
end

-- 10d: blocklists, public within the Starport. A server publishes its
-- reported bans to a list (its owner's at once, another's when accepted)
-- and subscribes to any list for its bans
blocklists_page = function(me)
	req("blocklists", {}, function(lists)
		local w = open("Blocklists", function() blocklists_page(me) end)
		-- The account's own fleets and servers, as the scope to act for
		local scopes = {}
		for _, f in ipairs(me.fleets or {}) do
			scopes[#scopes + 1] = "fleet:" .. s(f.id)
		end
		for _, x in ipairs(me.listings or {}) do
			if s(x.fleet) == "" then
				scopes[#scopes + 1] = "listing:" .. s(x.id)
			end
		end
		text(w, "Yours: " .. (#scopes > 0 and table.concat(scopes, ", ") or
				"no fleets or servers"), GREY)
		local scope = edit(w, "Acting for", scopes[1] or "")
		local l = list(w, 0.4)
		for _, b in ipairs(lists) do
			l.text(s(b.name) .. " (" .. s(b.owner) .. "): " .. s(b.bans) ..
					" bans; publishers " .. table.concat(b.publishers or {},
					", ") .. "; subscribers " .. #(b.subscribers or {}))
			local r = l.row()
			local function go(cmd, extra)
				local q = {list = b.id, scope = scope:GetText()}
				for k, v in pairs(extra or {}) do
					q[k] = v
				end
				req(cmd, q, function()
					req("me", {}, blocklists_page)
				end)
			end
			button(r, "Publish to it", function() go("blocklist_publish") end)
			button(r, "Stop", function() go("blocklist_unpublish") end)
			button(r, "Subscribe", function() go("blocklist_subscribe") end)
			button(r, "Unsubscribe", function()
				go("blocklist_subscribe", {on = false})
			end)
			if b.owner == me.name then
				for _, o in ipairs(b.offers or {}) do
					local rr = l.row()
					button(rr, "Accept " .. o, function()
						go("blocklist_accept", {scope = o})
					end)
					button(rr, "Refuse", function()
						go("blocklist_drop", {scope = o})
					end)
				end
			end
		end
		local name = edit(w, "New list's name", "")
		local r = row(w)
		button(r, "Make a list", function()
			req("blocklist_create", {name = name:GetText()}, function()
				req("me", {}, blocklists_page)
			end)
		end)
	end)
end

appeal_page = function(st)
	local w = open("Appeal: " .. s(st.listing_name) .. ", " .. s(st.action),
			function() appeal_page(st) end, home)
	text(w, s(st.text))
	local why = edit(w, "Why", "")
	local r = row(w)
	button(r, "Send", function()
		req("appeal", {statement = st.id, text = why:GetText()}, function()
			message = "Appeal sent; another moderator decides."
			home()
		end)
	end)
end

queue_page = function()
	req("queue", {}, function(groups)
		local w = open("Report queue", queue_page)
		local l = list(w)
		if #groups == 0 then
			l.text("Nothing waiting.", GREY)
		end
		for _, g in ipairs(groups) do
			l.button(string.format("%s: %s, %d report(s), weight %.2f%s",
					s(g.listing_name), s(g.reason), g.count or 0,
					g.weight or 0, g.auto ~= "" and ", auto " .. g.auto or ""),
					function() group_page(g.id) end)
			if s(g.note) ~= "" then
				l.text(g.note, GREY)
			end
		end
	end)
end

group_page = function(gid)
	req("group", {group = gid}, function(r)
		local g, x = r.group, r.listing or {}
		local w = open("Reports of " .. s(g.reason) .. ": " .. s(x.name),
				function() group_page(gid) end, queue_page)
		text(w, s(x.id) .. " " .. s(x.host) .. ":" .. s(x.port) .. ", " ..
				categories(x) .. "; " .. s(x.served) .. ". " ..
				s(x.description), GREY)
		local l = list(w, 0.3)
		if s(g.fleet) ~= "" then
			text(w, "Reports of the whole fleet " .. g.fleet ..
					": an action applies to all its servers.", YELLOW)
		end
		for _, rep in ipairs(r.reports or {}) do
			l.text(string.format("%s weight %.2f%s%s: %s", when(rep.ts),
					rep.weight or 0, rep.trusted and ", trusted flagger" or "",
					rep.state ~= "open" and ", " .. s(rep.state) or "",
					s(rep.text)))
			local rr = l.row()
			if s(rep.evidence) ~= "" then
				button(rr, "Save the screenshot", function()
					local path = buildat.save_file("evidence_" .. rep.id ..
							".jpg", unbase64(rep.evidence))
					message = path and "Saved: " .. path or
							"Could not save it"
					group_page(gid)
				end)
			end
			if s(rep.key) ~= "" and not rep.trusted then
				button(rr, "Trust this reporter (admin)", function()
					req("trust_reporter", {report = rep.id}, function()
						message = "Their reports now go first."
						group_page(gid)
					end)
				end)
			end
		end
		for _, a in ipairs(r.history or {}) do
			l.text(when(a.ts) .. " " .. s(a.action) .. " by " ..
					(s(a.by) ~= "" and a.by or "Starport") .. ": " ..
					s(a.text), GREY)
		end
		if r.id then
			-- 10d: a Starport ID that servers banned; only a moderator
			-- suspends it, with a statement it gets
			text(w, "Starport ID " .. s(r.id.name) .. ", age " ..
					s(r.id.band) .. ((tonumber(r.id.suspended_until) or 0) >
					0 and ", suspended" or ""), YELLOW)
			local why = edit(w, "Statement", "")
			local days = edit(w, "Days (0: until lifted)", "30")
			button(row(w), "Suspend the ID", function()
				req("decide", {group = gid, decision = "uphold",
					action = "suspend", text = why:GetText(),
					days = tonumber(days:GetText()) or 0}, queue_page)
			end)
		else
			action_rows(w, function(q)
				q.group, q.decision = gid, "uphold"
				req("decide", q, queue_page)
			end)
		end
		local b = row(w)
		button(b, "Dismiss", function()
			req("decide", {group = gid, decision = "dismiss"}, queue_page)
		end)
	end)
end

listings_page = function(search)
	req("listings", {search = search}, function(ls)
		local w = open("Listings", function() listings_page(search) end)
		local e = edit(w, "Search", search)
		magic.SubscribeToEvent(e, "TextFinished", function()
			listings_page(e:GetText())
		end)
		local l = list(w)
		for _, x in ipairs(ls) do
			l.button(s(x.name) .. " (" .. s(x.owner) .. "): " .. s(x.served),
					function() listing_page(x) end)
		end
	end)
end

listing_page = function(x)
	local w = open(s(x.name), function() listing_page(x) end,
			function() listings_page("") end)
	text(w, s(x.id) .. " " .. s(x.host) .. ":" .. s(x.port) .. ", app " ..
			s(x.app) .. ", operator " .. s(x.owner) .. "\n" .. categories(x) ..
			"\n" .. s(x.served) .. "\n" .. s(x.description), GREY)
	local reason = edit(w, "Reason", "other")
	local whole = false
	if s(x.fleet) ~= "" then
		local fb
		fb = button(row(w), "[ ] On the whole fleet " .. x.fleet, function()
			whole = not whole
			fb:GetChild(0):SetText((whole and "[x]" or "[ ]") ..
					" On the whole fleet " .. x.fleet)
		end)
	end
	action_rows(w, function(q)
		q.listing, q.reason = x.id, reason:GetText()
		if whole then
			q.fleet = x.fleet
			return req("act", q, function(n)
				message = "Done on " .. s(n) .. " server(s)."
				listings_page("")
			end)
		end
		req("act", q, function(nx)
			message = "Done."
			listing_page(nx)
		end)
	end)
end

audit_page = function()
	req("audit", {}, function(as)
		local w = open("Audit log", audit_page)
		local l = list(w)
		for _, a in ipairs(as) do
			l.text(when(a.ts) .. " " .. s(a.listing) .. " " .. s(a.action) ..
					(a.auto and " (automatic)" or "") .. " " ..
					s(a.reason) .. " by " .. (s(a.by) ~= "" and a.by or
					"Starport") .. ": " .. s(a.text))
		end
	end)
end

appeals_page = function()
	req("appeals", {}, function(as)
		local w = open("Appeals", appeals_page)
		local answer = edit(w, "Answer", "")
		local l = list(w)
		if #as == 0 then
			l.text("No open appeals.", GREY)
		end
		for _, a in ipairs(as) do
			local st = a.statement_text or {}
			l.text(when(a.ts) .. " " .. s(a.by) .. " on " ..
					s(st.listing_name) .. " (" .. s(st.action) .. " by " ..
					s(a.acted_by) .. "): " .. s(a.text))
			local r = l.row()
			for _, o in ipairs({"reverse", "keep"}) do
				button(r, o == "reverse" and "Reverse" or "Keep", function()
					req("decide_appeal", {appeal = a.id, outcome = o,
						text = answer:GetText()}, appeals_page)
				end)
			end
		end
	end)
end

-- The instance's settings ([STARPORT] 5a, 7, 8), each as its JSON
settings_page = function()
	req("settings", {}, function(set)
		local w = open("Settings", settings_page)
		text(w, "Each value is JSON; Enter in a field saves it.", GREY)
		local keys = {}
		for k in pairs(set) do
			keys[#keys + 1] = k
		end
		table.sort(keys)
		local l = list(w, 0.6)
		for _, k in ipairs(keys) do
			local r = l.row()
			local name = text(r, k)
			name:SetWordwrap(false)
			name.minWidth = 160
			local e = r:CreateChild("LineEdit")
			e:SetStyleAuto()
			e.minHeight = 26
			e.minWidth = 420
			e.textSelectable = true
			e.textCopyable = true
			e:SetText(encode(set[k]))
			magic.SubscribeToEvent(e, "TextFinished", function()
				local v, err = buildat.parse_json(e:GetText())
				if v == nil and e:GetText() ~= "null" then
					message = k .. ": " .. s(err)
					return settings_page()
				end
				req("set_settings", {settings = {[k] = v}}, function()
					message = k .. " saved."
					settings_page()
				end)
			end)
		end
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_SP_REQS") or ""
	if script ~= "" then
		for line in script:gmatch("[^\n]+") do
			local q = buildat.parse_json(line)
			if type(q) == "table" then
				q.id = next_id
				next_id = next_id + 1
				buildat.send_packet("sp:req", encode(q))
			end
		end
	end
	-- builtin/accounts' pages (the password, two-step login, Accounts)
	-- in this window
	accounts.page_parent = function()
		return page_element()
	end
	refresh(overview_page)
end

pages = {
	overview = overview_page,
	servers = servers_page,
	fleets = function() fleets_page(me) end,
	blocklists = function() blocklists_page(me) end,
	account = account_page,
	queue = queue_page,
	listings = function() listings_page("") end,
	appeals = appeals_page,
	audit = audit_page,
	settings = settings_page,
	accounts = function() accounts.users_page(home) end,
}

accounts.start({title = "Starport", env = "BUILDAT_SP"})
-- vim: set noet ts=4 sw=4:
