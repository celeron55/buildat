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

local message = nil
local home
local req = accounts.requester("ai", function(why)
	message = why
	home()
end, (buildat.get_env("BUILDAT_AITTA_REQS") or "") ~= "")
-- **From the launcher's publish screen** ([AITTA_PUBLISH_UI]): the
-- author name and key it made, to fill the form with; a client from
-- before it has no aitta_bind
local offer = buildat.aitta_bind and buildat.aitta_bind()

local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)
local text = accounts.page_text
local button = accounts.page_button

local function edit(parent, label)
	return accounts.page_field(parent, label)
end

-- In builtin/accounts' Server window ([SERVER_ADMIN_PAGE]), an entry
-- before its Account, Accounts and Health
home = function()
	req("me", nil, function(me)
		if not accounts.frame then
			return accounts.server_window("aitta")
		end
		local page = accounts.server_open("Aitta, as " .. tostring(me.account))
		if message then
			text(page, message, YELLOW)
			message = nil
		end
		if me.author == "" then
			text(page, "Bind an author name to your key to publish. The key " ..
					(offer and "and the name are your launcher's, from its " ..
					"publish screen" or "is the line `bin/buildat aitta " ..
					"keygen <file>` printed; the name is what your " ..
					"releases' meta.json say as \"author\"") ..
					", and neither changes after.", GREY)
			local author = edit(page, "Author name (a-z, 0-9, _)")
			local key = edit(page, "Public key")
			if offer then
				author:SetText(offer.author)
				key:SetText(offer.key)
			end
			button(page, "Bind", function()
				req("bind", {author = author:GetText(), key = key:GetText()},
						function()
					message = offer and "Bound. Leave to the launcher and " ..
							"publish from Settings, Developer." or
							"Bound. Publish with: bin/buildat aitta " ..
							"publish <release .zip> <this server's address>"
					home()
				end)
			end)
		else
			text(page, "Author: " .. me.author .. "  key " ..
					me.key:sub(1, 16) .. "...", GREY)
		end
		-- Where the publish screen is ([AITTA_PUBLISH_UI])
		button(page, "Back to the launcher", function() buildat.leave() end)
		text(page, #me.releases .. " releases, every one unreviewed:")
		-- **A row a release** ([AITTA_ADMIN_ROWS]): its id, its state and
		-- the admin's action as a button of its own, in columns of fixed
		-- widths; the rest on a dim line under it. A long id or address
		-- wraps in its column. simplified: plain rows on the Server
		-- window's page, which scrolls already; a list of its own
		-- (ui_utils.list_view) would fight it for the wheel
		local width = page.width - 12
		local state_w, button_w = 110, me.admin and 110 or 0
		local function column(parent, s, w, color)
			local t = text(parent, s, color)
			t:SetFixedWidth(w)
			return t
		end
		for _, r in ipairs(me.releases) do
			local id = r.author .. "/" .. r.name .. "/" .. r.version
			local box = page:CreateChild("UIElement")
			box:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
			local top = accounts.page_row(box)
			column(top, id, width - state_w - button_w - 8)
			local state = r.delisted and "delisted" or "listed"
			column(top, state, state_w, r.delisted and YELLOW or nil)
			local action = r.delisted and "Relist" or "Delist"
			if me.admin then
				button(top, action, function()
					req(r.delisted and "relist" or "delist", {release = id}, home)
				end):SetFixedWidth(button_w)
			end
			column(box, r.license_code .. " / " .. r.license_media .. "  " ..
					math.floor(r.size / 1000) .. " kB" ..
					((r.home_hearth or "") ~= "" and "  home: " .. r.home_hearth
					or ""), width, GREY)
			-- For a check
			log:info("aitta: row " .. id .. ": " .. state ..
					(me.admin and ", " .. action or ""))
		end
	end)
end

accounts.on_joined = function()
	local script = buildat.get_env("BUILDAT_AITTA_REQS") or ""
	for line in script:gmatch("[^\n]+") do
		local q = buildat.parse_json(line)
		if type(q) == "table" then
			req(q.cmd, q)
		end
	end
	home()
end

accounts.server_menu = function(add)
	add(nil, "Aitta", "aitta", home)
end
-- Its accounts are in the window; no corner button ([ACCOUNT_BUTTON])
accounts.no_account_button()
accounts.start({title = "Aitta", env = "BUILDAT_AITTA"})
-- vim: set noet ts=4 sw=4:
