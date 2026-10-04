-- Buildat: apps/aitta/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- **Aitta's own page** ([AITTA_MVP]): an author binds an author name to the
-- key `bin/buildat aitta keygen` printed, and sees the releases; the admin
-- delists. Every action is a JSON "ai:req" {id, cmd, ...}, answered by
-- "ai:res" (main.cpp decides who may do what).
--
-- A scripted client sends BUILDAT_AITTA_REQS, JSON requests a line each,
-- after the join, and logs each answer as "ai: <json>".
local log = buildat.Logger("aitta")
local magic = require("buildat/extension/urho3d")

local _, accounts_err, accounts = buildat.run_script_file("accounts/accounts.lua")
if type(accounts) ~= "table" then
	error("aitta: could not load accounts.lua: " .. tostring(accounts_err))
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

local next_id = 1
local waiting = {}
local function req(cmd, args, on)
	local q = args or {}
	q.cmd = cmd
	q.id = next_id
	waiting[next_id] = on or function() end
	next_id = next_id + 1
	buildat.send_packet("ai:req", encode(q))
end

local page = nil
local message = nil
local home

buildat.sub_packet("ai:res", function(data)
	local res = buildat.parse_json(data)
	if type(res) ~= "table" then
		return
	end
	if (buildat.get_env("BUILDAT_AITTA_REQS") or "") ~= "" then
		log:info("ai: " .. data)
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

local function edit(parent, label)
	text(parent, label)
	local e = parent:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	e.textCopyable = true
	return e
end

home = function()
	req("me", nil, function(me)
		if page then
			page:Remove()
		end
		page = accounts.page_window(760)
		text(page, "Aitta, as " .. tostring(me.account))
		if message then
			text(page, message, YELLOW)
			message = nil
		end
		if me.author == "" then
			text(page, "Bind an author name to your key to publish. The key " ..
					"is the line `bin/buildat aitta keygen <file>` printed; " ..
					"the name is what your releases' meta.json say as " ..
					"\"author\", and neither changes after.", GREY)
			local author = edit(page, "Author name (a-z, 0-9, _)")
			local key = edit(page, "Public key")
			button(page, "Bind", function()
				req("bind", {author = author:GetText(), key = key:GetText()},
						function()
					message = "Bound. Publish with: bin/buildat aitta " ..
							"publish <release .zip> <this server's address>"
					home()
				end)
			end)
		else
			text(page, "Author: " .. me.author .. "  key " ..
					me.key:sub(1, 16) .. "...", GREY)
		end
		text(page, #me.releases .. " releases, every one unreviewed:")
		for _, r in ipairs(me.releases) do
			local id = r.author .. "/" .. r.name .. "/" .. r.version
			local line = id .. "  " .. r.license_code .. " / " ..
					r.license_media .. "  " .. math.floor(r.size / 1000) .. " kB" ..
					((r.home_hearth or "") ~= "" and "  home: " .. r.home_hearth or "") ..
					(r.delisted and "  (delisted)" or "")
			if me.admin then
				button(page, line .. "  -- " ..
						(r.delisted and "relist" or "delist"), function()
					req(r.delisted and "relist" or "delist", {release = id},
							home)
				end)
			else
				text(page, line)
			end
		end
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_AITTA_REQS") or ""
	for line in script:gmatch("[^\n]+") do
		local q = buildat.parse_json(line)
		if type(q) == "table" then
			q.id = next_id
			next_id = next_id + 1
			buildat.send_packet("ai:req", encode(q))
		end
	end
	home()
end

accounts.start({title = "Aitta", env = "BUILDAT_AITTA"})
-- vim: set noet ts=4 sw=4:
