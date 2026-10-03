-- Buildat: apps/hearth/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Hearth, taking part** ([HEARTH_MVP]): the topics, a topic's threads, a
-- thread and a reply to it, a new thread. Every action is a JSON "hr:req"
-- {id, cmd, ...}, answered by "hr:res" (main.cpp decides who may do what).
-- Reading is also the server's plain HTML, at its address in a browser.
--
-- A scripted client sends BUILDAT_HEARTH_REQS, JSON requests a line each,
-- after the join, and logs each answer as "hr: <json>".
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
		for k, x in pairs(v) do
			out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x)
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return tostring(v)
end

local scripted = (buildat.get_env("BUILDAT_HEARTH_REQS") or "") ~= ""
local next_id = 1
local waiting = {}
local message = nil
local page = nil
local home

local function req(cmd, args, on)
	local q = args or {}
	q.cmd = cmd
	q.id = next_id
	waiting[next_id] = on or function() end
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
		message = tostring(res.error)
		return home()
	end
	if on then
		on(res.result)
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

local function edit(parent, label)
	text(parent, label)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	e.textCopyable = true
	return e
end

local show_topic, show_thread

home = function()
	req("topics", nil, function(r)
		local w = new_page("Hearth")
		local _, add = list(w)
		for _, t in ipairs(r.topics) do
			add((t.parent ~= 0 and "    " or "") .. t.name .. "  (" ..
					t.threads .. " threads)", nil, function()
				show_topic(t.id)
			end)
		end
		add("Latest", GREY)
		for _, t in ipairs(r.latest) do
			add(t.title .. "  -- " .. t.author .. ", " .. t.messages ..
					" messages", nil, function()
				show_thread(t.id)
			end)
		end
	end)
end

show_topic = function(id)
	req("topic", {topic = id}, function(t)
		local w = new_page(t.name)
		if t.about ~= "" then
			text(w, t.about, GREY)
		end
		local _, add = list(w)
		for _, th in ipairs(t.threads) do
			add(th.title .. "  -- " .. th.author .. ", " .. th.messages ..
					" messages", nil, function()
				show_thread(th.id)
			end)
		end
		local title = edit(w, "A new thread's title")
		-- simplified: one line; a multi-line editor with the markup's
		-- buttons and a preview comes with the markup
		local body = edit(w, "Its first message")
		button(w, "Start the thread", function()
			req("new_thread", {topic = id, title = title:GetText(),
					body = body:GetText()}, function(new_id)
				show_thread(new_id)
			end)
		end)
		button(w, "Back", home)
	end)
end

show_thread = function(id)
	req("thread", {thread = id}, function(t)
		local w = new_page(t.title)
		local l, add = list(w)
		for _, m in ipairs(t.list) do
			add(m.author .. (m.edited ~= 0 and "  (edited)" or ""), GREY)
			add(m.body)
		end
		l.viewPosition = magic.IntVector2(0, 1000000)
		local e = edit(w, "Reply")
		local function send()
			if e:GetText() == "" then
				return
			end
			req("reply", {thread = id, body = e:GetText()}, function()
				show_thread(id)
			end)
		end
		magic.SubscribeToEvent(e, "TextFinished", send)
		button(w, "Send", send)
		button(w, "Back", function() show_topic(t.topic) end)
		-- A touchscreen's keyboard would cover the thread: it opens on a tap
		if buildat.get_env("BUILDAT_TOUCH") ~= "1" then
			e:SetFocus(true)
		end
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_HEARTH_REQS") or ""
	for line in script:gmatch("[^\n]+") do
		local q = buildat.parse_json(line)
		if type(q) == "table" then
			q.id = next_id
			next_id = next_id + 1
			buildat.send_packet("hr:req", encode(q))
		end
	end
	home()
end

accounts.start({title = "Hearth", env = "BUILDAT_HEARTH"})
-- vim: set noet ts=4 sw=4:
