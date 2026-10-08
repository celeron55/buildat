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

-- JSON out; in is buildat.parse_json
local encode = require("buildat/extension/network").write_json

-- BUILDAT_HEARTH_RESUME=1 logs as a scripted client does, for its check
local scripted = (buildat.get_env("BUILDAT_HEARTH_REQS") or "") ~= "" or
		(buildat.get_env("BUILDAT_HEARTH_OPEN") or "") ~= "" or
		buildat.get_env("BUILDAT_HEARTH_RESUME") == "1"
-- What the last request said, for the page drawn next; say() puts it on
-- the page open
local message = nil
local say

-- on(result); on_error(why): instead of the reason said on the page open,
-- where what was typed stays
local req = accounts.requester("hr", function(why) say(why) end, scripted)

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

-- **New posts, marked where they are** ([HEARTH_NEW_MARKS]): the HTML
-- face's blobs after a thread's or a topic's name -- ● for a message within
-- a day, • within a week, nothing older; amber when unread to this account
-- and then • however old, the brand's cyan when not. {glyph, colour name}.
-- simplified: by the sizes and colours alone, no count.
local function mark_for(last, unread, at)
	local age = (at or now()) - (tonumber(last) or 0)
	return {age < 86400 and "●" or (age < 7 * 86400 or unread) and "•" or "",
			unread and "main" or "focus"}
end
assert(mark_for(0, false, 3600)[1] == "●" and
		mark_for(0, true, 8 * 86400)[1] == "•" and
		mark_for(0, false, 8 * 86400)[1] == "" and
		mark_for(0, true, 0)[2] == "main")

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
-- gets the preview's text. `extra` adds the row's first buttons (Send):
-- first, as a phone's page cuts the row's end ([PLAYTEST_1008])
local function markup_buttons(parent, e, show, extra)
	local r = row(parent)
	if extra then
		extra(r)
	end
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
-- ("reply 12", "new 3", "edit 40"), so Back or a page drawn again loses
-- nothing; and kept on the client with the page open ([HEARTH_RESUME],
-- below), so a closed tab or a server's restart loses neither
local drafts, draft_times = {}, {}
-- [HEARTH_RESUME] The page open as data: {kind = "thread", id, topic,
-- scroll}, {kind = "topic", id} or {kind = "compose", topic, tracker};
-- nil for the rest, which start at the top
local place = nil
local state_dirty = false
-- A kept thread's scroll, for show_thread to put it back
local restore_scroll = nil
local function state_changed() state_dirty = true end

-- A field; multi: a message's, where Enter breaks the line and Ctrl+Enter
-- finishes. `draft` names its draft.
-- on_change: called on TextChanged after the draft is kept; a second
-- subscription to it would replace this one's
local function edit(parent, label, multi, draft, width, on_change)
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
	end
	if draft or on_change then
		magic.SubscribeToEvent(e, "TextChanged", function()
			if draft then
				drafts[draft] = e:GetText()
				draft_times[draft] = buildat.get_time_us() / 1e6
				state_changed()
			end
			if on_change then
				on_change()
			end
		end)
	end
	return e
end

-- A choice of one from `choices` ({value, label}), as a dropdown with
-- `prefix` before it; returns a function giving the value picked
local function choice(parent, prefix, choices, at, on_change)
	at = at or 1
	local list = {}
	for i, c in ipairs(choices) do
		list[i] = {c[2], c[1]}
	end
	ui.dropdown(parent, list, choices[at][1], function(v, i)
		at = i
		if on_change then
			on_change(v)
		end
	end, {label = prefix ~= "" and prefix:gsub(" $", "") or nil})
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
	place = nil
	state_changed()
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
-- A touchscreen: Escape there is the browser's Back, which goes back
local touch = buildat.get_env("BUILDAT_TOUCH") == "1"
-- The open thread's list, laid out again as a message's actions show
local thread_list = nil

-- The marks drawn, so that "hr:activity" changes them in place: the
-- page's and the sidebar's, each by "t<thread>" or "c<topic>" to
-- {element, ..., unread = }
local marks = {page = {}, side = {}}

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
	marks.page = {}
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
local function add_row(v, label, badge, on_click, width, mark)
	-- simplified: cut by a character's typical width, not measured
	local max = math.floor((width or W) * 0.5 / 10)
	if #label > max then
		label = label:sub(1, max - 3) .. "..."
	end
	local b, m = v:row({label = label, mark = mark}, badge)
	if on_click then
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	return b, m
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
	local h = text(b, head, head_color or DIM, W - 32)
	h:SetName(name or "")
	if body and body ~= "" then
		text(b, body, nil, W - 32)
	end
	if on_click then
		magic.SubscribeToEvent(b, "Released", function() on_click() end)
	end
	return holder, b, h
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

local function mark_name(mk)
	return (mk[1] == "●" and "medium" or mk[1] == "•" and "small" or "none") ..
			" " .. mk[2]
end
-- m is nil on a Buildat whose ui_utils draws no marks
local function keep(where, key, m, mk, unread)
	if scripted then
		log:info("hearth: mark " .. where .. " " .. key .. " " .. mark_name(mk))
	end
	if not m then
		return
	end
	local e = marks[where][key] or {}
	e[#e + 1] = m
	e.unread = e.unread or unread
	marks[where][key] = e
end
local function set_mark(key, time, unread)
	for where, all in pairs(marks) do
		local e = all[key]
		if e then
			e.unread = e.unread or unread
			local mk = mark_for(time, e.unread)
			if scripted then
				log:info("hearth: mark " .. where .. " " .. key .. " " ..
						mark_name(mk) .. " live")
			end
			for _, m in ipairs(e) do
				m.text = mk[1]
				m:SetColor(C(mk[2]))
			end
		end
	end
end

-- A thread's row, marked; `badge` when not thread_badge()
local function thread_row(v, th, badge)
	local mk = mark_for(th.last, th.unread)
	local b, m = add_row(v, th.title, badge or thread_badge(th), function()
		go(function() show_thread(th.id) end)
	end, nil, mk)
	keep("page", "t" .. th.id, m, mk, th.unread)
	return b
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
local function side(label, key, count, page, mk)
	count = tonumber(count) or 0
	local b = sidebar:CreateChild("Button")
	b:SetStyleAuto()
	b:SetFixedHeight(24)
	local t = text(b, label .. (count > 0 and " (" .. count .. ")" or ""),
			count > 0 and MAIN or nil)
	t:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
	t.position = magic.IntVector2(6, 0)
	local m = nil
	if mk then
		m = text(b, mk[1], C(mk[2]))
		-- At the right, left of the section's arrow: one column, shown or not
		m:SetAlignment(magic.HA_RIGHT, magic.VA_CENTER)
		m.position = magic.IntVector2(-22, 0)
	end
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
	return m
end

draw_sidebar = function()
	if not frame then
		build_frame()
	end
	sidebar:RemoveAllChildren()
	marks.side = {}
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
		local mk = mark_for(t.active, t.unread)
		keep("side", "c" .. t.id, side(indent .. cut(t.name), "topic " .. t.id,
				0, function() show_topic(t.id) end, mk), mk, t.unread)
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
	if me.helper then
		text(sidebar, "Moderation", DIM)
		side("Queue", "queue", me.open_reports, function() show_queue() end)
	end
	if me.moderator then
		side("Settings", "settings", 0, function() show_settings() end)
	end
	-- At its foot: who this is
	local gap = sidebar:CreateChild("UIElement")
	gap.minHeight = 8
	side(me.account .. ((me.level or 0) < 10 and " (new)" or ""), "account", 0,
			function() show_account(me.account) end)
end

--
-- The pages
--

-- **Home**: what waits for this account, then the topics and the latest.
-- "Waiting for you" is five unread threads, the followed first, and "more"
-- for the rest the server sent.
local all_waiting = false
show_home = function()
	open_thread = nil
	req("topics", nil, function(r)
		topics = r.topics
		local w = open("Hearth")
		draw_sidebar()
		local bar = row(w)
		button(bar, "Mark all read", function()
			req("mark_read", {}, redraw)
		end)
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
		if me.helper and (me.open_reports or 0) > 0 then
			head()
			add_row(v, me.open_reports .. " reports open", "", function()
				enter("queue", function() show_queue() end)
			end)
		end
		local names = {}
		for _, t in ipairs(topics) do
			names[t.id] = t.name
		end
		for i, th in ipairs(r.waiting or {}) do
			if i > 5 and not all_waiting then
				add_row(v, (#r.waiting - 5) .. " more", "", function()
					all_waiting = true
					redraw()
				end)
				break
			end
			head()
			thread_row(v, th, (names[th.topic] or "") .. " · " ..
					thread_badge(th))
		end
		all_waiting = false
		v:header("Topics")
		local function topic_row(t, indent)
			local mk = mark_for(t.active, t.unread)
			local _, m = add_row(v, indent .. t.name, t.threads ..
					(t.threads == 1 and " thread" or " threads"), function()
				enter("topic " .. t.id, function() show_topic(t.id) end)
			end, nil, mk)
			keep("page", "c" .. t.id, m, mk, t.unread)
		end
		for _, t in ipairs(topics) do
			if t.parent == 0 then
				topic_row(t, "")
				for _, s in ipairs(topics) do
					if s.parent == t.id then
						topic_row(s, "    ")
					end
				end
			end
		end
		v:header("Latest")
		for _, th in ipairs(r.latest) do
			thread_row(v, th, (names[th.topic] or "") .. " · " ..
					thread_badge(th))
		end
		v:fit()
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
				fixed = "released a version that fixes",
				thanks = "thanked your message in"}
		for _, n in ipairs(items) do
			-- Thanks are gathered: the latest name, the others' count in
			-- the note ([HEARTH_THANKS])
			local by, note = n.by, n.note
			if n.kind == "thanks" then
				local others = tonumber(note) or 0
				by = by .. (others == 1 and " and 1 other" or others > 1 and
						" and " .. others .. " others" or "")
				note = nil
			end
			local _, b = add_box(v, nil, by .. " " .. (said[n.kind] or n.kind) ..
					" " .. n.title .. " · " .. ago(n.time), note,
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
	place = {kind = "topic", id = id}
	state_changed()
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
		-- What is listed and how, a row of its own under the buttons
		local view = row(w)
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
		choice(view, "Showing: ", kinds, at, function(k)
			state.kind = k
			redraw()
		end)
		local oat = 1
		for i, o in ipairs(ORDERS) do
			if o[1] == state.order then oat = i end
		end
		-- A phone has no room for the two side by side
		choice(narrow and row(w) or view, "Order: ", ORDERS, oat,
				function(o)
			state.order = o
			redraw()
		end)
		button(bar, "Mark all read", function()
			req("mark_read", {topic = id}, function()
				req("topics", nil, function(r)
					topics = r.topics
					draw_sidebar()
					redraw()
				end)
			end)
		end)
		if me.moderator then
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
show_thread = function(id, at, missing)
	place = {kind = "thread", id = id}
	state_changed()
	req("thread", {thread = id}, function(t)
		place.topic = t.topic
		local w = open(t.title)
		-- What was unread there is read now: the sidebar's marks again
		req("topics", nil, function(r)
			topics = r.topics
			draw_sidebar()
		end)
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
		local mine = t.author == me.account or me.moderator
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
		if (t.kind == "problem" or t.kind == "patch") and me.moderator then
			local list_ = t.kind == "patch" and {"open", "applied", "wontfix"} or
					{"open", "confirmed", "fixed", "wontfix"}
			local choices, sat = {}, 1
			for i, s in ipairs(list_) do
				choices[i] = {s, s == "wontfix" and "won't fix" or s}
				if s == t.status then sat = i end
			end
			local fixed_in
			local pick = choice(bar, "Status: ", choices, sat)
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
				body = (m.hidden_text or "Hidden: " ..
						m.hidden_reason) ..
						(body ~= "" and "\n\n" .. body or "")
			end
			for _, p in ipairs(m.patches or {}) do
				body = body .. "\n\n" .. p.name .. "\n" .. p.text
			end
			local holder, _, head_text = add_box(v, "m" .. m.id, head, body,
					is_answer and MAIN or nil)
			-- [HEARTH_THANKS]: the count at the top right, as dim as the
			-- author's name
			if (m.thanks or 0) > 0 then
				local c = text(head_text, "+" .. m.thanks, DIM)
				c:SetAlignment(magic.HA_RIGHT, magic.VA_TOP)
			end
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
			if (m.author == me.account and not m.hidden) or me.moderator then
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
			-- A member's, on another's message; pressed again, taken back
			if not m.hidden and m.author ~= me.account and
					(me.level or 0) >= 10 then -- a member (api.h LV_MEMBER)
				action(m.thanked and "Thanked (take back)" or "Thanks",
						function()
					req("thank", {message = m.id, on = not m.thanked}, redraw)
				end)
			end
			if m.id ~= t.first and (t.author == me.account or me.moderator) then
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
		-- [HEARTH_RESUME]: where it was scrolled to when kept
		if restore_scroll then
			v:scroll(-1000000)
			v:scroll(restore_scroll)
			restore_scroll = nil
		end
		open_thread = {id = id, view = v,
				last = t.list[#t.list] and t.list[#t.list].id or 0,
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
				state_changed()
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
		if missing then
			return missing()
		end
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
	elseif area.visible and selected and composer and not touch then
		composer:SetFocus(true)
	elseif area.visible and (#history > 0 or narrow) then
		back()
	elseif area.visible and section ~= "home" then
		-- A section's first page: Back is to the top ([PLAYTEST_1008])
		enter("home", function() show_home() end)
	else
		accounts.show_account()
	end
end)
-- [PLAYTEST_1008] The browser's Back is Escape while the handler above has
-- a page to go back from (the web page's depth, [TAP_BACK]); at the top it
-- leaves the page. A client from before set_back_depth_extra has none.
local back_extra = nil
magic.SubscribeToEvent("Update", function()
	if not buildat.set_back_depth_extra then
		return
	end
	local n = frame and frame.visible and (accounts.page or
			(area.visible and (#history > 0 or narrow or
			section ~= "home"))) and 1 or 0
	if n ~= back_extra then
		back_extra = n
		buildat.set_back_depth_extra(n)
	end
end)

-- **Kept on the client** ([HEARTH_RESUME]): every non-empty draft and
-- the page open, in the served code's storage (per server; on the web
-- IndexedDB, written every 5 s and when the page is hidden), with the
-- account they are of: another account on the same client gets none of
-- them. Written a second after a change at most.
local STATE, DRAFT_DAYS = "hearth_state", 30
-- Written only once read, so a start writes nothing over it first; a
-- scripted client keeps nothing unless BUILDAT_HEARTH_RESUME=1 (a check's
-- client name logs in many times)
local state_loaded = false
local state_at = 0
magic.SubscribeToEvent("Update", function()
	local t = buildat.get_time_us()
	if not state_dirty or t - state_at < 1000000 or not state_loaded or
			not buildat.storage_write then
		return
	end
	state_dirty, state_at = false, t
	local d = {}
	for k, text_ in pairs(drafts) do
		if text_ ~= "" then
			d[k] = {text = text_, t = draft_times[k] or t / 1e6}
		end
	end
	local p = place
	if p and p.kind == "thread" and open_thread and open_thread.id == p.id
			and open_thread.view then
		p.scroll = -open_thread.view.list.position.y
	end
	buildat.storage_write(STATE, encode({account = me.account, drafts = d,
			place = p}))
end)
-- A thread's scroll changes with no event here: the place is written
-- again every few seconds while a thread is open
-- simplified: by a timer rather than on each scroll
local scroll_at = 0
magic.SubscribeToEvent("Update", function()
	local t = buildat.get_time_us()
	if open_thread and t - scroll_at > 5000000 then
		scroll_at = t
		state_changed()
	end
end)

-- The kept drafts into `drafts`, and the kept page, or nil; on start,
-- once `me` is known
local function load_state()
	if scripted and buildat.get_env("BUILDAT_HEARTH_RESUME") ~= "1" then
		return nil
	end
	state_loaded = true
	local raw = buildat.storage_read and buildat.storage_read(STATE)
	local st = raw and buildat.parse_json(raw)
	if type(st) ~= "table" or st.account ~= me.account then
		return nil
	end
	local oldest = buildat.get_time_us() / 1e6 - DRAFT_DAYS * 86400
	for k, d in pairs(type(st.drafts) == "table" and st.drafts or {}) do
		if type(k) == "string" and type(d) == "table" and
				type(d.text) == "string" and (tonumber(d.t) or 0) > oldest then
			drafts[k], draft_times[k] = d.text, tonumber(d.t)
		end
	end
	return type(st.place) == "table" and st.place or nil
end

-- The kept page opened again, with Back going up from it (thread to topic,
-- topic to the top); a thread gone or hidden opens its topic, or the top
local function restore(p)
	local function home() enter("home", function() show_home() end) end
	local topic = tonumber(p.topic)
	local function topic_page()
		if topic then
			enter("topic " .. topic, function() show_topic(topic) end)
		else
			home()
		end
	end
	if p.kind == "thread" and tonumber(p.id) then
		local id = tonumber(p.id)
		section = topic and "topic " .. topic or "home"
		history = {topic and function() show_topic(topic) end or
				function() show_home() end}
		draw_sidebar()
		here = function() show_thread(id) end
		local scroll = tonumber(p.scroll)
		show_thread(id, nil, topic_page)
		if scroll then
			restore_scroll = scroll
		end
	elseif p.kind == "topic" and tonumber(p.id) then
		topic = tonumber(p.id)
		topic_page()
	elseif p.kind == "compose" and topic then
		-- Not topic_page() and then go(): the topic's answer, coming after,
		-- drew it over this page
		section = "topic " .. topic
		history = {function() show_topic(topic) end}
		draw_sidebar()
		here = function()
			show_compose({topic = topic, tracker = p.tracker})
		end
		here()
	else
		home()
	end
end

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
		place = {kind = "compose", topic = o.topic, tracker = o.tracker}
		state_changed()
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
				topic_pick = choice(bar, "In: ", choices, at)
			end
		end
		local kinds = {}
		for i, k in ipairs(KINDS) do
			if k[1] ~= "patch" or tracker then
				kinds[#kinds + 1] = {k[1], "It is " .. k[2]}
			end
		end
		kind = choice(bar, "", kinds, o.feedback and 3 or 1)
	end
	-- The field the page's width; the preview under it once Preview is
	-- pressed, as a reply's ([HEARTH_NEW_PREVIEW]: beside it, it halved
	-- the field)
	-- A second after the last key, a preview shown again
	local changed = nil
	local body = edit(w, "The message (Markdown)", true, key, W, function()
		changed = buildat.get_time_us()
	end)
	body:SetFixedHeight(W >= 600 and 200 or 120)
	if o.edit and not drafts[key] then
		body:SetText(o.edit.body)
	elseif o.feedback and not drafts[key] then
		local f = o.feedback
		body:SetText("App: " .. f.package .. " " .. f.version .. "\nEngine: " ..
				f.engine .. "\nPlatform: " .. f.platform .. "\n\n")
	end
	if scripted then
		log:info("hearth: fields " .. encode({title = title_e and
				title_e:GetText() or "", body = body:GetText()}))
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
			state_changed()
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
					thread_row(v, {id = r.thread, title = r.title,
							last = r.last, unread = r.unread}, "")
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
		local lv = a.level or 0
		local ln = accounts.level_name
		text(w, ln(lv), DIM, W)
		-- [TRUST_LADDER] What a helper and up does to an account
		local function act(cmd, args, done)
			args.name = a.name
			req(cmd, args, function()
				message = done
				redraw()
			end)
		end
		if me.helper and a.name ~= me.account then
			local b = row(w)
			if lv < 10 then
				button(b, "Trust", function()
					act("trust", {on = true}, a.name .. " is a " .. ln(10) ..
							" now.")
				end)
			elseif lv < 20 then
				button(b, "Take back the trust", function()
					act("trust", {on = false}, a.name .. " is a " .. ln(0) ..
							" again.")
				end)
			end
			-- Each role below one's own level, from a moderator
			for _, l in ipairs({20, 30}) do
				if me.moderator and l < (me.level or 0) and lv < me.level and
						lv < l + 10 then
					local on = lv >= l
					button(b, (on and "No longer a " or "Make a ") .. ln(l),
							function()
						act("level", {level = on and l - 10 or l}, "Saved.")
					end)
				end
			end
		end
		for _, x in ipairs(a.approved_by or {}) do
			text(w, "Trusted by " .. x.name .. ", " .. ago(x.time), DIM, W)
		end
		if a.approved and #a.approved > 0 then
			local names = {}
			for _, x in ipairs(a.approved) do names[#names + 1] = x.name end
			text(w, "Has trusted: " .. table.concat(names, ", "), DIM, W)
		end
		if a.trust and lv < 10 then
			local tr = a.trust
			text(w, "A " .. ln(0) .. " posts less, and its links wait for " ..
					"a " .. ln(20) .. "'s approval, until it has been active " ..
					"on five days -- a day it read a thread or wrote a " ..
					"message that stands, counted once the day is over (" ..
					(tr.days or 0) .. " so far) -- or a " .. ln(20) ..
					" trusts it; " ..
					"and with none of its messages hidden in 30 days (" ..
					tr.hidden .. " hidden).", nil, W)
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
			message = kind == "appeal" and
					"The appeal is waiting for a " .. accounts.level_name(30) .. "." or
					"Reported; a " .. accounts.level_name(30) .. " will look at it."
			back()
		end)
	end, true)
	e:SetFocus(true)
end

-- **The moderators' queue**: open reports (hide or dismiss), appeals
-- (restore or dismiss), tracker domains (accept or dismiss) and held links
-- (approve or reject, a helper's too; the rest a helper only sees) as
-- rows; the one
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
			if r.kind == "held" then
				text(panel, "A " .. accounts.level_name(0) .. "'s link, waiting in " ..
						r.title, WARN,
						pw)
				text(panel, r.author .. ": " .. r.body, nil, pw)
				local b = row(panel)
				button(b, "Approve (trusts " .. r.author .. ")", function()
					act("approve")
				end)
				button(b, "Reject (deletes it)", function() act("reject") end)
				return
			end
			if not me.moderator then
				text(panel, (r.kind == "domain" and "Tracker domain " .. r.reason
						or r.author .. ": " .. r.body) .. " -- " .. r.kind ..
						" by " .. r.by .. ": " .. r.reason ..
						"\n\nA " .. accounts.level_name(30) .. " decides.", DIM, pw)
				return
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
					r.by .. " in " .. r.title .. ": " .. r.reason ..
					(r.hidden == 3 and " (hidden by reports until you look)" or
					""), WARN, pw)
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
					(r.kind == "appeal" and "Appeal: " or r.kind == "held" and
					"Link: " or "Report: ") .. r.title
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
	-- What is server-wide is the admin's ([TRUST_LADDER])
	local function admins(cmd, on)
		if me.admin then req(cmd, {}, on) else on({}) end
	end
	req("tracker_domains", nil, function(domains)
		admins("release_sources", function(sources)
			admins("file_settings", function(files)
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
				v:header(me.admin and "Releases (from the Aittas named, for " ..
						"this Hearth's addresses)" or "Files")
				if me.admin then
					addresses("Aittas", "aittas")
					addresses("This Hearth's", "addresses")
					v:header("Files (bytes; seconds unused)")
				end
				for _, k in ipairs(me.admin and {"budget", "lod2_after",
						"delete_after"} or {}) do
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
		parent = choice(w, "Under: ", parents, 1)
	end
	button(row(w), t and "Save" or "Create", function()
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

-- [HEARTH_NEW_MARKS] A new message anywhere: the rows drawn for its
-- thread and its topics take their marks at once, and the topic tree keeps
-- them for the next sidebar
buildat.sub_packet("hr:activity", function(data)
	local a = buildat.parse_json(data)
	if type(a) ~= "table" then
		return
	end
	local unread = a.author ~= me.account and
			not (open_thread and open_thread.id == a.thread)
	for _, t in ipairs(topics) do
		if t.id == a.topic or t.id == a.parent then
			t.active = a.time
			t.unread = t.unread or unread
		end
	end
	set_mark("t" .. tostring(a.thread), a.time, unread)
	set_mark("c" .. tostring(a.topic), a.time, unread)
	if a.parent ~= 0 then
		set_mark("c" .. tostring(a.parent), a.time, unread)
	end
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
			-- click on it would; "queue" or "account:<name>" a page, and
			-- "server:<key>" a Server window page
			local open_page = buildat.get_env("BUILDAT_HEARTH_OPEN") or ""
			local kept = load_state()
			local open_ = tonumber(open_page)
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
			elseif open_page == "queue" or open_page:match("^account:") then
				here = function() show_home() end
				go(function()
					if open_page == "queue" then
						show_queue()
					else
						show_account(open_page:sub(9))
					end
				end)
			else
				if kept then
					restore(kept)
				else
					enter("home", function() show_home() end)
				end
			end
			-- "server:<page>": the Server window's page over it
			if open_page:match("^server:") then
				accounts.server_window(open_page:sub(8))
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
