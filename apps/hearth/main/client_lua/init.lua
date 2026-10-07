-- Buildat: apps/hearth/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Hearth, taking part** ([HEARTH_MVP], [HEARTH_UI]): one window, a
-- sidebar of places -- Home, Search, Notifications, Following, the topics,
-- the admin's -- and the page open beside it, as Starport's. Back goes to
-- where a page was opened from. Every action is a JSON "hr:req" {id, cmd,
-- ...}, answered by "hr:res" (main.cpp decides who may do what). Reading
-- is also the server's plain HTML, at its address in a browser.
--
-- A scripted client sends BUILDAT_HEARTH_REQS, JSON requests a line each
-- numbered from 1001, after the join, and logs each answer as "hr: <json>"
-- and each notification as "hr notify: <json>".
local log = buildat.Logger("hearth")
local magic = require("buildat/extension/urho3d")
local ui = require("buildat/extension/ui_utils")
ui = ui.safe or ui

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("hearth: could not load accounts.lua: " .. tostring(accounts_err))
end

-- JSON out, for the flat requests this page sends
local function encode(v)
	if type(v) == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c)
			return string.format("\\u%04x", c:byte())
		end) .. '"'
	elseif type(v) == "table" then
		local out = {}
		-- simplified: a table with v[1] is an array (no holes, no mixed keys)
		if v[1] ~= nil then
			for _, x in ipairs(v) do out[#out + 1] = encode(x) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		for k, x in pairs(v) do
			out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return tostring(v)
end

local scripted = (buildat.get_env("BUILDAT_HEARTH_REQS") or "") ~= "" or
		(buildat.get_env("BUILDAT_HEARTH_OPEN") or "") ~= ""
local next_id = 1
local waiting = {}
-- What the last request said, for the page drawn next; say() puts it on
-- the page open
local message = nil
local say

-- on_error(why): instead of the reason said on the page open
local function req(cmd, args, on, on_error)
	local q = args or {}
	q.cmd = cmd
	q.id = next_id
	waiting[next_id] = {on or function() end, on_error}
	next_id = next_id + 1
	buildat.send_packet("hr:req", encode(q))
end

buildat.sub_packet("hr:res", function(data)
	local res = buildat.parse_json(data)
	if type(res) ~= "table" then
		return
	end
	if scripted then
		log:info("hr: " .. data)
	end
	local on = waiting[res.id]
	waiting[res.id] = nil
	if not res.ok then
		if on and on[2] then
			return on[2](tostring(res.error))
		end
		-- On the page as it is: what was typed stays
		return say(tostring(res.error))
	end
	if on then
		on[1](res.result)
	end
end)

local function C(name) return magic.Color(ui.rgb(name)) end
local DIM, WARN, MAIN = C("dim"), C("warn"), C("main")
-- A button as wide as its label: a row lays its buttons out from the left
-- rather than stretching them over the page
local function button(parent, label, on_click, main)
	local b = accounts.page_button(parent, label, on_click, main)
	b:SetFixedWidth(b.minWidth)
	return b
end

-- A row of buttons or fields; its height fixed, as a layout stretches
-- what has none to fill the page
local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	r:SetFixedHeight(28)
	return r
end

-- A text, wrapped to `width` when it has one
local function text(parent, s, color, width, size)
	local t = parent:CreateChild("Text")
	t:SetStyleAuto()
	if size then
		t:SetFontSize(size)
	end
	if width then
		t:SetWordwrap(true)
		t:SetFixedWidth(width)
	end
	t:SetText(s)
	if color then
		t:SetColor(color)
	end
	return t
end

-- **Time**: the server's clock at the join ("me"), run on by this one's
local clock = {server = 0, at = 0}
local function now()
	return clock.server + (buildat.get_time_us() - clock.at) / 1e6
end
-- "YYYY-MM-DD" in UTC; the sandbox has no os.date (Starport's when(),
-- Howard Hinnant's civil_from_days)
local function date(ts)
	local z = math.floor(ts / 86400) + 719468
	local era = math.floor(z / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) +
			math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp < 10 and mp + 3 or mp - 9
	return string.format("%04d-%02d-%02d", yoe + era * 400 +
			(m <= 2 and 1 or 0), m, d)
end
-- "now", "5 min", "3 h", "2 d" ago; the date past a week
local function ago(ts, at)
	ts = tonumber(ts) or 0
	local s = math.max(0, (at or now()) - ts)
	if s < 60 then
		return "now"
	elseif s < 3600 then
		return math.floor(s / 60) .. " min ago"
	elseif s < 86400 then
		return math.floor(s / 3600) .. " h ago"
	elseif s < 7 * 86400 then
		return math.floor(s / 86400) .. " d ago"
	end
	return date(ts)
end
assert(ago(100, 130) == "now" and ago(0, 7200) == "2 h ago" and
		ago(951782400, 951782400 + 30 * 86400) == "2000-02-29")

-- The markup's buttons under a message's field, for whoever does not know
-- Markdown: each puts its Markdown in at the cursor.
-- simplified: never wraps a selection -- a field's selection cannot be
-- read from here; that needs Text's selectionStart and selectionLength in
-- safe_classes.lua
local MARKUP = {{"Bold", "**bold**"}, {"List", "\n- "},
	{"Link", "[text](https://)"}, {"Image", "![what it shows](https://)"},
	{"Code", "`code`"}}
local function insert_at_cursor(e, s)
	-- The cursor counts characters, the string bytes
	local all, at, i = e:GetText(), e.cursorPosition, 1
	for _ = 1, at do
		local c = all:byte(i)
		if not c then
			break
		end
		i = i + (c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1)
	end
	e:SetText(all:sub(1, i - 1) .. s .. all:sub(i))
	e.cursorPosition = at + #s
	e:SetFocus(true)
end

-- [FORUM] step 5: File... picks a file (the browser's picker, or on native
-- the client's list of <user>/exports); once read it is uploaded, and its
-- link goes in at the cursor of the field it was picked for
local picking_into = nil

-- The server's HTML of a message as text to read: a link with its address
-- after it, a spoiler and a task's box said, the entities back
-- simplified: the five entities the server writes; another (&#123;) is
-- shown as written
local function html_text(h)
	h = h:gsub('<a class="ref" href="[^"]*">(.-)</a>', "%1")
	h = h:gsub('<a href="([^"]*)"[^>]*>(.-)</a>', function(u, t)
		return t == u and t or t .. " (" .. u .. ")"
	end)
	h = h:gsub('<span class="spoiler"[^>]*>(.-)</span>', "[spoiler: %1]")
	h = h:gsub('<input type="checkbox" disabled checked> ', "[x] ")
	h = h:gsub('<input type="checkbox" disabled> ', "[ ] ")
	h = h:gsub("<[ou]l[^>]*>\n", ""):gsub("</[ou]l>\n", "\n")
	h = h:gsub("<li>", "  - "):gsub("<hr>", "----"):gsub("</p>\n", "\n\n")
	h = h:gsub("</h%d>\n", "\n\n"):gsub("</t[hd]>", " | ")
	h = h:gsub("<[^>]*>", "")
	h = h:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
	h = h:gsub("&#39;", "'"):gsub("&amp;", "&")
	return (h:gsub("%s+$", ""))
end
assert(html_text('<p><strong>b</strong> <a href="https://x/?a=1&amp;b">x</a> ' ..
		'<a class="ref" href="/t/1">#1</a></p>\n<ul>\n<li>i</li>\n</ul>\n') ==
		"b x (https://x/?a=1&b) #1\n\n  - i")

-- The markup's buttons and Preview in a row under the field `e`; `show`
-- gets the preview's text. `extra` adds the row's last buttons (Send).
local function markup_buttons(parent, e, show, extra)
	local r = row(parent)
	for _, b in ipairs(MARKUP) do
		button(r, b[1], function()
			insert_at_cursor(e, b[2])
		end)
	end
	button(r, "File...", function()
		picking_into = e
		buildat.pick_file("")
	end)
	-- **The preview** ([FORUM]): what the page will show, from the server's
	-- own markup
	-- simplified: on the button (and on a pause in the compose page), not
	-- per key; a request is a parse of the whole message on the server
	button(r, "Preview", function()
		req("preview", {body = e:GetText()}, function(h)
			local t = html_text(tostring(h))
			show(t ~= "" and t or "(nothing)")
		end, function(why)
			show("No preview: " .. why)
		end)
	end)
	if extra then
		extra(r)
	end
	return r
end

magic.SubscribeToEvent("Update", function()
	if not picking_into then
		return
	end
	local name, data = buildat.picked_file()
	if not name and not data then
		return
	end
	local e = picking_into
	picking_into = nil
	local function fail(why)
		say("The file: " .. why)
	end
	if not name then
		return fail(tostring(data))
	end
	if #data > 16 * 1024 * 1024 then
		return fail("a file is 16 MiB at most")
	end
	-- simplified: hex, twice the file's size on the wire
	local hex = data:gsub(".", function(c)
		return string.format("%02x", c:byte())
	end)
	req("upload", {name = name, data = hex}, function(r)
		-- A page left meanwhile: e is held, detached, and nothing shows
		pcall(insert_at_cursor, e, (r.image and "!" or "") .. "[" ..
				name:gsub("[%[%]]", "") .. "](/f/" .. r.id .. "/" ..
				name:gsub("[^%w%.%-_]", "_") .. ")")
	end, fail)
end)

-- **Drafts** ([HEARTH_UI]): what is typed in a field, kept by its place
-- ("reply 12", "new 3", "edit 40") while the client runs, so Back or a
-- page drawn again loses nothing
local drafts = {}

-- A field; multi: a message's, where Enter breaks the line and Ctrl+Enter
-- finishes. `draft` names its draft.
local function edit(parent, label, multi, draft, width)
	if label then
		text(parent, label, DIM)
	end
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e:SetFixedHeight(multi and 96 or 26)
	if width then
		e:SetFixedWidth(width)
	end
	e.multiLine = multi == true
	e.textSelectable = true
	e.textCopyable = true
	if draft then
		e:SetText(drafts[draft] or "")
		magic.SubscribeToEvent(e, "TextChanged", function()
			drafts[draft] = e:GetText()
		end)
	end
	return e
end

-- A button that cycles through `choices` ({value, label}); returns a
-- function giving the value picked
-- simplified: a cycle, not a dropdown; the lists are short
local function cycle(parent, prefix, choices, at, on_change)
	local b
	at = at or 1
	b = button(parent, prefix .. choices[at][2], function()
		at = at % #choices + 1
		local t = b:GetChild(0)
		t:SetText(prefix .. choices[at][2])
		b:SetFixedWidth(t.width + 24)
		if on_change then
			on_change(choices[at][1])
		end
	end)
	return function() return choices[at][1] end
end

--
-- The frame: the sidebar and the page area beside it
--
local frame, sidebar, area = nil, nil, nil
local narrow = magic.ui.root.width < 560
-- The page area's size
local W, H = 100, 100

local function build_frame()
	frame = accounts.page_window(880)
	frame:SetLayout(magic.LM_HORIZONTAL, 8, magic.IntRect(8, 8, 8, 8))
	frame:SetFixedHeight(math.floor(magic.ui.root.height * 0.85))
	local inner = frame.width - 16
	sidebar = frame:CreateChild("UIElement")
	sidebar:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	sidebar:SetFixedWidth(narrow and inner or 180)
	area = frame:CreateChild("UIElement")
	area:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
	W = narrow and inner or inner - 188
	H = frame.height - 16
	area:SetFixedSize(W, H)
	-- [HEARTH_COLUMN_KEYS]: Up and Down in the sidebar or the page, Right
	-- and Left between them
	ui.keyboard_columns(frame, sidebar, area)
	log:info("hearth: frame " .. frame.width .. "x" .. frame.height .. ", page " ..
			W .. "x" .. H .. ", screen " .. magic.ui.root.width)
	if narrow then
		area.visible = false
	end
end

-- **Back goes where the page was opened from**: the pages behind the one
-- open, newest last, each a function that draws it again. The sidebar
-- starts a new trail.
local history = {}
local here = nil
local section = "home"
local draw_sidebar

local function go(page)
	if here then
		history[#history + 1] = here
	end
	here = page
	page()
end

local function back()
	local p = table.remove(history)
	if p then
		here = p
		p()
	elseif narrow then
		sidebar.visible = true
		area.visible = false
	end
end

local function enter(key, page)
	history = {}
	section = key
	here = page
	draw_sidebar()
	page()
end

-- The page open drawn again, as after an action that changed it
local function redraw()
	if here then
		here()
	end
end

-- The line under the title that says what a request said
local status = nil
say = function(t)
	if status and pcall(function() status:SetText(t) end) then
		status.visible = true
	else
		message = t
	end
	if scripted then
		log:info("hearth: said " .. t)
	end
end

-- Escape: a selected message let go, else Back
local selected = nil
local composer = nil
-- The open thread's list, laid out again as a message's actions show
local thread_list = nil

-- A page: the area emptied, Back (when there is somewhere to go back to),
-- the title and what the last request said
local function open(title)
	if not frame then
		build_frame()
	end
	if scripted then
		log:info("hearth: page " .. title)
	end
	area:RemoveAllChildren()
	selected, composer, thread_list = nil, nil, nil
	if narrow then
		sidebar.visible = false
		area.visible = true
	end
	local top = row(area)
	local tw = W
	if #history > 0 or narrow then
		local b = button(top, "Back", back)
		tw = W - b.minWidth - 4
	end
	-- The title wraps; the row is as tall as it
	local t = text(top, title, nil, tw, 16)
	top:SetFixedHeight(math.max(28, t.height))
	status = text(area, message or "", WARN, W)
	status.visible = message ~= nil
	message = nil
	return area
end

-- The height left in the area under what is on it, less `reserve`
local function room(reserve)
	local used = 0
	for i = 0, area:GetNumChildren() - 1 do
		local c = area:GetChild(i)
		if c and c.visible then
			used = used + c.height + 6
		end
	end
	return math.max(60, H - used - (reserve or 0))
end

-- The page's list: what is left of the area, the wheel over it scrolling
-- it and the keys' focus kept in view
local function list(reserve, options)
	options = options or {}
	options.wheel = options.wheel or 40
	options.follow_focus = true
	options.label_share = options.label_share or 0.5
	return ui.list_view(area, W, room(reserve), options)
end

-- A row of the list: a one-line button with its badge. `width`: the
-- list's, when it is not the page's.
local function add_row(v, label, badge, on_click, width)
	-- simplified: cut by a character's typical width, not measured
	local max = math.floor((width or W) * 0.5 / 10)
	if #label > max then
		label = label:sub(1, max - 3) .. "..."
	end
	local b = v:row({label = label}, badge)
	if on_click then
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	return b
end

-- A text row of the list, wrapped (an empty state, a note)
local function add_text(v, s, color)
	return text(v.list, s, color or DIM, W - 24)
end

-- A box of the list: a button holding a head line and a wrapped body,
-- inside an element that can hold more under it (a message's actions).
-- `name` goes on the head, which is how the box is known.
local function add_box(v, name, head, body, head_color, on_click)
	local holder = v.list:CreateChild("UIElement")
	holder:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	local b = holder:CreateChild("Button")
	b:SetStyleAuto()
	b:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(8, 4, 8, 6))
	text(b, head, head_color or DIM, W - 32):SetName(name or "")
	if body and body ~= "" then
		text(b, body, nil, W - 32)
	end
	if on_click then
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	return holder, b
end

--
-- What a thread is
--

-- What a thread is, as main.cpp's kind_text() says it: "problem, fixed in
-- 1.3", "patch, applied", "question", or "" for a discussion
local function kind_text(th)
	if th.kind ~= "problem" and th.kind ~= "patch" then
		return th.kind or ""
	end
	if th.status == "fixed" or th.status == "applied" then
		return th.kind .. ", " .. th.status ..
				(th.fixed_in ~= "" and " in " .. th.fixed_in or "")
	end
	return th.kind .. ", " .. (th.status == "wontfix" and "won't fix" or th.status)
end

-- The kinds of a new thread ([PACKAGE_SUBJECT]); a patch only in a
-- tracker topic ([HEARTH_TRACKER])
local KINDS = {{"", "a discussion"}, {"question", "a question"},
		{"problem", "a problem"}, {"idea", "an idea"}, {"patch", "a patch"}}

-- A thread's badge: what it is, answered, its messages, its last activity
local function thread_badge(th)
	local kind = kind_text(th)
	return (kind ~= "" and kind .. " · " or "") ..
			(th.answer ~= 0 and "answered · " or "") ..
			th.messages .. " · " .. ago(th.last)
end

local show_home, show_topic, show_thread, show_notifications, show_following
local show_search, show_account, show_compose, show_report, show_link
local show_queue, show_settings, show_tracker_link, show_topic_edit
local show_place, show_server, show_discussed, read_on

-- A thread's row; unread marked
local function thread_row(v, th)
	return add_row(v, (th.unread and "* " or "") .. th.title,
			thread_badge(th), function()
		go(function() show_thread(th.id) end)
	end)
end

-- Who this client is ("me"), the topic tree as last read, and the thread
-- open: the server pushes that thread's new messages ("hr:new"), which
-- are added to it in place
local me = {account = "", unseen = 0, level = 0, open_reports = 0}
local topics = {}
local open_thread = nil

--
-- The sidebar
--
local function side(label, key, count, page)
	count = tonumber(count) or 0
	local b = sidebar:CreateChild("Button")
	b:SetStyleAuto()
	b:SetFixedHeight(24)
	local t = text(b, label .. (count > 0 and " (" .. count .. ")" or ""),
			count > 0 and MAIN or nil)
	t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	t.position = magic.IntVector2(6, 0)
	-- The section shown: an arrow at the right, after the label, so the
	-- label does not move
	if key == section then
		local m = text(b, "►", t.color)
		m:SetAlignment(magic.HA_RIGHT, magic.VA_CENTER)
		m.position = magic.IntVector2(-6, 0)
	end
	magic.SubscribeToEvent(b, "Released", function()
		enter(key, page)
	end)
end

draw_sidebar = function()
	if not frame then
		build_frame()
	end
	sidebar:RemoveAllChildren()
	text(sidebar, "Hearth", nil, nil, 16)
	side("Home", "home", 0, function() show_home() end)
	side("Search", "search", 0, function() show_search("") end)
	side("Notifications", "notifications", me.unseen, function()
		show_notifications()
	end)
	side("Following", "following", 0, function() show_following() end)
	text(sidebar, "Topics", DIM)
	-- Each subtopic under its parent; the server gives the top level first.
	-- **A name cut at 12 characters with "…"** (user, 2026-10-07): the
	-- sidebar is narrow, and the topic's page has the whole name
	local function cut(name)
		local chars = {}
		for c in tostring(name):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
			chars[#chars + 1] = c
		end
		return #chars <= 12 and tostring(name) or
				table.concat(chars, "", 1, 11) .. "…"
	end
	local function topic(t, indent)
		side(indent .. cut(t.name), "topic " .. t.id, 0, function()
			show_topic(t.id)
		end)
	end
	for _, t in ipairs(topics) do
		if t.parent == 0 then
			topic(t, "")
			for _, s in ipairs(topics) do
				if s.parent == t.id then
					topic(s, "  ")
				end
			end
		end
	end
	if me.admin then
		text(sidebar, "Admin", DIM)
		side("Queue", "queue", me.open_reports, function() show_queue() end)
		side("Settings", "settings", 0, function() show_settings() end)
	end
	-- At its foot: who this is
	local gap = sidebar:CreateChild("UIElement")
	gap.minHeight = 8
	side(me.account .. (me.level == 0 and " (new)" or ""), "account", 0,
			function() show_account(me.account) end)
end

--
-- The pages
--

-- **Home**: what waits for this account, then the topics and the latest
show_home = function()
	open_thread = nil
	req("topics", nil, function(r)
		topics = r.topics
		req("following", nil, function(followed)
			local w = open("Hearth")
			draw_sidebar()
			local v = list()
			local waiting = false
			local function head()
				if not waiting then
					v:header("Waiting for you")
					waiting = true
				end
			end
			if me.unseen > 0 then
				head()
				add_row(v, me.unseen .. (me.unseen == 1 and " new notification" or
						" new notifications"), "", function()
					enter("notifications", function() show_notifications() end)
				end)
			end
			if me.admin and (me.open_reports or 0) > 0 then
				head()
				add_row(v, me.open_reports .. " reports open", "", function()
					enter("queue", function() show_queue() end)
				end)
			end
			for i, th in ipairs(followed) do
				if not th.unread or i > 5 then
					break
				end
				head()
				thread_row(v, th)
			end
			v:header("Topics")
			local names = {}
			for _, t in ipairs(topics) do
				names[t.id] = t.name
			end
			for _, t in ipairs(topics) do
				if t.parent == 0 then
					add_row(v, t.name, t.threads .. (t.threads == 1 and " thread" or " threads"), function()
						enter("topic " .. t.id, function() show_topic(t.id) end)
					end)
					for _, s in ipairs(topics) do
						if s.parent == t.id then
							add_row(v, "    " .. s.name, s.threads .. (s.threads == 1 and " thread" or " threads"),
									function()
								enter("topic " .. s.id, function()
									show_topic(s.id)
								end)
							end)
						end
					end
				end
			end
			v:header("Latest")
			for _, th in ipairs(r.latest) do
				add_row(v, (th.unread and "* " or "") .. th.title,
						(names[th.topic] or "") .. " · " .. thread_badge(th),
						function()
					go(function() show_thread(th.id) end)
				end)
			end
			v:fit()
		end)
	end)
end

show_notifications = function()
	open_thread = nil
	req("notifications", nil, function(items)
		me.unseen = 0
		open("Notifications")
		draw_sidebar()
		local v = list()
		local said = {reply = "replied in", mention = "mentioned you in",
				answer = "marked your message the answer in",
				hidden = "hid your message in",
				restored = "restored your message in",
				appeal_dismissed = "kept your message hidden in",
				status = "set the status of",
				fixed = "released a version that fixes"}
		for _, n in ipairs(items) do
			local _, b = add_box(v, nil, n.by .. " " .. (said[n.kind] or n.kind) ..
					" " .. n.title .. " · " .. ago(n.time), n.note,
					not n.seen and MAIN or nil, function()
				go(function() show_thread(n.thread, n.message) end)
			end)
		end
		if #items == 0 then
			add_text(v, "None yet. Replies in the threads you follow, " ..
					"mentions (@" .. me.account .. ") and answers come here.")
		end
		v:fit()
	end)
end

show_following = function()
	open_thread = nil
	req("following", nil, function(list_)
		open("Following")
		local v = list()
		for _, th in ipairs(list_) do
			thread_row(v, th)
		end
		if #list_ == 0 then
			add_text(v, "None. A thread you start or write in is followed, " ..
					"and Follow on a thread follows it.")
		end
		v:fit()
	end)
end

-- **A topic**: its threads, filtered and ordered here; a new thread on its
-- own page
local topic_view = {}
local ORDERS = {{"active", "active"}, {"new", "new"},
		{"unanswered", "unanswered first"}}
show_topic = function(id)
	open_thread = nil
	req("topic", {topic = id}, function(t)
		local w = open(t.name)
		if t.about ~= "" then
			text(w, t.about, DIM, W)
		end
		local state = topic_view[id] or {kind = "", order = "active"}
		topic_view[id] = state
		local bar = row(w)
		button(bar, "New thread...", function()
			go(function() show_compose({topic = id, tracker = t.tracker}) end)
		end, true)
		-- The kinds, or a tracker's statuses, that are there
		local kinds, seen = {{"", "everything"}}, {}
		for _, th in ipairs(t.threads) do
			local k = t.tracker and th.status ~= "" and th.status or th.kind
			if k ~= "" and not seen[k] then
				seen[k] = true
				kinds[#kinds + 1] = {k, k == "wontfix" and "won't fix" or k}
			end
		end
		local at = 1
		for i, k in ipairs(kinds) do
			if k[1] == state.kind then at = i end
		end
		cycle(bar, "Showing: ", kinds, at, function(k)
			state.kind = k
			redraw()
		end)
		local oat = 1
		for i, o in ipairs(ORDERS) do
			if o[1] == state.order then oat = i end
		end
		cycle(bar, "Order: ", ORDERS, oat, function(o)
			state.order = o
			redraw()
		end)
		if me.admin then
			button(bar, t.tracker and "Not a tracker" or "Make it a tracker",
					function()
				req("topic_tracker", {topic = id, on = not t.tracker}, redraw)
			end)
			-- [DISCUSS_SERVER] Where the client's Discuss on a server
			-- starts its thread; a Hearth older than that has no category
			if t.category then
				button(bar, t.category == "servers" and
						"Not for servers' threads" or "For servers' threads",
						function()
					req("topic_category", {topic = id, category =
							t.category == "servers" and "" or "servers"}, redraw)
				end)
			end
		end
		local shown = {}
		for _, th in ipairs(t.threads) do
			local k = t.tracker and th.status ~= "" and th.status or th.kind
			if state.kind == "" or k == state.kind then
				shown[#shown + 1] = th
			end
		end
		table.sort(shown, function(a, b)
			if state.order == "new" then
				return a.created > b.created
			elseif state.order == "unanswered" and
					(a.answer == 0) ~= (b.answer == 0) then
				return a.answer == 0
			end
			return a.last > b.last
		end)
		local v = list()
		for _, th in ipairs(shown) do
			thread_row(v, th)
		end
		if #shown == 0 then
			add_text(v, #t.threads == 0 and "No threads yet." or
					"Nothing here is that.")
		end
		v:fit()
	end, function(why)
		say(why)
	end)
end

-- **A thread**: a header, the messages as boxes, the reply at the foot. A
-- message's actions show under it while it is selected (user, 2026-10-06:
-- reading stays uncluttered). `at`: a message to open at, else the first
-- unread, else the end.
show_thread = function(id, at)
	req("thread", {thread = id}, function(t)
		local w = open(t.title)
		local info = kind_text(t)
		info = (info ~= "" and info .. (t.version ~= "" and
				", reported in " .. t.version or "") .. " · " or "") ..
				"in " .. (function()
					for _, x in ipairs(topics) do
						if x.id == t.topic then return x.name end
					end
					return "topic " .. t.topic
				end)() .. " · " .. t.author .. " · " .. ago(t.created)
		text(w, info, DIM, W)
		if t.link ~= "" then
			text(w, "Tracker: " .. t.link, DIM, W)
		elseif t.link_waiting ~= "" then
			text(w, "Tracker: " .. t.link_waiting ..
					" (its domain waits for a moderator)", WARN, W)
		end
		local bar = row(w)
		button(bar, t.following and "Stop following" or "Follow", function()
			req("follow", {thread = id, on = not t.following}, redraw)
		end)
		local mine = t.author == me.account or me.admin
		if t.subject ~= "" then
			local pkg = t.subject:match("^(%S+)") or t.subject
			button(bar, "About " .. pkg, function()
				go(function() show_place({subject = t.subject, package = pkg}) end)
			end)
		elseif mine then
			button(bar, "About a package...", function()
				go(function() show_link(t) end)
			end)
		end
		if t.ticket and mine then
			button(bar, "Tracker link...", function()
				go(function() show_tracker_link(t) end)
			end)
		end
		-- A problem's or a patch's status, the admin's to set
		-- ([PACKAGE_SUBJECT], [HEARTH_TRACKER])
		if (t.kind == "problem" or t.kind == "patch") and me.admin then
			local list_ = t.kind == "patch" and {"open", "applied", "wontfix"} or
					{"open", "confirmed", "fixed", "wontfix"}
			local choices, sat = {}, 1
			for i, s in ipairs(list_) do
				choices[i] = {s, s == "wontfix" and "won't fix" or s}
				if s == t.status then sat = i end
			end
			local fixed_in
			local pick = cycle(bar, "Status: ", choices, sat)
			fixed_in = bar:CreateChild("LineEdit")
			fixed_in:SetStyleAuto()
			fixed_in:SetFixedWidth(70)
			fixed_in:SetText(t.fixed_in or "")
			button(bar, "Set", function()
				local to = pick()
				req("status", {thread = id, status = to, fixed_in =
						(to == "fixed" or to == "applied") and
						fixed_in:GetText() or ""}, redraw)
			end)
		end
		-- The reply's room is kept at the foot: the field, its label and
		-- its buttons
		local v = list(165, {spacing = 6})
		thread_list = v
		t.first = t.list[1] and t.list[1].id or 0
		local boxes = {}
		local new_line = false
		local function add_message(m, is_answer)
			if not is_answer and t.read > 0 and m.id > t.read and not new_line and
					m.author ~= me.account then
				new_line = true
				boxes.new = v:header("New since you were here", nil, "main")
			end
			local head = (is_answer and "This answered it -- " or "") .. m.author ..
					" · " .. ago(m.created) .. (m.edited ~= 0 and " · edited" or "")
			local body = m.body
			if m.hidden then
				body = "Hidden by a moderator: " .. m.hidden_reason ..
						(body ~= "" and "\n\n" .. body or "")
			end
			for _, p in ipairs(m.patches or {}) do
				body = body .. "\n\n" .. p.name .. "\n" .. p.text
			end
			local holder = add_box(v, "m" .. m.id, head, body,
					is_answer and MAIN or nil)
			-- Its actions, shown while it is selected
			local acts = holder:CreateChild("UIElement")
			acts:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(8, 0, 0, 2))
			acts:SetName("acts" .. m.id)
			acts.visible = false
			local function action(label, fn)
				button(acts, label, fn):SetName("a" .. m.id)
			end
			action("Quote", function()
				if composer then
					local first = (m.body:match("^[^\n]*") or ""):sub(1, 120)
					insert_at_cursor(composer, "> " .. m.author .. ": " ..
							first .. "\n\n")
				end
			end)
			if (m.author == me.account and not m.hidden) or me.admin then
				action("Edit", function()
					go(function() show_compose({edit = m, thread = id}) end)
				end)
			end
			if m.hidden and m.author == me.account then
				action("Appeal", function()
					go(function() show_report(m, "appeal") end)
				end)
			elseif not m.hidden and m.author ~= me.account then
				action("Report", function()
					go(function() show_report(m, "report") end)
				end)
			end
			if m.id ~= t.first and (t.author == me.account or me.admin) then
				local is = t.answer == m.id
				action(is and "Not the answer" or "This answered it",
						function()
					req("answered", {thread = id, message = is and 0 or m.id},
							redraw)
				end)
			end
			action("Copy #" .. id, function()
				magic.ui:SetClipboardText("#" .. id)
			end)
			boxes[m.id] = holder
		end
		-- The question, its answer, then the rest in order
		local answer = nil
		for _, m in ipairs(t.list) do
			if m.id == t.answer then
				answer = m
			end
		end
		for i, m in ipairs(t.list) do
			if m ~= answer then
				add_message(m, false)
			end
			if i == 1 and answer then
				add_message(answer, true)
			end
		end
		v:fit()
		-- Where it opens: at the message asked for, else at what is new,
		-- else at the end
		local function place()
			local target = at and boxes[at]
			if target then
				v:scroll(-1000000)
				v:show(target)
				local b = target:GetChild(0)
				if b then
					b:SetFocus(true)
				end
				at = nil
			elseif boxes.new then
				v:scroll(-1000000)
				v:scroll(boxes.new.position.y)
			else
				v:scroll(1000000)
			end
		end
		place()
		open_thread = {id = id, last = t.list[#t.list] and t.list[#t.list].id or 0,
				append = function(list_)
			for _, m in ipairs(list_) do
				add_message(m, false)
				open_thread.last = m.id
			end
			v:fit()
			if at then
				place()
			else
				v:scroll(1000000)
			end
		end}
		if t.more then
			read_on(open_thread)
		end
		-- The reply, at the foot
		local key = "reply " .. id
		local e = edit(w, "Reply (Markdown; Ctrl+Enter sends)", true, key, W)
		composer = e
		local preview = nil
		local function send()
			if e:GetText() == "" then
				return
			end
			-- It comes back as "hr:new", as anyone else's does
			req("reply", {thread = id, body = e:GetText()}, function()
				drafts[key] = nil
				pcall(function() e:SetText("") end)
			end)
		end
		magic.SubscribeToEvent(e, "TextFinished", send)
		markup_buttons(w, e, function(s)
			-- The preview as the list's last box, until it is sent
			if preview then
				pcall(function() preview:Remove() end)
			end
			preview = add_box(v, nil, "Preview", s, MAIN)
			v:fit()
			v:scroll(1000000)
		end, function(r)
			button(r, "Send", send, true)
		end)
		-- A touchscreen's keyboard would cover the thread: it opens on a tap
		if buildat.get_env("BUILDAT_TOUCH") ~= "1" and not at then
			e:SetFocus(true)
		end
	end, function(why)
		say(why)
	end)
end

-- The open thread's messages after the last one it has, a part ("more")
-- at a time
read_on = function(o)
	req("thread", {thread = o.id, after = o.last}, function(t)
		if open_thread == o then
			o.append(t.list)
			if t.more then
				read_on(o)
			end
		end
	end)
end

-- The selected message: the one whose box, or one of whose actions, has
-- the focus; its actions shown, the others' hidden
magic.SubscribeToEvent("Update", function()
	if not area or not open_thread then
		return
	end
	local f = magic.ui.focusElement
	local id = nil
	if f then
		-- A box's head is named m<id>, an action a<id> (a script's element
		-- has no parent to read)
		local ok, name = pcall(function()
			local h = f:GetChild(0)
			return (h and h:GetName() or "") .. " " .. f:GetName()
		end)
		id = ok and (name:match("^m(%d+) ") or name:match(" a(%d+)$"))
	end
	if id == selected then
		return
	end
	local function acts(i, on)
		if not i then
			return
		end
		-- The actions are the holder's second child, named acts<id>
		local function find(e)
			for k = 0, e:GetNumChildren() - 1 do
				local c = e:GetChild(k)
				if c and c:GetName() == "acts" .. i then
					c.visible = on
					return true
				end
				if c and c:GetTypeName() == "UIElement" and find(c) then
					return true
				end
			end
		end
		pcall(find, area)
	end
	acts(selected, false)
	selected = id
	acts(selected, true)
	if thread_list then
		thread_list:fit()
	end
end)

-- [ESC_ACCOUNT]: Escape is an accounts page's Back, the thread's
-- composer, a page's Back, and at the top My account, as the top right
-- Account button (user, 2026-10-07)
magic.SubscribeToEvent("KeyDown", function(_, d)
	if not frame or not frame.visible or
			d:GetInt("Key") ~= magic.KEY_ESCAPE then
		return
	end
	if accounts.page then
		accounts.back()
	elseif area.visible and selected and composer then
		composer:SetFocus(true)
	elseif area.visible and (#history > 0 or narrow) then
		back()
	else
		accounts.show_account()
	end
end)

-- **Compose**: a new thread (`o.topic`, `o.tracker`), feedback about a
-- package (`o.feedback`), or an edit (`o.edit`, a message of `o.thread`);
-- the preview beside the message on a wide page, under it on a narrow one,
-- refreshed a second after the typing stops
show_compose = function(o)
	open_thread = nil
	local title, key
	if o.edit then
		title, key = "Edit your message", "edit " .. o.edit.id
	elseif o.feedback then
		title, key = "Feedback about " .. o.feedback.package .. " " ..
				o.feedback.version, "feedback " .. o.feedback.subject
	elseif o.server then
		title, key = "A thread about " .. (o.server.address or o.server.name),
				"server " .. o.server.subject
	else
		title, key = "A new thread", "new " .. (o.topic or 0)
	end
	local w = open(title)
	if o.feedback then
		text(w, "Goes to this Hearth's Feedback topic, which its makers read",
				DIM, W)
	elseif o.game then
		text(w, "Goes to this Hearth's topic for games" ..
				(o.server.source == "unknown" and "; where it came from " ..
				"is not known" or ""),
				DIM, W)
	elseif o.server then
		text(w, "Goes to this Hearth's topic for servers", DIM, W)
	end
	local title_e, kind, topic_pick
	if not o.edit then
		title_e = edit(w, "Title", false, key .. " title", W)
		if o.server and not drafts[key .. " title"] then
			title_e:SetText(o.server.title)
			if scripted then
				log:info("hearth: title " .. o.server.title)
			end
		end
		local bar = row(w)
		local tracker = o.tracker
		if not o.feedback and not o.server then
			-- The topic, picked here when the page did not come from one
			local choices, at, names = {}, 1, {}
			for _, t in ipairs(topics) do
				names[t.id] = t.name
			end
			for _, t in ipairs(topics) do
				choices[#choices + 1] = {t.id, (t.parent ~= 0 and
						(names[t.parent] or "") .. " / " or "") .. t.name}
				if t.id == o.topic then
					at = #choices
				end
			end
			if #choices > 0 then
				topic_pick = cycle(bar, "In: ", choices, at)
			end
		end
		local kinds = {}
		for i, k in ipairs(KINDS) do
			if k[1] ~= "patch" or tracker then
				kinds[#kinds + 1] = {k[1], "It is " .. k[2]}
			end
		end
		kind = cycle(bar, "", kinds, o.feedback and 3 or 1)
	end
	-- The field the page's width; the preview under it once Preview is
	-- pressed, as a reply's ([HEARTH_NEW_PREVIEW]: beside it, it halved
	-- the field)
	local body = edit(w, "The message (Markdown)", true, key, W)
	body:SetFixedHeight(W >= 600 and 200 or 120)
	if o.edit and not drafts[key] then
		body:SetText(o.edit.body)
	elseif o.feedback and not drafts[key] then
		local f = o.feedback
		body:SetText("App: " .. f.package .. " " .. f.version .. "\nEngine: " ..
				f.engine .. "\nPlatform: " .. f.platform .. "\n\n")
	end
	local pv, shown = nil, nil
	local function show(s)
		pcall(function()
			-- What is left of the page under the buttons
			pv = pv or list()
			if shown then
				shown:Remove()
			end
			shown = add_box(pv, nil, "Preview", s, MAIN)
			pv:fit()
		end)
		if scripted then
			log:info("hearth: preview " .. s)
		end
	end
	local function submit()
		local b = body:GetText()
		local function done(new_id)
			drafts[key], drafts[key .. " title"] = nil, nil
			-- In place of this page; an edit's thread is the one behind it
			if o.edit then
				table.remove(history)
			end
			here = function() show_thread(o.thread or new_id) end
			here()
		end
		if o.edit then
			req("edit", {message = o.edit.id, body = b}, function() done() end)
		elseif o.server then
			req("new_thread", {server = not o.game, game = o.game == true,
					subject = o.server.subject,
					title = title_e:GetText(), body = b, kind = kind()}, done)
		elseif o.feedback then
			local f = o.feedback
			req("new_thread", {feedback = true, subject = f.subject,
					title = title_e:GetText(), body = b, kind = kind(),
					-- one the server would refuse leaves the report without it
					version = #f.version <= 40 and
							f.version:match("^[%w%.%+_%-]+$") or nil}, done)
		else
			req("new_thread", {topic = topic_pick and topic_pick() or o.topic,
					title = title_e:GetText(), body = b, kind = kind()}, done)
		end
	end
	markup_buttons(w, body, show, function(r)
		button(r, o.edit and "Save" or o.feedback and "Send" or
				"Start the thread", submit, true)
	end)
	-- A second after the last key, a preview shown again
	local changed = nil
	magic.SubscribeToEvent(body, "TextChanged", function()
		changed = buildat.get_time_us()
	end)
	local sub
	sub = magic.SubscribeToEvent("Update", function()
		if not pcall(function() return body.visible end) then
			magic.UnsubscribeFromEvent("Update", sub)
			return
		end
		if pv and changed and buildat.get_time_us() - changed > 1e6 then
			changed = nil
			req("preview", {body = body:GetText()}, function(h)
				local s = html_text(tostring(h))
				show(s ~= "" and s or "(nothing)")
			end, function(why) show("No preview: " .. why) end)
		end
	end)
	if title_e then
		title_e:SetFocus(true)
	else
		body:SetFocus(true)
	end
end

-- **Search**: Enter searches (the server allows 30 a minute); the threads
-- found, then the messages
local last_query = ""
show_search = function(q)
	open_thread = nil
	local function draw(results)
		local w = open("Search")
		local e = edit(w, nil, false, nil, W)
		e:SetText(q)
		magic.SubscribeToEvent(e, "TextFinished", function()
			last_query = e:GetText()
			here = function() show_search(last_query) end
			here()
		end)
		local v = list()
		if results then
			local threads, seen = {}, {}
			for _, r in ipairs(results) do
				if not seen[r.thread] then
					seen[r.thread] = true
					threads[#threads + 1] = r
				end
			end
			if #threads > 0 then
				v:header(#results .. " messages in " .. #threads .. " threads")
				for _, r in ipairs(threads) do
					add_row(v, r.title, "", function()
						go(function() show_thread(r.thread) end)
					end)
				end
				v:header("Messages")
				for _, r in ipairs(results) do
					local snip = r.snippet:gsub("[\1\2]", "")
					add_box(v, nil, r.title .. " · " .. r.author .. " · " ..
							ago(r.created), snip, nil, function()
						go(function() show_thread(r.thread, r.message) end)
					end)
				end
			else
				add_text(v, "Nothing matches \"" .. q .. "\".")
			end
		else
			add_text(v, "Words in titles and messages; the last word may be " ..
					"the start of one. Enter searches.")
		end
		v:fit()
		e:SetFocus(true)
	end
	if q == "" then
		return draw(nil)
	end
	req("search", {q = q}, draw)
end

-- **An account**: its level, to its owner what lifts a new account's
-- limits, and its last messages
show_account = function(name)
	open_thread = nil
	req("account", {name = name}, function(a)
		local w = open(a.name)
		text(w, a.level == 2 and "The admin" or a.level == 1 and
				"A member" or "A new account", DIM, W)
		if a.trust and a.level == 0 then
			local tr = a.trust
			text(w, "A new account posts less and no links until it has " ..
					"been active on five days -- a day it read a thread or " ..
					"wrote a message that stands, counted once the day is " ..
					"over (" .. (tr.days or 0) .. " so far) -- with none of " ..
					"its messages hidden in 30 days (" .. tr.hidden ..
					" hidden).", nil, W)
		end
		local v = list()
		for _, m in ipairs(a.messages) do
			add_box(v, nil, m.title .. " · " .. ago(m.created), m.body, nil,
					function()
				go(function() show_thread(m.thread, m.message) end)
			end)
		end
		if #a.messages == 0 then
			add_text(v, "Nothing written here.")
		end
		v:fit()
	end, function(why)
		say(why)
	end)
end

-- Which package a thread is about, out of those released here
show_link = function(t)
	open_thread = nil
	req("subjects", nil, function(subjects)
		open("What is \"" .. t.title .. "\" about?")
		local v = list()
		for _, s in ipairs(subjects) do
			local pkg, key = s:match("^(%S+) (%x*)")
			add_row(v, pkg or s, "key " .. (key or ""):sub(1, 12) .. "...",
					function()
				req("link", {thread = t.id, subject = s}, back)
			end)
		end
		if #subjects == 0 then
			add_text(v, "No package has a release here yet.")
		end
		v:fit()
	end)
end

-- A ticket's tracker link, by whoever started it or the admin
-- ([HEARTH_TRACKER])
show_tracker_link = function(t)
	open_thread = nil
	local w = open("Tracker link")
	local link = edit(w, "A branch, a pull request, an issue elsewhere", false,
			nil, W)
	link:SetText(t.link ~= "" and t.link or t.link_waiting)
	button(w, "Set", function()
		req("tracker_link", {thread = t.id, link = link:GetText()}, back)
	end, true)
	link:SetFocus(true)
end

-- A report of someone's message, or an appeal of one's own hidden one
show_report = function(m, kind)
	open_thread = nil
	local w = open(kind == "appeal" and "Appeal: why it should be shown" or
			"Report: what is wrong with it")
	text(w, m.author .. ": " .. m.body, DIM, W)
	local e = edit(w, kind == "appeal" and "Your appeal" or "The reason",
			false, nil, W)
	button(w, "Send", function()
		req(kind, {message = m.id, [kind == "appeal" and "text" or "reason"] =
				e:GetText()}, function()
			message = kind == "appeal" and "The appeal is waiting for the admin." or
					"Reported; the admin will look at it."
			back()
		end)
	end, true)
	e:SetFocus(true)
end

-- **The admin's queue**: open reports (hide or dismiss), appeals (restore
-- or dismiss) and tracker domains (accept or dismiss) as rows; the one
-- picked in the panel beside them (under them on a narrow page), with the
-- statement of reasons its author is shown
show_queue = function()
	open_thread = nil
	req("queue", nil, function(items)
		me.open_reports = #items
		local w = open("Moderation")
		draw_sidebar()
		local wide = W >= 600
		local body = w:CreateChild("UIElement")
		body:SetLayout(wide and magic.LM_HORIZONTAL or magic.LM_VERTICAL, 8,
				magic.IntRect(0, 0, 0, 0))
		local lw = wide and math.floor(W * 0.45) or W
		local pw = (wide and W - lw - 8 or W) - 32
		local v = ui.list_view(body, lw, wide and room() or
				math.floor(room() / 2), {wheel = 40, follow_focus = true,
				label_share = 0.5})
		local panel = body:CreateChild("UIElement")
		panel:SetLayout(magic.LM_VERTICAL, 6, magic.IntRect(0, 0, 0, 0))
		panel:SetFixedWidth(pw)
		local function pick(r)
			panel:RemoveAllChildren()
			local function act(action, statement)
				req("moderate", {report = r.id, action = action,
						statement = statement and statement:GetText() or ""},
						redraw)
			end
			if r.kind == "domain" then
				text(panel, "Tracker domain " .. r.reason .. ", linked by " ..
						r.by .. " in " .. r.title, WARN, pw)
				local b = row(panel)
				button(b, "Accept the domain", function() act("accept") end)
				button(b, "Dismiss", function() act("dismiss") end)
				return
			end
			text(panel, (r.kind == "appeal" and "Appeal by " or "Report by ") ..
					r.by .. " in " .. r.title .. ": " .. r.reason, WARN, pw)
			if r.kind == "appeal" then
				text(panel, "Hidden for: " .. r.hidden_reason, DIM, pw)
			end
			text(panel, r.author .. ": " .. r.body, nil, pw)
			local statement = edit(panel, "Reasons (shown to the author)", false,
					nil, pw)
			local b = row(panel)
			if r.kind == "appeal" then
				button(b, "Restore", function() act("restore", statement) end)
				button(b, "Keep it hidden", function()
					act("dismiss", statement)
				end)
			else
				button(b, "Hide", function() act("hide", statement) end)
				button(b, "Dismiss", function() act("dismiss", statement) end)
			end
		end
		for _, r in ipairs(items) do
			local label = r.kind == "domain" and "Domain " .. r.reason or
					(r.kind == "appeal" and "Appeal: " or "Report: ") .. r.title
			add_row(v, label, r.by, function() pick(r) end, lw)
		end
		if #items == 0 then
			text(v.list, "Nothing open.", DIM, lw - 8)
		end
		v:fit()
		if items[1] then
			pick(items[1])
		end
	end)
end

-- **The admin's settings**: the topics, the tracker domains, the Aittas
-- releases are read from, and the files' budget
show_settings = function()
	open_thread = nil
	req("tracker_domains", nil, function(domains)
		req("release_sources", {}, function(sources)
			req("file_settings", {}, function(files)
				local w = open("Settings")
				local v = list()
				v:header("Topics")
				for _, t in ipairs(topics) do
					add_row(v, (t.parent ~= 0 and "    " or "") .. t.name,
							t.tracker and "tracker" or "", function()
						go(function() show_topic_edit(t) end)
					end)
				end
				add_row(v, "New topic...", "", function()
					go(function() show_topic_edit(nil) end)
				end)
				v:header("Tracker domains (a link to one is shown whoever " ..
						"posted it)")
				for _, d in ipairs(domains) do
					add_row(v, d, "remove", function()
						req("tracker_domains", {remove = {d}}, redraw)
					end)
				end
				local dr = row(v.list)
				local de = edit(dr, nil, false, nil, 240)
				button(dr, "Add the domain", function()
					req("tracker_domains", {add = {de:GetText()}}, redraw)
				end)
				-- A list of addresses as one line, spaces between
				local function addresses(label, k)
					local r = row(v.list)
					local l = text(r, label, nil)
					l.minWidth = 160
					local e = edit(r, nil, false, nil, W - 160 - 70)
					e:SetText(table.concat(sources[k] or {}, " "))
					button(r, "Save", function()
						local list_ = {}
						for a in e:GetText():gmatch("%S+") do
							list_[#list_ + 1] = a
						end
						req("release_sources", {[k] = list_}, function()
							say("Saved.")
						end)
					end)
				end
				v:header("Releases (from the Aittas named, for this " ..
						"Hearth's addresses)")
				addresses("Aittas", "aittas")
				addresses("This Hearth's", "addresses")
				v:header("Files (bytes; seconds unused)")
				for _, k in ipairs({"budget", "lod2_after", "delete_after"}) do
					local r = row(v.list)
					local l = text(r, k, nil)
					l.minWidth = 160
					local e = edit(r, nil, false, nil, 200)
					e:SetText(tostring(files[k] or ""))
					button(r, "Save", function()
						req("file_settings", {[k] = tonumber(e:GetText())},
								function() say("Saved.") end)
					end)
				end
				local fr = row(v.list)
				local fe = edit(fr, nil, false, nil, 120)
				button(fr, "Delete the file (an upheld claim)", function()
					req("delete_file", {file = tonumber(fe:GetText()) or 0},
							function() say("Deleted.") end)
				end)
				v:fit()
			end)
		end)
	end)
end

-- A topic's name and what it is about; a new one's parent (one level of
-- subtopics)
show_topic_edit = function(t)
	open_thread = nil
	local w = open(t and "Topic: " .. t.name or "New topic")
	local name = edit(w, "Name (80 bytes at most)", false, nil, W)
	local about = edit(w, "What it is about (optional)", false, nil, W)
	local parent
	if t then
		name:SetText(t.name)
		about:SetText(t.about)
	else
		local parents = {{0, "none, a top-level topic"}}
		for _, x in ipairs(topics) do
			if x.parent == 0 then
				parents[#parents + 1] = {x.id, x.name}
			end
		end
		parent = cycle(w, "Under: ", parents, 1)
	end
	button(w, t and "Save" or "Create", function()
		local function done()
			req("topics", nil, function(r)
				topics = r.topics
				draw_sidebar()
				back()
			end)
		end
		if t then
			req("edit_topic", {topic = t.id, name = name:GetText(),
					about = about:GetText()}, done)
		else
			req("new_topic", {name = name:GetText(), about = about:GetText(),
					parent = parent()}, done)
		end
	end, true)
	name:SetFocus(true)
end

-- **A package's place** ([PACKAGE_SUBJECT]): "Discuss" on Aitta's list
-- came here; the threads about the package, and the way to report one
show_place = function(f)
	open_thread = nil
	req("subject", {subject = f.subject}, function(threads)
		local w = open(f.package .. " on this Hearth")
		if f.version then
			button(w, "Report a problem or give feedback...", function()
				go(function() show_compose({feedback = f}) end)
			end, true)
		end
		local v = list()
		for _, th in ipairs(threads) do
			thread_row(v, th)
		end
		if #threads == 0 then
			add_text(v, "Nothing about it here yet.")
		end
		v:fit()
	end)
end

-- **A server the player was on** ([DISCUSS_SERVER]), or with `game` a game
-- they played ([OVERLAY_DISCUSS]): the client's Discuss came here. Its
-- thread, by the subject Hearth gave it; with none, the threads whose
-- words match its name to pick from, or straight to a new one, titled
-- with the name (and a server's address)
show_server = function(d, game)
	open_thread = nil
	-- In place of this page, which Back would only bring here again
	local function instead(page)
		here = page
		page()
	end
	local function compose()
		instead(function() show_compose({server = d, game = game}) end)
	end
	req("subject", {subject = d.subject}, function(threads)
		if #threads > 0 then
			return instead(function() show_thread(threads[1].id) end)
		end
		local q = d.name:gsub("[^%w%s]", " "):match("^%s*(.-)%s*$")
		if q == "" then
			return compose()
		end
		req("search", {q = q}, function(results)
			if #results == 0 then
				return compose()
			end
			local w = open(d.title)
			button(w, "Start a thread about it...", function()
				go(function() show_compose({server = d, game = game}) end)
			end, true)
			local v = list()
			v:header("Threads that may be about it")
			local seen = {}
			for _, r in ipairs(results) do
				if not seen[r.thread] then
					seen[r.thread] = true
					add_row(v, r.title, "", function()
						go(function() show_thread(r.thread) end)
					end)
				end
			end
			v:fit()
		end, compose)
	end)
end

-- The server, the game or both from the client's Discuss: with both,
-- which one the player means is theirs to say
local function show_game(g)
	g.title = g.title or g.name
	if g.package then
		-- An Aitta package's place ([PACKAGE_SUBJECT])
		show_place(g)
	else
		show_server(g, true)
	end
end
show_discussed = function(dd)
	if not (dd.server and dd.game) then
		if dd.server then
			return show_server(dd.server)
		end
		return show_game(dd.game)
	end
	open_thread = nil
	local w = open("What is it about?")
	button(row(w), "About this server, " .. dd.server.title, function()
		go(function() show_server(dd.server) end)
	end)
	button(row(w), "About " .. dd.game.name, function()
		go(function() show_game(dd.game) end)
	end)
	-- What is left of the page
	w:CreateChild("UIElement")
end

buildat.sub_packet("hr:new", function(data)
	local v = buildat.parse_json(data)
	if type(v) ~= "table" or not open_thread or v.thread ~= open_thread.id then
		return
	end
	read_on(open_thread)
end)

buildat.sub_packet("hr:notify", function(data)
	local v = buildat.parse_json(data)
	if type(v) ~= "table" then
		return
	end
	if scripted then
		log:info("hr notify: " .. data)
	end
	me.unseen = tonumber(v.unseen) or 0
	if frame then
		draw_sidebar()
	end
end)

accounts.on_joined = function()
	-- This client is sent to every Buildat; one from before 0.6.56 has no
	-- list_view in its ui_utils
	if not ui.list_view then
		local w = accounts.page_window(600)
		w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
		text(w, "This Hearth needs a newer Buildat. Update it to use it.",
				WARN, 568)
		return
	end
	req("me", nil, function(r)
		me = r
		clock.server, clock.at = tonumber(r.now) or 0, buildat.get_time_us()
		req("topics", nil, function(tr)
			topics = tr.topics
			draw_sidebar()
			-- BUILDAT_HEARTH_OPEN=<thread>: a scripted client opens it, as a
			-- click on it would
			local open_ = tonumber(buildat.get_env("BUILDAT_HEARTH_OPEN") or "")
			-- **"Feedback..." on an app** ([PACKAGE_SUBJECT]): the launch grid
			-- came here with the app's package and versions, which start the
			-- message and go with the thread as its subject
			local f = buildat.feedback()
			-- [OVERLAY_DISCUSS] or [DISCUSS_SERVER]; a client from before
			-- them has neither
			local dd = buildat.discussed and buildat.discussed()
			if not dd and buildat.discussed_server then
				local ds = buildat.discussed_server()
				dd = ds and {server = ds}
			end
			if dd then
				if scripted then
					log:info("hr discuss: " .. encode(dd))
				end
				here = function() show_home() end
				go(function() show_discussed(dd) end)
			elseif f then
				if scripted then
					log:info("hr feedback: " .. encode(f))
				end
				here = function() show_home() end
				if f.place then
					go(function() show_place(f) end)
				else
					go(function() show_compose({feedback = f}) end)
				end
			elseif open_ then
				here = function() show_home() end
				go(function() show_thread(open_) end)
			else
				enter("home", function() show_home() end)
			end
			-- After the page's own requests, so a scripted "thread" is the
			-- one left open; numbered from 1001
			local script = buildat.get_env("BUILDAT_HEARTH_REQS") or ""
			local i = 1000
			for line in script:gmatch("[^\n]+") do
				local q = buildat.parse_json(line)
				if type(q) == "table" then
					i = i + 1
					q.id = i
					buildat.send_packet("hr:req", encode(q))
				end
			end
		end)
	end)
end

accounts.start({title = "Hearth", env = "BUILDAT_HEARTH"})
-- vim: set noet ts=4 sw=4:
