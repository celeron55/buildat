-- Buildat: builtin/accounts/client_lua/accounts.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The join, and the account calls a game's pages make ([VANILLA_PUBLIC] 2;
-- the server's side is builtin/accounts). A game loads this, sets the hooks
-- it wants, and calls start():
--
--   local ok, err, accounts = buildat.run_script_file("accounts/accounts.lua")
--   accounts.on_joined = function(name) ... end
--   accounts.start({title = "Floor planner", env = "BUILDAT_FP"})
--
-- Hooks, each optional:
--   on_joined(name)        in; what the game shows next is its own
--   on_users()             accounts.users changed (an admin's)
--   on_admin_result(text)  what an admin request did; also accounts.message
--   on_passwd(text)        "" when the password was changed, else why not
--   on_kicked(text)        before the client disconnects
--   notice(text)           a line the game shows; the log's by default
-- A scripted client joins by the environment: <env>_NAME, <env>_PASSWORD,
-- <env>_CODE and <env>_TOTP, or by a Starport ID's token in <env>_STARPORT
-- (env is "BUILDAT_JOIN" by default).
local log = buildat.Logger("accounts")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")

local M = {
	hello = {},
	logged_in = false,
	name = nil,
	-- What the server said last of its accounts, invites, bans and
	-- registration (an admin's), and of the last admin request
	users = nil,
	message = nil,
}

local TEXT = {"object", {"text", "string"}}
local LOGIN = {"object", {"name", "string"}, {"password", "string"},
		{"code", "string"}, {"token", "string"}, {"keep", "byte"},
		{"totp", "string"}, {"starport", "string"}}
local TOTP_REQ = {"object", {"cmd", "string"}, {"code", "string"}}
local TOTP_RESULT = {"object", {"error", "string"}, {"secret", "string"},
		{"uri", "string"}, {"on", "byte"}}
local LOGIN_RESULT = {"object", {"r", {"object", {"error", "string"},
		{"token", "string"}}}, {"name", "string"}}
local HELLO = {"object", {"local", "byte"}, {"setup", "byte"},
		{"open_registration", "byte"}, {"starport", "byte"}}
local ADMIN = {"object", {"cmd", "string"}, {"name", "string"},
		{"arg", "string"}, {"on", "byte"}}
local USERS = {"object",
	{"users", {"array", {"object", {"name", "string"},
			{"privs", {"array", "string"}}, {"here", "byte"}}}},
	{"invites", {"array", {"object", {"code", "string"},
			{"privs", {"array", "string"}}, {"by", "string"}}}},
	{"access", {"object", {"open_registration", "byte"}}},
	{"bans", {"array", {"object", {"name", "string"}, {"address", "string"}}}},
	-- [STARPORT] 10g: Starport IDs off, anyone or approved; those waiting
	{"starport_ids", "string"},
	{"approvals", {"array", "string"}},
}

local opts = {}
local window = nil
-- The account page open, for the packets that redraw it; see M.users_page
local page_kind, page_back, users_page, passwd_page = nil, nil, nil, nil
local ban_page

local function notice(text)
	if M.notice then
		M.notice(text)
	else
		log:info(text)
	end
end

-- **Keep me logged in** ([ACC_KEEP]): the token a login asked to be kept
-- got, in the client's storage for this server, which the next hello logs
-- in with and asks nothing
local token_tried = false

-- The last login sent, for the TOTP code it may turn out to need
local last_login = nil

local function send_login(name, password, code, token, keep, totp, starport)
	last_login = {name, password, code, token, keep}
	buildat.send_packet("accounts:login", cereal.binary_output(
			{name = name, password = password, code = code or "",
			token = token or "", keep = keep and 1 or 0, totp = totp or "",
			starport = starport or ""}, LOGIN))
end
M.send_login = send_login

-- A window of the join: `width` wide, or the screen's width less a margin
-- on a narrow one ([FP_TOUCH] 2), and its texts wrap to it
local function page_window(width)
	local w = magic.ui.root:CreateChild("Window")
	-- Its own style, for a game whose root has none (vanilla's world); what
	-- is in it finds the style through it
	w.defaultStyle = magic.cache:GetResource("XMLFile",
			"launch_menu/res/main_style.xml")
	w:SetStyleAuto()
	-- Over a game's HUD, such as the Luanti hotbar (priority 10)
	w.priority = 100
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w:SetFixedWidth(math.min(width, magic.ui.root.width - 16))
	return w
end
M.page_window = page_window

local function page_text(w, t, color)
	local l = w:CreateChild("Text")
	l:SetStyleAuto()
	l:SetWordwrap(true)
	l:SetText(t)
	if color then
		l:SetColor(color)
	end
	return l
end
M.page_text = page_text

function M.close()
	if window then
		window:Remove()
		window = nil
	end
end

-- simplified: the join dialog is rebuilt on every error rather than
-- updated
-- **The TOTP code** ([STARPORT] 10a): asked after the password was right,
-- and sent with the same login again
local function show_totp(error_text)
	M.close()
	local w = page_window(380)
	window = w
	page_text(w, "Code from your authenticator app")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	if error_text and error_text ~= "" then
		page_text(w, error_text, magic.Color(1.0, 0.4, 0.4))
	end
	local function go()
		local l = last_login
		send_login(l[1], l[2], l[3], l[4], l[5], e:GetText())
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	local b = w:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 30
	local bt = b:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText("Join")
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	magic.SubscribeToEvent(b, "Released", go)
	e:SetFocus(true)
end

local function show_login(error_text)
	M.close()
	local is_local = M.hello["local"] == 1
	local w = page_window(380)
	window = w
	local function label(text)
		return page_text(w, text)
	end
	local function field(text, secret)
		local e = w:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.textCopyable = not secret
		e.textSelectable = true
		if secret then
			e.echoCharacter = string.byte("*")
		end
		e:SetText(text)
		return e
	end
	-- The game, and what it runs on: "Floor planner | Buildat 0.5.8-bafe9fd8"
	-- (user, 2026-09-30)
	local version, hash = buildat.version()
	label((opts.title or "Join") .. " v." .. tostring(version) ..
			(hash and hash ~= "" and ("-" .. hash) or ""))
	-- Declared here for the Starport ID's button, made before them
	local password, code, keep = nil, nil, nil
	-- [STARPORT] 10c: a Starport ID in place of an account here; the
	-- token comes from the client's own Starport extension, which asks
	-- the Starport, so the password never comes here
	if M.hello.starport == 1 and not is_local then
		local sb = w:CreateChild("Button")
		sb:SetStyleAuto()
		sb.minHeight = 30
		local st = sb:CreateChild("Text")
		st:SetStyleAuto()
		st:SetText("Sign in with your Starport ID")
		st:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(sb, "Released", function()
			local ok, starport = pcall(require, "buildat/extension/starport")
			if not ok or not starport.id_token_here then
				return show_login("This client has no Starport extension")
			end
			starport.id_token_here(function(token, why)
				if not token then
					return show_login(why ~= "cancelled" and why or nil)
				end
				-- With the setup code, the first admin is an ID (10g); and
				-- kept logged in as a local login is
				send_login("", "", code and code:GetText() or "", nil,
						keep and keep.on, "", token)
			end)
		end)
		label("or with an account of this server:")
	end
	label("Name")
	-- The name used last on this server, kept on the client; else the one
	-- the user gave the client for every game, unless that is the client's
	-- own default, which is nobody's name (user, the sixth round)
	local default = buildat.get_preference("default_username")
	local name = field(buildat.storage_read("name") or
			(default ~= "User" and default) or "", false)
	if is_local then
		-- The saves are on this machine: no password to ask
		label("On this computer: no password needed")
	else
		label(M.hello.open_registration == 1 and
				"Password (a new name makes an account)" or "Password")
		password = field("", true)
		-- The server's first admin claims it with the code in the server's
		-- log; while registration is closed a new account needs an invite
		if M.hello.setup == 1 then
			label("Setup code (see the server's log)")
			code = field("", false)
		elseif M.hello.open_registration ~= 1 then
			label("Invite code (only for a new account)")
			code = field("", false)
		end
		-- simplified: a native client's connection is not encrypted yet
		-- ([TRANSPORT]); a web client on an https page has TLS, and its
		-- page says so
		if buildat.get_env("BUILDAT_PAGE_HTTPS") ~= "1" then
			local warn = label("The password is sent unencrypted: use a " ..
					"trusted network")
			warn:SetColor(magic.Color(1.0, 0.8, 0.4))
		end
	end
	if not is_local then
		keep = {on = buildat.storage_read("keep") == "1"}
		local kb = w:CreateChild("Button")
		kb:SetStyleAuto()
		kb.minHeight = 30
		local kt = kb:CreateChild("Text")
		kt:SetStyleAuto()
		kt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		local function draw_keep()
			kt:SetText((keep.on and "[x] " or "[ ] ") .. "Keep me logged in")
		end
		-- **By the keyboard too** (user, 2026-10-01): Tab reaches it after
		-- the fields, and a focused button is pressed by Space or Enter
		kb:SetFocusMode(magic.FM_FOCUSABLE)
		draw_keep()
		magic.SubscribeToEvent(kb, "Released", function()
			keep.on = not keep.on
			draw_keep()
		end)
	end
	if error_text then
		local e = label(error_text)
		e:SetColor(magic.Color(1.0, 0.4, 0.4))
	end
	local button = w:CreateChild("Button")
	button:SetStyleAuto()
	button.minHeight = 30
	local bt = button:CreateChild("Text")
	bt:SetStyleAuto()
	bt:SetText("Join")
	bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	local function join()
		local n = name:GetText()
		buildat.storage_write("name", n)
		buildat.storage_write("keep", keep and keep.on and "1" or "0")
		M.name = n
		send_login(n, password and password:GetText() or "",
				code and code:GetText() or "", nil, keep and keep.on)
	end
	-- and Join after it
	button:SetFocusMode(magic.FM_FOCUSABLE)
	magic.SubscribeToEvent(button, "Released", function() join() end)
	magic.SubscribeToEvent(name, "TextFinished", function()
		if password then
			password:SetFocus(true)
		else
			join()
		end
	end)
	if password then
		magic.SubscribeToEvent(password, "TextFinished", function()
			if code then
				code:SetFocus(true)
			else
				join()
			end
		end)
	end
	if code then
		magic.SubscribeToEvent(code, "TextFinished", function() join() end)
	end
	name:SetFocus(true)
end

buildat.sub_packet("accounts:hello", function(data)
	M.hello = cereal.binary_input(data, HELLO)
	-- Said again when an admin changes who may register: a user who has
	-- joined already has nothing to do with it
	if M.logged_in then
		return
	end
	-- A scripted or second client can skip the dialog
	local env = opts.env or "BUILDAT_JOIN"
	local auto_name = buildat.get_env(env .. "_NAME")
	-- A Starport ID's token, as a check gets one from the Starport's API
	local auto_starport = buildat.get_env(env .. "_STARPORT")
	if auto_starport and auto_starport ~= "" and not M.auto_tried then
		M.auto_tried = true
		send_login("", "", buildat.get_env(env .. "_CODE") or "", nil,
				buildat.get_env(env .. "_KEEP") == "1", "", auto_starport)
		return
	end
	local token = buildat.storage_read("token") or ""
	if auto_name and not M.auto_tried then
		M.auto_tried = true
		M.name = auto_name
		send_login(auto_name, buildat.get_env(env .. "_PASSWORD") or "",
				buildat.get_env(env .. "_CODE") or "", nil,
				buildat.get_env(env .. "_KEEP") == "1",
				buildat.get_env(env .. "_TOTP") or "")
	elseif token ~= "" and not token_tried then
		token_tried = true
		M.name = buildat.storage_read("name") or ""
		log:info("Logging in as " .. M.name .. " with the kept login")
		send_login(M.name, "", "", token)
	else
		show_login(nil)
	end
end)

buildat.sub_packet("accounts:login_result", function(data)
	local outer = cereal.binary_input(data, LOGIN_RESULT)
	local r = outer.r
	if outer.name ~= "" then
		M.name = outer.name
	end
	local err = r.error
	if err ~= "" then
		log:info("Login refused: " .. err)
		-- A kept login that did not work is forgotten
		if token_tried then
			buildat.storage_write("token", "")
		end
		if err:sub(1, 5) == "TOTP:" and last_login then
			show_totp(err == "TOTP: enter the code from your authenticator "..
					"app" and "" or err:sub(7))
			return
		end
		show_login(err)
		return
	end
	if r.token ~= "" then
		buildat.storage_write("token", r.token)
		-- A Starport ID's name comes from the server
		buildat.storage_write("name", M.name or "")
	end
	M.logged_in = true
	M.close()
	magic.ui:SetFocusElement(nil)
	log:info("Joined as " .. tostring(M.name))
	if M.on_joined then
		M.on_joined(M.name)
	end
end)

buildat.sub_packet("accounts:users", function(data)
	M.users = cereal.binary_input(data, USERS)
	log:info(#M.users.users .. " accounts listed")
	if page_kind == "users" then
		users_page(page_back)
	end
	if M.on_users then
		M.on_users()
	end
end)

buildat.sub_packet("accounts:admin_result", function(data)
	M.message = cereal.binary_input(data, TEXT).text
	if page_kind == "users" then
		users_page(page_back)
	end
	if M.on_admin_result then
		M.on_admin_result(M.message)
	end
end)

buildat.sub_packet("accounts:passwd_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	if page_kind == "passwd" then
		passwd_page(page_back, text == "" and "The password was changed" or
				text)
	end
	if M.on_passwd then
		M.on_passwd(text)
	end
end)

buildat.sub_packet("accounts:link_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	if page_kind == "passwd" then
		passwd_page(page_back, text == "" and "The Starport ID is linked: "..
				"it logs in as this account now" or text)
	end
end)

buildat.sub_packet("accounts:kicked", function(data)
	local text = cereal.binary_input(data, TEXT).text
	notice(text)
	if M.on_kicked then
		M.on_kicked(text)
	end
end)

-- An admin's request: list, priv, kick, ban, unban, password, delete, add,
-- invite, uninvite, setting
function M.admin(cmd, name, arg, on)
	log:info("admin request: " .. cmd)
	buildat.send_packet("accounts:admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = on and 1 or 0}, ADMIN))
end

-- Whether this client has a kept login on this server
function M.kept()
	return (buildat.storage_read("token") or "") ~= ""
end

-- The kept login ended, on the server and here, and the client off the
-- server: the next join asks again
function M.logout()
	local token = buildat.storage_read("token") or ""
	if token ~= "" then
		buildat.send_packet("accounts:logout",
				cereal.binary_output({text = token}, TEXT))
	end
	buildat.storage_write("token", "")
	buildat.storage_write("keep", "0")
	buildat.disconnect()
end

function M.passwd(old, new)
	buildat.send_packet("accounts:passwd", cereal.binary_output(
			{old = old, new = new}, {"object", {"old", "string"},
			{"new", "string"}}))
end

--
-- The account pages ([VANILLA_PUBLIC] 2): a user's own password, and an
-- admin's users, invites, bans and registration. Each game opens them from
-- its own pause menu, and `back` is what their Back goes to. M.page is the
-- page open, for the game's hit tests; M.close_page() closes it.
--
local function row(parent)
	local r = parent:CreateChild("UIElement")
	r:SetLayout(magic.LM_HORIZONTAL, 4, magic.IntRect(0, 0, 0, 0))
	return r
end

local function button(parent, text, on_click)
	local b = parent:CreateChild("Button")
	b:SetStyleAuto()
	b.minHeight = 28
	local t = b:CreateChild("Text")
	t:SetStyleAuto()
	t:SetText(text)
	t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	b.minWidth = t.width + 24
	magic.SubscribeToEvent(b, "Released", function() on_click() end)
	return b
end
-- For a game's own pages in the same look: vanilla's pause menu
M.page_button = button

local function field(parent, label, secret, on_finish)
	local r = row(parent)
	local l = page_text(r, label)
	l:SetWordwrap(false)
	l.minWidth = 100
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.minWidth = 160
	e.textSelectable = true
	if secret then
		e.echoCharacter = string.byte("*")
	else
		e.textCopyable = true
	end
	magic.SubscribeToEvent(e, "TextFinished", function() on_finish() end)
	return e
end

local YELLOW = magic.Color(1.0, 0.8, 0.4)
local GREY = magic.Color(0.7, 0.7, 0.7)

local chat_list = nil
-- The width a line of the chat wraps to: the page's less its margins and
-- the list's scroll bar
local chat_width = 100

function M.close_page()
	if M.page then
		M.page:Remove()
		M.page = nil
	end
	page_kind = nil
	chat_list = nil
end

local function open_page(kind, title, back)
	M.close_page()
	page_kind, page_back = kind, back
	M.page = page_window(560)
	page_text(M.page, title)
	return M.page
end

local function go_back()
	M.close_page()
	M.message = nil
	if page_back then
		page_back()
	end
end

-- A user's own password; `message` is what the last change came to
passwd_page = function(back, message)
	local w = open_page("passwd", "Change password", back)
	if message then
		page_text(w, message, YELLOW)
	end
	local old, new1, new2
	local function change()
		if new1:GetText() ~= new2:GetText() then
			return passwd_page(back, "The new passwords differ")
		end
		M.passwd(old:GetText(), new1:GetText())
	end
	old = field(w, "Old", true, function() new1:SetFocus(true) end)
	new1 = field(w, "New", true, function() new2:SetFocus(true) end)
	new2 = field(w, "New again", true, change)
	local r = row(w)
	button(r, "Change", change)
	-- [STARPORT] 10g: this account the one a Starport ID logs in as
	if M.hello.starport == 1 then
		button(r, "Link a Starport ID...", function()
			local ok, starport = pcall(require, "buildat/extension/starport")
			if not ok or not starport.id_token_here then
				return passwd_page(back, "This client has no Starport extension")
			end
			starport.id_token_here(function(token, why)
				if not token then
					return passwd_page(back, why)
				end
				buildat.send_packet("accounts:link_starport", token)
			end)
		end)
	end
	button(r, "Back", go_back)
	old:SetFocus(true)
end
M.password_page = function(back) passwd_page(back) end

-- A QR code of `text` for an authenticator app's camera ([STARPORT] 10a),
-- drawn at 6 pixels a module with the quiet zone round it: scaled down by
-- the UI it stays readable
local function qr_image(parent, text)
	local bits, n = buildat.qr_code(text)
	if not bits then
		return nil
	end
	local px, quiet = 6, 4
	local side = (n + 2 * quiet) * px
	local rows = {}
	for y = 0, side - 1 do
		local row = {}
		local my = math.floor(y / px) - quiet
		for x = 0, side - 1 do
			local mx = math.floor(x / px) - quiet
			local dark = mx >= 0 and my >= 0 and mx < n and my < n and
					bits:byte(my * n + mx + 1) == 49
			row[#row + 1] = dark and "\0\0\0" or "\255\255\255"
		end
		rows[#rows + 1] = table.concat(row)
	end
	local img = magic.Image:new()
	img:SetSize(side, side, 3)
	magic.image_set_data(img, side, side, 3, table.concat(rows))
	local tex = magic.Texture2D:new()
	tex:SetData(img)
	local b = parent:CreateChild("BorderImage")
	b.texture = tex
	b:SetFixedSize(side, side)
	return b
end

-- **Two-step login** ([STARPORT] 10a): TOTP on the user's own account. The
-- server answers every request with whether it is on and, while turning it
-- on, the secret to give an authenticator app
local totp_page
local totp_state = {on = 0, secret = "", uri = "", error = ""}
totp_page = function(back)
	local w = open_page("totp", "Two-step login (TOTP)", back)
	local st = totp_state
	if st.error ~= "" then
		page_text(w, st.error, YELLOW)
	end
	if st.secret ~= "" then
		page_text(w, "Add this key to an authenticator app, then enter " ..
				"the code it shows:")
		local k = w:CreateChild("LineEdit")
		k:SetStyleAuto()
		k.minHeight = 26
		k.textCopyable = true
		k.textSelectable = true
		k:SetText(st.secret)
		qr_image(w, st.uri)
		local code = field(w, "Code", false, function() end)
		local r = row(w)
		button(r, "Turn on", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "confirm", code = code:GetText()}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
		return
	end
	page_text(w, st.on == 1 and "On: logging in asks for a code from your " ..
			"authenticator app." or "Off. With it on, logging in also asks " ..
			"for a code from an authenticator app on your phone.")
	if st.on == 1 then
		local code = field(w, "Code", false, function() end)
		local r = row(w)
		button(r, "Turn off", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "off", code = code:GetText()}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
	else
		local r = row(w)
		button(r, "Turn on...", function()
			buildat.send_packet("accounts:totp", cereal.binary_output(
					{cmd = "begin", code = ""}, TOTP_REQ))
		end)
		button(r, "Back", go_back)
	end
end
M.totp_page = function(back)
	totp_state = {on = 0, secret = "", uri = "", error = ""}
	buildat.send_packet("accounts:totp", cereal.binary_output(
			{cmd = "status", code = ""}, TOTP_REQ))
	totp_page(back)
end

buildat.sub_packet("accounts:totp_result", function(data)
	local r = cereal.binary_input(data, TOTP_RESULT)
	totp_state = {on = r.on, secret = r.secret, uri = r.uri, error = r.error}
	if page_kind == "totp" then
		totp_page(page_back)
	end
end)

-- **A ban, its reason and whether it goes to the Starports** ([STARPORT]
-- 10d): ticked by itself for a reason others should know of; a house rule
-- stays here. Only a Starport ID's account is reported
local BAN_REASONS = {
	{"harassment", "Harassment or abuse", true},
	{"illegal", "Illegal content", true},
	{"csam", "Child sexual abuse material", true},
	{"scam", "Scam, phishing or malware", true},
	{"other", "Breaking this server's rules", false},
}
ban_page = function(name, back)
	local w = open_page("ask", "Ban " .. name, back)
	local reason, report = nil, false
	local buttons, rb = {}, nil
	local function draw()
		for k, b in pairs(buttons) do
			b:GetChild(0):SetColor(k == reason and YELLOW or
					magic.Color(1, 1, 1))
		end
		rb:GetChild(0):SetText((report and "[x]" or "[ ]") ..
				" Report to Starport (a Starport ID only)")
	end
	for _, x in ipairs(BAN_REASONS) do
		buttons[x[1]] = button(w, x[2], function()
			reason = x[1]
			report = x[3]
			draw()
		end)
	end
	rb = button(w, "", function()
		report = not report
		draw()
	end)
	draw()
	local r = row(w)
	button(r, "Ban", function()
		M.admin("ban", name, reason or "other", report)
		users_page(back)
	end)
	button(r, "Back", function() users_page(back) end)
end

-- A page of fields under the users page: a password for an account, or a
-- new account's name and password
local function ask_page(title, labels, on_done)
	local w = open_page("ask", title, page_back)
	local back = page_back
	local es = {}
	local function done()
		local v = {}
		for i, e in ipairs(es) do
			v[i] = e:GetText()
		end
		on_done(v[1], v[2])
		users_page(back)
	end
	for i, l in ipairs(labels) do
		es[i] = field(w, l, l == "Password", function()
			if es[i + 1] then
				es[i + 1]:SetFocus(true)
			else
				done()
			end
		end)
	end
	local r = row(w)
	button(r, "OK", done)
	button(r, "Back", function() users_page(back) end)
	es[1]:SetFocus(true)
end

-- simplified: every user on one page, with no scrolling; a server with
-- more users than fit the screen needs a list that scrolls
users_page = function(back)
	local w = open_page("users", "Accounts", back)
	-- What the last request came to, on a line that is always there so
	-- that the buttons under it do not move when it appears; an invite's
	-- code in a field, to copy
	local message = M.message or ""
	local code = message:match("^Invite code: (%w+)$")
	if code then
		local r = row(w)
		page_text(r, "Invite code", YELLOW):SetWordwrap(false)
		local e = r:CreateChild("LineEdit")
		e:SetStyleAuto()
		e.minHeight = 26
		e.minWidth = 120
		e.textCopyable = true
		e.textSelectable = true
		e:SetText(code)
		button(r, "Copy", function()
			magic.ui:SetClipboardText(code)
			notice("Copied the invite code")
		end)
	else
		page_text(w, message ~= "" and message or " ", YELLOW).minHeight = 22
	end
	local u = M.users
	if not u then
		page_text(w, "Waiting for the server...")
		button(w, "Back", go_back)
		return
	end
	-- **The accounts, invites and bans in a list that scrolls** (user,
	-- 2026-09-30): a server's users are more than a phone's screen. Its
	-- height is what is in it, up to under half the screen.
	local list = w:CreateChild("ListView")
	list:SetStyleAuto()
	local item_width = math.max(100, w.width - 32 - 28)
	local lines = 0
	local function item()
		local it = list:CreateChild("UIElement")
		it:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 2, 0, 2))
		it:SetFixedWidth(item_width)
		list:AddItem(it)
		return it
	end
	-- [STARPORT] 10g: Starport IDs waiting for an admin
	for _, name in ipairs(u.approvals or {}) do
		local it = item()
		page_text(it, name .. ": a Starport ID waiting to be let in", YELLOW)
		local r = row(it)
		lines = lines + 2
		button(r, "Let in", function() M.admin("approve", name) end)
		button(r, "Turn away", function() M.admin("turn_away", name) end)
	end
	for _, user in ipairs(u.users) do
		local has = {}
		for _, p in ipairs(user.privs) do
			has[p] = true
		end
		-- The name over its buttons: five of them are a narrow window's
		-- width at the web client's scale
		local it = item()
		page_text(it, user.name .. (user.here == 1 and " (here)" or ""))
		local r = row(it)
		lines = lines + 2
		button(r, has.admin and "Admin: yes" or "Admin: no", function()
			M.admin("priv", user.name, "admin", not has.admin)
		end)
		if user.here == 1 then
			button(r, "Kick", function() M.admin("kick", user.name) end)
		end
		if not has.admin then
			button(r, "Ban...", function() ban_page(user.name, back) end)
		end
		button(r, "Password...", function()
			ask_page("A new password for " .. user.name, {"Password"},
					function(p) M.admin("password", user.name, p) end)
		end)
		button(r, "Delete...", function()
			local w2 = open_page("ask", "Delete the account " .. user.name ..
					"? Their session ends.", back)
			local r2 = row(w2)
			button(r2, "Delete", function()
				M.admin("delete", user.name)
				users_page(back)
			end)
			button(r2, "Back", function() users_page(back) end)
		end)
	end
	if #u.invites > 0 then
		page_text(item(), "Invites (each makes one account):")
		lines = lines + 1
	end
	for _, inv in ipairs(u.invites) do
		local r = row(item())
		lines = lines + 1
		page_text(r, inv.code .. "  (" .. inv.by .. ")"):SetWordwrap(false)
		button(r, "Delete", function() M.admin("uninvite", inv.code) end)
	end
	-- [VANILLA_PUBLIC] 4: a ban is of the account, and of where it joined
	-- from while registration is open
	if #(u.bans or {}) > 0 then
		page_text(item(), "Banned:")
		lines = lines + 1
		for _, b in ipairs(u.bans) do
			local r = row(item())
			lines = lines + 1
			page_text(r, b.name .. (b.address ~= "" and
					"  (" .. b.address .. ")" or "")):SetWordwrap(false)
			button(r, "Unban", function() M.admin("unban", b.name) end)
		end
	end
	list:SetFixedHeight(math.min(lines * 34 + 8,
			math.floor(magic.ui.root.height * 0.45)))
	local r = row(w)
	button(r, "Add a user...", function()
		ask_page("Add a user", {"Name", "Password"},
				function(n, p) M.admin("add", n, p) end)
	end)
	button(r, "New invite", function() M.admin("invite") end)
	local a = u.access
	button(w, a.open_registration == 1 and
			"Local accounts: anyone can make one" or
			"Local accounts: invite only", function()
		M.admin("setting", "open_registration", "", a.open_registration ~= 1)
	end)
	-- [STARPORT] 10g: off, anyone, approved only
	local ids = u.starport_ids or "off"
	local next_ids = {off = "anyone", anyone = "approved", approved = "off"}
	button(w, ({off = "Starport IDs: off",
		anyone = "Starport IDs: anyone may join",
		approved = "Starport IDs: approved only"})[ids] or ids, function()
		M.admin("setting", "starport_ids", next_ids[ids] or "off")
	end)
	local r2 = row(w)
	button(r2, "Starport...", function() M.starport_page(back) end)
	button(r2, "Back", go_back)
end
--
-- **The server's Starport page** ([STARPORT] 10g): starport.json, which
-- builtin/starport_announce writes and watches, and what each Starport last
-- answered. The admin's only; the server checks.
--
-- The keys whose values are lists, empty ones too (the sandbox has no
-- metatables to mark them by)
local ARRAY_KEYS = {starports = true, tags = true, languages = true}
local function encode(v, as_array)
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
	if as_array or v[1] ~= nil then
		for _, x in ipairs(v) do
			out[#out + 1] = encode(x)
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	if next(v) == nil then
		return "{}"
	end
	for k, x in pairs(v) do
		out[#out + 1] = encode(tostring(k)) .. ":" .. encode(x, ARRAY_KEYS[k])
	end
	return "{" .. table.concat(out, ",") .. "}"
end
assert(encode({a = {1, "x\n"}}) == '{"a":[1,"x\\n"]}')
assert(encode({starports = {}}) == '{"starports":[]}')

local starport_info = nil
local starport_page
buildat.sub_packet("starport:config", function(data)
	starport_info = buildat.parse_json(data)
	if page_kind == "starport" then
		starport_page(page_back)
	end
end)

local LISTING_FIELDS = {"name", "description", "kind", "audience", "access",
	"signup_url", "region", "fleet", "pool"}

starport_page = function(back, confirm_remove)
	local w = open_page("starport", "Starport", back)
	local info = starport_info
	if not info then
		page_text(w, "Waiting for the server...")
		button(w, "Back", function() users_page(back) end)
		return
	end
	local c = info.config or {}
	if type(c.starports) ~= "table" then
		c.starports = {}
	end
	local function save()
		buildat.send_packet("starport:config_set", encode(c))
	end
	if info.message and info.message ~= "" then
		page_text(w, info.message, YELLOW)
	end
	page_text(w, "Written to " .. tostring(info.path) .. ", which an edit "..
			"by hand changes too", GREY)
	local r = row(w)
	button(r, c.enabled == false and "Starport: off" or "Starport: on",
			function()
		c.enabled = c.enabled == false
		save()
	end)
	button(r, c.unlisted and "Unlisted: yes (IDs, not in the list)" or
			"Unlisted: no", function()
		c.unlisted = not c.unlisted
		save()
	end)
	for i, s in ipairs(info.starports or {}) do
		page_text(w, tostring(s.url) .. ": " .. tostring(s.status ~= "" and
				s.status or "not announced yet"))
		page_text(w, "listing " .. tostring(s.listing or "-") ..
				", claim code " .. tostring(s.claim or "-") .. "; " ..
				tostring(s.linked or 0) .. " accounts linked to its IDs" ..
				((s.subscribed and #s.subscribed > 0) and "; follows " ..
				table.concat(s.subscribed, ", ") or ""), GREY)
		if confirm_remove == s.url then
			page_text(w, "Remove it? Its listing is withdrawn at once, and "..
					tostring(s.linked or 0) .. " accounts cannot log in by "..
					"their IDs while it is gone (an admin can give them "..
					"passwords).", YELLOW)
			local rr = row(w)
			button(rr, "Remove", function()
				table.remove(c.starports, i)
				save()
			end)
			button(rr, "Keep it", function() starport_page(back) end)
		else
			button(w, "Remove " .. tostring(s.url), function()
				starport_page(back, s.url)
			end)
		end
	end
	local add = field(w, "Add a Starport", false, function() end)
	add:SetText("https://")
	button(w, "Add", function()
		local url = add:GetText():gsub("/+$", "")
		if url:match("^https?://[%w%.%-]+[:%d]*$") then
			table.insert(c.starports, url)
			save()
		end
	end)
	-- The listing: what the server says it is ([STARPORT] 3)
	local edits = {}
	for _, k in ipairs(LISTING_FIELDS) do
		edits[k] = field(w, k, false, function() end)
		edits[k]:SetText(tostring(c[k] or ""))
	end
	local rest = field(w, "descriptors, tags, languages (JSON)", false,
			function() end)
	rest:SetText(encode({descriptors = c.descriptors or {},
		tags = c.tags or {}, languages = c.languages or {}}))
	local r3 = row(w)
	button(r3, "Save the listing", function()
		for _, k in ipairs(LISTING_FIELDS) do
			local v = edits[k]:GetText()
			c[k] = v ~= "" and v or nil
		end
		local more = buildat.parse_json(rest:GetText())
		if type(more) == "table" then
			c.descriptors = more.descriptors
			c.tags = more.tags
			c.languages = more.languages
		end
		save()
	end)
	button(r3, "Back", function() users_page(back) end)
end
M.starport_page = function(back)
	starport_info = nil
	buildat.send_packet("starport:config_get", "")
	starport_page(back)
end

M.users_page = function(back)
	M.admin("list")
	users_page(back)
end

--
-- **The chat console** ([CHAT_CONSOLE]): the chat as a page of its own, a
-- log that scrolls and a line to type in, for a touchscreen, where there
-- is no key to open a game's chat line, and for reading back. The game
-- hands it every line with chat_add() and sets chat_send(text).
--
M.chat_lines = {}
M.chat_send = nil
local CHAT_KEEP = 200

local function chat_row(text)
	local t = chat_list:CreateChild("Text")
	t:SetStyleAuto()
	t:SetWordwrap(true)
	t:SetFixedWidth(chat_width)
	t:SetText(text)
	chat_list:AddItem(t)
end

local function chat_to_end()
	chat_list.viewPosition = magic.IntVector2(0, 1000000)
end

function M.chat_add(line)
	M.chat_lines[#M.chat_lines + 1] = line
	while #M.chat_lines > CHAT_KEEP do
		table.remove(M.chat_lines, 1)
	end
	if chat_list then
		chat_row(line)
		chat_to_end()
	end
end

function M.chat_page(back)
	local w = open_page("chat", "Chat", back)
	chat_width = math.max(100, w.width - 32 - 28)
	chat_list = w:CreateChild("ListView")
	chat_list:SetStyleAuto()
	chat_list:SetFixedHeight(math.max(120,
			math.floor(magic.ui.root.height * 0.5)))
	for _, line in ipairs(M.chat_lines) do
		chat_row(line)
	end
	local r = row(w)
	local e = r:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 28
	e.textCopyable = true
	e.textSelectable = true
	local function send()
		local text = e:GetText()
		if text ~= "" and M.chat_send then
			M.chat_send(text)
		end
		e:SetText("")
	end
	magic.SubscribeToEvent(e, "TextFinished", send)
	local b = button(r, "Send", send)
	b:SetFixedWidth(b.minWidth)
	button(w, "Back", go_back)
	chat_to_end()
	-- A touchscreen's keyboard would cover the log: it opens on a tap
	if buildat.get_env("BUILDAT_TOUCH") ~= "1" then
		e:SetFocus(true)
	end
end

-- The join: the server's hello brings the dialog, or the scripted login
function M.start(o)
	opts = o or {}
	buildat.send_packet("accounts:get_hello", "")
end

return M
-- vim: set noet ts=4 sw=4:
