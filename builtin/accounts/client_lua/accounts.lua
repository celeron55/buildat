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
-- A scripted client joins by the environment: <env>_NAME, <env>_PASSWORD and
-- <env>_CODE (env is "BUILDAT_JOIN" by default).
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
		{"code", "string"}}
local HELLO = {"object", {"local", "byte"}, {"setup", "byte"},
		{"open_registration", "byte"}}
local ADMIN = {"object", {"cmd", "string"}, {"name", "string"},
		{"arg", "string"}, {"on", "byte"}}
local USERS = {"object",
	{"users", {"array", {"object", {"name", "string"},
			{"privs", {"array", "string"}}, {"here", "byte"}}}},
	{"invites", {"array", {"object", {"code", "string"},
			{"privs", {"array", "string"}}, {"by", "string"}}}},
	{"access", {"object", {"open_registration", "byte"}}},
	{"bans", {"array", {"object", {"name", "string"}, {"address", "string"}}}},
}

local opts = {}
local window = nil

local function notice(text)
	if M.notice then
		M.notice(text)
	else
		log:info(text)
	end
end

local function send_login(name, password, code)
	buildat.send_packet("accounts:login", cereal.binary_output(
			{name = name, password = password, code = code or ""}, LOGIN))
end

-- A window of the join: `width` wide, or the screen's width less a margin
-- on a narrow one ([FP_TOUCH] 2), and its texts wrap to it
local function page_window(width)
	local w = magic.ui.root:CreateChild("Window")
	w:SetStyleAuto()
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
	label(opts.title or "Join")
	label("Name")
	-- The name used last on this server, kept on the client; else the one
	-- the user gave the client for every game
	local name = field(buildat.storage_read("name") or
			buildat.get_preference("default_username") or "", false)
	local password = nil
	local code = nil
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
		M.name = n
		send_login(n, password and password:GetText() or "",
				code and code:GetText() or "")
	end
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
	if auto_name and not M.auto_tried then
		M.auto_tried = true
		M.name = auto_name
		send_login(auto_name, buildat.get_env(env .. "_PASSWORD") or "",
				buildat.get_env(env .. "_CODE") or "")
	else
		show_login(nil)
	end
end)

buildat.sub_packet("accounts:login_result", function(data)
	local err = cereal.binary_input(data, TEXT).text
	if err ~= "" then
		log:info("Login refused: " .. err)
		show_login(err)
		return
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
	if M.on_users then
		M.on_users()
	end
end)

buildat.sub_packet("accounts:admin_result", function(data)
	M.message = cereal.binary_input(data, TEXT).text
	if M.on_admin_result then
		M.on_admin_result(M.message)
	end
end)

buildat.sub_packet("accounts:passwd_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	if M.on_passwd then
		M.on_passwd(text)
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
	buildat.send_packet("accounts:admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = on and 1 or 0}, ADMIN))
end

function M.passwd(old, new)
	buildat.send_packet("accounts:passwd", cereal.binary_output(
			{old = old, new = new}, {"object", {"old", "string"},
			{"new", "string"}}))
end

-- The join: the server's hello brings the dialog, or the scripted login
function M.start(o)
	opts = o or {}
	buildat.send_packet("accounts:get_hello", "")
end

return M
-- vim: set noet ts=4 sw=4:
