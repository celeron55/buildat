-- Buildat: apps/hearth/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Hearth, taking part** ([HEARTH_MVP]): the topics, a topic's threads, a
-- thread and a reply to it, a new thread. Every action is a JSON "hr:req"
-- {id, cmd, ...}, answered by "hr:res" (main.cpp decides who may do what).
-- Reading is also the server's plain HTML, at its address in a browser.
--
-- A scripted client sends BUILDAT_HEARTH_REQS, JSON requests a line each
-- numbered from 1001, after the join, and logs each answer as "hr: <json>"
-- and each notification as "hr notify: <json>".
local log = buildat.Logger("hearth")
local magic = require("buildat/extension/urho3d")

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("hearth: could not load accounts.lua: " .. tostring(accounts_err))
end
accounts.on_kicked = function()
	buildat.disconnect()
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
local message = nil
local page = nil
local home

-- on_error(why): instead of home() and the error over it
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
		message = tostring(res.error)
		return home()
	end
	if on then
		on[1](res.result)
	end
end)

local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)
local text = accounts.page_text
local button = accounts.page_button

local function new_page(title)
	if page then
		page:Remove()
	end
	page = accounts.page_window(820)
	text(page, title)
	if message then
		text(page, message, YELLOW)
		message = nil
	end
	return page
end

-- A scrolling list as tall as half the screen; rows are added by add()
local function list(parent)
	local l = parent:CreateChild("ListView")
	l:SetStyleAuto()
	l:SetFixedHeight(math.max(120, math.floor(magic.ui.root.height * 0.5)))
	local width = math.max(100, parent.width - 32 - 28)
	local function add(t, color, on_click)
		local e
		if on_click then
			e = l:CreateChild("Button")
			e:SetStyleAuto()
			e.minHeight = 28
			local label = e:CreateChild("Text")
			label:SetStyleAuto()
			label:SetText(t)
			label:SetAlignment(magic.HA_LEFT, magic.VA_CENTER)
			label.position = magic.IntVector2(8, 0)
			magic.SubscribeToEvent(e, "Released", function() on_click() end)
		else
			e = l:CreateChild("Text")
			e:SetStyleAuto()
			e:SetWordwrap(true)
			e:SetText(t)
			if color then
				e:SetColor(color)
			end
		end
		e:SetFixedWidth(width)
		l:AddItem(e)
	end
	return l, add
end

-- The markup's buttons under a message's field, for whoever does not know
-- Markdown: each puts its Markdown in at the cursor.
-- simplified: never wraps a selection -- a field's selection cannot be
-- read from here; that needs Text's selectionStart and selectionLength in
-- safe_classes.lua
local MARKUP = {{"Bold", "**bold**"}, {"List", "\n- "},
	{"Link", "[text](https://)"}, {"Image", "![what it shows](https://)"},
	{"Code", "`code`"}}
local function insert_at_cursor(e, text)
	-- The cursor counts characters, the string bytes
	local s, at, i = e:GetText(), e.cursorPosition, 1
	for _ = 1, at do
		local c = s:byte(i)
		if not c then
			break
		end
		i = i + (c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1)
	end
	e:SetText(s:sub(1, i - 1) .. text .. s:sub(i))
	e.cursorPosition = at + #text
	e:SetFocus(true)
end

-- [FORUM] step 5: File... picks a file (the browser's picker, or on native
-- the client's list of <user>/exports); once read it is uploaded, and its
-- link goes in at the cursor of the field it was picked for
local picking_into = nil
local function markup_buttons(parent, e)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	for _, b in ipairs(MARKUP) do
		button(r, b[1], function()
			insert_at_cursor(e, b[2])
		end)
	end
	button(r, "File...", function()
		picking_into = e
		buildat.pick_file("")
	end)
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
	-- A page left meanwhile: e is held, detached, and nothing shows
	local function fail(why)
		local parent = e:GetParent()
		if parent then
			text(parent, "The file: " .. why, YELLOW)
		end
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
		insert_at_cursor(e, (r.image and "!" or "") .. "[" ..
				name:gsub("[%[%]]", "") .. "](/f/" .. r.id .. "/" ..
				name:gsub("[^%w%.%-_]", "_") .. ")")
	end, fail)
end)

-- multi: a message's field -- Enter breaks the line, Ctrl+Enter finishes
local function edit(parent, label, multi)
	text(parent, label)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = multi and 96 or 26
	e.multiLine = multi == true
	e.textSelectable = true
	e.textCopyable = true
	if multi then
		markup_buttons(parent, e)
	end
	return e
end

local show_topic, show_thread, read_on, show_notifications, show_queue, show_report
local show_new_topic, show_link
-- Who this client is ("me"), and the thread it has open: the server pushes
-- that thread's new messages ("hr:new"), which are added to it in place
local me = {account = "", unseen = 0, level = 0, open_reports = 0}
local open_thread = nil
local on_home = false

-- What a thread is, as main.cpp's kind_text() says it: "problem, fixed in
-- 1.3", "question", or "" for a discussion
local function kind_text(th)
	if th.kind ~= "problem" then
		return th.kind or ""
	end
	if th.status == "fixed" then
		return "problem, fixed" .. (th.fixed_in ~= "" and " in " .. th.fixed_in or "")
	end
	return "problem, " .. (th.status == "wontfix" and "won't fix" or th.status)
end

-- A button that cycles through what a new thread is ([PACKAGE_SUBJECT]);
-- returns a function giving the kind picked
local KINDS = {{"", "a discussion"}, {"question", "a question"},
		{"problem", "a problem"}, {"idea", "an idea"}}
local function kind_pick(parent, at)
	local pick
	pick = button(parent, "It is " .. KINDS[at][2], function()
		at = at % #KINDS + 1
		pick:GetChild(0):SetText("It is " .. KINDS[at][2])
	end)
	return function() return KINDS[at][1] end
end

local function thread_line(th)
	local kind = kind_text(th)
	return th.title .. "  -- " .. (kind ~= "" and kind .. ", " or "") ..
			(th.answer ~= 0 and "answered, " or "") ..
			th.author .. ", " .. th.messages .. " messages"
end

home = function()
	open_thread = nil
	req("topics", nil, function(r)
		local w = new_page("Hearth, as " .. me.account ..
				(me.level == 0 and " (new account)" or ""))
		on_home = true
		button(w, "Notifications" .. (me.unseen > 0 and
				" (" .. me.unseen .. " new)" or ""), show_notifications)
		if me.admin then
			button(w, "Moderation (" .. (me.open_reports or 0) .. " open)",
					show_queue)
			button(w, "New topic...", function() show_new_topic(r.topics) end)
		end
		local _, add = list(w)
		-- Each subtopic under its parent; the server gives the top level first
		local function add_topic(t)
			add((t.parent ~= 0 and "    " or "") .. t.name .. "  (" ..
					t.threads .. " threads)", nil, function()
				show_topic(t.id)
			end)
		end
		for _, t in ipairs(r.topics) do
			if t.parent == 0 then
				add_topic(t)
				for _, s in ipairs(r.topics) do
					if s.parent == t.id then
						add_topic(s)
					end
				end
			end
		end
		add("Latest", GREY)
		for _, t in ipairs(r.latest) do
			add(thread_line(t), nil, function()
				show_thread(t.id)
			end)
		end
	end)
end

local function leave_home()
	on_home = false
end

show_notifications = function()
	leave_home()
	open_thread = nil
	req("notifications", nil, function(items)
		me.unseen = 0
		local w = new_page("Notifications")
		local _, add = list(w)
		local said = {reply = "replied in", mention = "mentioned you in",
				answer = "marked your message the answer in",
				hidden = "hid your message in",
				restored = "restored your message in",
				appeal_dismissed = "kept your message hidden in",
				status = "set the status of",
				fixed = "released a version that fixes"}
		for _, n in ipairs(items) do
			add((n.seen and "" or "* ") .. n.by .. " " ..
					(said[n.kind] or n.kind) .. " " .. n.title ..
					(n.note ~= "" and ": " .. n.note or ""), nil, function()
				show_thread(n.thread)
			end)
		end
		if #items == 0 then
			add("None yet. Replies in the threads you follow, mentions " ..
					"(@" .. me.account .. ") and answers come here.", GREY)
		end
		button(w, "Back", home)
	end)
end

show_topic = function(id)
	leave_home()
	open_thread = nil
	req("topic", {topic = id}, function(t)
		local w = new_page(t.name)
		if t.about ~= "" then
			text(w, t.about, GREY)
		end
		local _, add = list(w)
		for _, th in ipairs(t.threads) do
			add(thread_line(th), nil, function()
				show_thread(th.id)
			end)
		end
		local title = edit(w, "A new thread's title")
		-- simplified: no markup buttons and no preview yet; the text is
		-- CommonMark, which reads as it is
		local body = edit(w, "Its first message (Markdown)", true)
		local kind = kind_pick(w, 1)
		button(w, "Start the thread", function()
			req("new_thread", {topic = id, title = title:GetText(),
					body = body:GetText(), kind = kind()}, function(new_id)
				show_thread(new_id)
			end)
		end)
		button(w, "Back", home)
	end)
end

-- A message's rows; whoever started the thread can mark a reply the answer.
-- Others' messages can be reported; a hidden one's author appeals.
local function add_message(t, add, m, is_answer)
	add((is_answer and "This answered it -- " or "") .. m.author ..
			(m.edited ~= 0 and "  (edited)" or ""), is_answer and YELLOW or GREY)
	if m.hidden then
		add("Hidden by a moderator: " .. m.hidden_reason, YELLOW)
	end
	if m.body ~= "" then
		add(m.body)
	end
	if m.hidden and m.author == me.account then
		add("Appeal", nil, function() show_report(t.id, m, "appeal") end)
	elseif not m.hidden and m.author ~= me.account then
		add("Report", nil, function() show_report(t.id, m, "report") end)
	end
	if not is_answer and m.id ~= t.first and t.answer ~= m.id and
			(t.author == me.account or me.admin) then
		add("This answered it", nil, function()
			req("answered", {thread = t.id, message = m.id}, function()
				show_thread(t.id)
			end)
		end)
	end
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

show_thread = function(id)
	leave_home()
	req("thread", {thread = id}, function(t)
		local w = new_page(t.title)
		local kind = kind_text(t)
		if kind ~= "" then
			text(w, kind .. (t.version ~= "" and ", reported in " .. t.version or
					""), GREY)
		end
		local l, add = list(w)
		t.first = t.list[1] and t.list[1].id or 0
		-- The question, its answer, then the rest in order
		local answer = nil
		for _, m in ipairs(t.list) do
			if m.id == t.answer then
				answer = m
			end
		end
		for i, m in ipairs(t.list) do
			if m ~= answer then
				add_message(t, add, m, false)
			end
			if i == 1 and answer then
				add_message(t, add, answer, true)
			end
		end
		l.viewPosition = magic.IntVector2(0, 1000000)
		local last = t.list[#t.list] and t.list[#t.list].id or 0
		open_thread = {id = id, last = last, append = function(list)
			for _, m in ipairs(list) do
				add_message(t, add, m, false)
				open_thread.last = m.id
			end
			l.viewPosition = magic.IntVector2(0, 1000000)
		end}
		if t.more then
			read_on(open_thread)
		end
		local e = edit(w, "Reply (Markdown; Ctrl+Enter sends)", true)
		local function send()
			if e:GetText() == "" then
				return
			end
			-- It comes back as "hr:new", as anyone else's does
			req("reply", {thread = id, body = e:GetText()})
			e:SetText("")
		end
		magic.SubscribeToEvent(e, "TextFinished", send)
		button(w, "Send", send)
		button(w, t.following and "Stop following" or "Follow", function()
			req("follow", {thread = id, on = not t.following}, function()
				show_thread(id)
			end)
		end)
		if t.subject == "" and (t.author == me.account or me.admin) then
			button(w, "About a package...", function() show_link(t) end)
		end
		-- A problem's status, the admin's to set ([PACKAGE_SUBJECT])
		if t.kind == "problem" and me.admin then
			-- One button, to the next status: a page that fits a small window
			local fixed_in = edit(w, "Fixed in (a version, for fixed)")
			local next = {open = "confirmed", confirmed = "fixed",
					fixed = "wontfix", wontfix = "open"}
			local to = next[t.status] or "open"
			button(w, "Make it " .. (to == "wontfix" and "won't fix" or to),
					function()
				req("status", {thread = id, status = to, fixed_in =
						to == "fixed" and fixed_in:GetText() or ""},
						function() show_thread(id) end)
			end)
		end
		button(w, "Back", function() show_topic(t.topic) end)
		-- A touchscreen's keyboard would cover the thread: it opens on a tap
		if buildat.get_env("BUILDAT_TOUCH") ~= "1" then
			e:SetFocus(true)
		end
	end)
end

-- Which package a thread is about, out of those released here
show_link = function(t)
	leave_home()
	open_thread = nil
	req("subjects", nil, function(subjects)
		local w = new_page("What is \"" .. t.title .. "\" about?")
		local _, add = list(w)
		for _, s in ipairs(subjects) do
			local pkg, key = s:match("^(%S+) (%x*)")
			add((pkg or s) .. "  (key " .. (key or ""):sub(1, 12) .. "...)",
					nil, function()
				req("link", {thread = t.id, subject = s}, function()
					show_thread(t.id)
				end)
			end)
		end
		if #subjects == 0 then
			add("No package has a release here yet.", GREY)
		end
		button(w, "Back", function() show_thread(t.id) end)
	end)
end

-- A report of someone's message, or an appeal of one's own hidden one
show_report = function(thread_id, m, kind)
	leave_home()
	open_thread = nil
	local w = new_page(kind == "appeal" and "Appeal: why it should be shown" or
			"Report: what is wrong with it")
	text(w, m.author .. ": " .. m.body, GREY)
	local e = edit(w, kind == "appeal" and "Your appeal" or "The reason")
	button(w, "Send", function()
		req(kind, {message = m.id, [kind == "appeal" and "text" or "reason"] =
				e:GetText()}, function()
			message = kind == "appeal" and "The appeal is waiting for the admin." or
					"Reported; the admin will look at it."
			show_thread(thread_id)
		end)
	end)
	button(w, "Back", function() show_thread(thread_id) end)
end

-- The admin's new topic: a name, what it is about, and a parent -- none, or
-- one of the top-level topics, so subtopics are one level deep
show_new_topic = function(topics)
	leave_home()
	open_thread = nil
	local w = new_page("New topic")
	local name = edit(w, "Name (80 bytes at most)")
	local about = edit(w, "What it is about (optional)")
	local parents = {{id = 0, name = "none, a top-level topic"}}
	for _, t in ipairs(topics) do
		if t.parent == 0 then
			parents[#parents + 1] = t
		end
	end
	local at = 1
	local pick
	pick = button(w, "Under: " .. parents[at].name, function()
		at = at % #parents + 1
		pick:GetChild(0):SetText("Under: " .. parents[at].name)
	end)
	button(w, "Create", function()
		req("new_topic", {name = name:GetText(), about = about:GetText(),
				parent = parents[at].id}, function()
			home()
		end)
	end)
	button(w, "Back", home)
	name:SetFocus(true)
end

-- The admin's queue: open reports (hide or dismiss) and appeals (restore
-- or dismiss), with a statement of reasons the author is shown
show_queue = function()
	leave_home()
	open_thread = nil
	req("queue", nil, function(items)
		me.open_reports = #items
		local w = new_page("Moderation")
		local statement = edit(w, "Statement of reasons (shown to the author)")
		local _, add = list(w)
		local function act(r, action)
			req("moderate", {report = r.id, action = action,
					statement = statement:GetText()}, show_queue)
		end
		for _, r in ipairs(items) do
			add((r.kind == "appeal" and "Appeal by " or "Report by ") .. r.by ..
					" in " .. r.title .. ": " .. r.reason, YELLOW)
			if r.kind == "appeal" then
				add("Hidden for: " .. r.hidden_reason, GREY)
			end
			add(r.author .. ": " .. r.body)
			if r.kind == "appeal" then
				add("Restore", nil, function() act(r, "restore") end)
			else
				add("Hide", nil, function() act(r, "hide") end)
			end
			add("Dismiss", nil, function() act(r, "dismiss") end)
		end
		if #items == 0 then
			add("Nothing open.", GREY)
		end
		button(w, "Back", home)
	end)
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
	if on_home then
		home()
	end
end)

-- **"Feedback..." on an app** ([PACKAGE_SUBJECT]): the launch grid came
-- here with the app's package and versions, which start the message and
-- go with the thread as its subject
local function show_feedback(f)
	leave_home()
	open_thread = nil
	local w = new_page("Feedback about " .. f.package .. " " .. f.version)
	text(w, "Goes to this Hearth's Feedback topic, which its makers read",
			GREY)
	local title = edit(w, "A title")
	local body = edit(w, "The message (Markdown)", true)
	body:SetText("App: " .. f.package .. " " .. f.version .. "\nEngine: " ..
			f.engine .. "\nPlatform: " .. f.platform .. "\n\n")
	local kind = kind_pick(w, 3)
	button(w, "Send", function()
		req("new_thread", {feedback = true, subject = f.subject,
				title = title:GetText(), body = body:GetText(), kind = kind(),
				-- one the server would refuse leaves the report without it
				version = #f.version <= 40 and
						f.version:match("^[%w%.%+_%-]+$") or nil},
				function(new_id)
			show_thread(new_id)
		end)
	end)
	button(w, "Back", home)
end

-- **A package's place** ([PACKAGE_SUBJECT]): "Discuss" on Aitta's list
-- came here; the threads about the package, and the way to report one
local function show_place(f)
	leave_home()
	open_thread = nil
	req("subject", {subject = f.subject}, function(threads)
		local w = new_page(f.package .. " on this Hearth")
		local _, add = list(w)
		for _, th in ipairs(threads) do
			add(thread_line(th), nil, function() show_thread(th.id) end)
		end
		if #threads == 0 then
			add("Nothing about it here yet.", GREY)
		end
		button(w, "Report a problem or give feedback...", function()
			show_feedback(f)
		end)
		button(w, "Back", home)
	end)
end

accounts.on_joined = function()
	req("me", nil, function(r)
		me = r
		-- BUILDAT_HEARTH_OPEN=<thread>: a scripted client opens it, as a
		-- click on it would
		local open = tonumber(buildat.get_env("BUILDAT_HEARTH_OPEN") or "")
		local f = buildat.feedback()
		if f then
			if scripted then
				log:info("hr feedback: " .. encode(f))
			end
			if f.place then
				show_place(f)
			else
				show_feedback(f)
			end
		elseif open then
			show_thread(open)
		else
			home()
		end
		-- After the page's own requests, so a scripted "thread" is the one
		-- left open; numbered from 1001
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
end

accounts.start({title = "Hearth", env = "BUILDAT_HEARTH"})
-- vim: set noet ts=4 sw=4:
