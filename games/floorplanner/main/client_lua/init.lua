-- Buildat: games/floorplanner/main/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The floor planner's client: the join dialog, the replica of the document,
-- the chat, and the editor (editor.lua). doc/plan/floorplanner_plan.md is
-- the spec; the server (main.cpp) holds the document and checks everything.
local log = buildat.Logger("floorplanner")
local cereal = require("buildat/extension/cereal")
local magic = require("buildat/extension/urho3d")

local STYLE = magic.cache:GetResource("XMLFile", "launch_menu/res/main_style.xml")
magic.ui.root.defaultStyle = STYLE

-- The wire types, the same as main.cpp's structs field for field
local ENTITY = {"object",
	{"id", "int32_t"},
	{"type", "string"},
	{"ints", {"unordered_map", "string", "int32_t"}},
	{"strs", {"unordered_map", "string", "string"}},
	{"lists", {"unordered_map", "string", {"array", "int32_t"}}},
}
local TEXT = {"object", {"text", "string"}}
-- The code is the setup code of a plan with no admin, or an invite code
-- for a new account ([FP_ACCESS])
local LOGIN = {"object", {"name", "string"}, {"password", "string"},
		{"code", "string"}}
local BATCH = {"object",
	{"seq", "int32_t"},
	{"ops", {"array", {"object", {"op", "byte"}, {"ent", ENTITY}}}},
}
local BATCH_RESULT = {"object",
	{"seq", "int32_t"},
	{"error", "string"},
	{"placeholders", {"unordered_map", "int32_t", "int32_t"}},
}
local CHANGES = {"object",
	{"seq", "int32_t"},
	{"sender", "int32_t"},
	{"ents", {"array", ENTITY}},
	{"deleted", {"array", "int32_t"}},
}

--
-- The replica
--
-- doc.ents[id] is what the server last said about each entity; nothing
-- here changes it but the server's packets. An edit is a batch sent with
-- doc.send(); the result comes back as fp:changes to everybody.
local doc = {
	ents = {},
	privs = {},
	-- Called with (changed_ids, deleted_ids) after every change
	listeners = {},
	-- seq -> {done = function(error, placeholders), kind, inverse}, for
	-- this client's own batches
	pending = {},
	next_seq = 1,
	-- What undoes each batch of this user's, newest last
	undo_stack = {},
	redo_stack = {},
	-- Each voxel volume's voxels: definition id -> {cell key -> palette
	-- entry}, and a count per definition that grows with every change
	voxels = {},
	voxel_version = {},
	-- Other users: peer -> {name, p (their presence), preview (entity id
	-- -> the fields their drag would give it)}
	others = {},
}
local UNDO_DEPTH = 200

function doc.can(priv)
	return doc.privs[priv] == true
end

function doc.of_type(type)
	local out = {}
	for id, e in pairs(doc.ents) do
		if e.type == type then
			out[#out + 1] = e
		end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function doc.settings()
	return doc.of_type("settings")[1]
end

-- ops: {{op = "create"|"set"|"delete", ent = {id =, type =, ints =, ...}}}
-- A created entity takes a negative id, unique in the batch, which other ops
-- in it may refer to; done(error, placeholders) gets the real ids.
local OP_CODES = {create = 0, set = 1, delete = 2, restore = 3}
local LAYERED = {node = true, instance = true, image = true}
-- kind: nil for an edit, "undo" or "redo" for what undoes one
function doc.send(ops, done, kind)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	local wire = {}
	for i, op in ipairs(ops) do
		local e = op.ent
		local ints = e.ints or {}
		-- A new node, instance or picture is the current layout's
		-- ([FP_LAYOUTS]); walls and rooms are their nodes'
		if op.op == "create" and LAYERED[e.type] and not ints.layout then
			ints.layout = doc.layout or 0
		end
		wire[i] = {op = OP_CODES[op.op], ent = {id = e.id, type = e.type or "",
				ints = ints, strs = e.strs or {}, lists = e.lists or {}}}
	end
	doc.pending[seq] = {kind = kind, done = done or function(err)
		if err ~= "" then
			doc.notice("Refused: " .. err)
		end
	end}
	buildat.send_packet("fp:batch",
			cereal.binary_output({seq = seq, ops = wire}, BATCH))
end

-- A negative id for a new entity, unique for this session
local next_placeholder = -1
function doc.placeholder()
	next_placeholder = next_placeholder - 1
	return next_placeholder
end

local function notify(changed, deleted)
	for _, f in ipairs(doc.listeners) do
		f(changed, deleted)
	end
end

buildat.sub_packet("fp:snapshot", function(data)
	local ents = cereal.binary_input(data, {"array", ENTITY})
	doc.ents = {}
	local changed = {}
	for _, e in ipairs(ents) do
		doc.ents[e.id] = e
		changed[#changed + 1] = e.id
	end
	log:info("Snapshot: " .. #ents .. " entities")
	doc.joined()
	notify(changed, {})
end)

local function same(a, b)
	if type(a) ~= "table" then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function copy(t)
	local o = {}
	for k, v in pairs(t) do
		o[k] = type(v) == "table" and copy(v) or v
	end
	return o
end

-- What undoes a batch, from what the server says it changed and the
-- replica before it: what it deleted is restored, what it made is
-- deleted, and each changed field is set back. `expect` is what a field
-- was left at, so an undo can skip one somebody else has changed since.
local function inverse_of(c)
	local restores, sets, deletes = {}, {}, {}
	for _, e in ipairs(c.ents) do
		local old = doc.ents[e.id]
		if not old then
			deletes[#deletes + 1] = {op = "delete", ent = {id = e.id}}
		else
			local ent = {id = e.id, ints = {}, strs = {}, lists = {}}
			local expect = {ints = {}, strs = {}, lists = {}}
			local any = false
			for _, part in ipairs({"ints", "strs", "lists"}) do
				for k, v in pairs(e[part]) do
					if not same(old[part][k], v) then
						ent[part][k] = old[part][k]
						expect[part][k] = v
						any = true
					end
				end
			end
			if any then
				sets[#sets + 1] = {op = "set", ent = ent, expect = expect}
			end
		end
	end
	for _, id in ipairs(c.deleted) do
		local old = doc.ents[id]
		if old then
			restores[#restores + 1] = {op = "restore", ent = copy(old)}
		end
	end
	local out = {}
	for _, list in ipairs({restores, sets, deletes}) do
		for _, op in ipairs(list) do
			out[#out + 1] = op
		end
	end
	return out
end

-- An undo or redo, less what has changed under it since: a field somebody
-- else has set is left as they set it
local function still_applies(ops)
	local out, skipped = {}, 0
	for _, op in ipairs(ops) do
		local cur = doc.ents[op.ent.id]
		if op.op == "restore" then
			if cur then
				skipped = skipped + 1
			else
				out[#out + 1] = op
			end
		elseif op.op == "delete" then
			if cur then
				out[#out + 1] = op
			end
		elseif cur then
			local ent = {id = op.ent.id, ints = {}, strs = {}, lists = {}}
			local any = false
			for _, part in ipairs({"ints", "strs", "lists"}) do
				for k, v in pairs(op.ent[part]) do
					if same(cur[part][k], op.expect[part][k]) then
						ent[part][k] = v
						any = true
					else
						skipped = skipped + 1
					end
				end
			end
			if any then
				out[#out + 1] = {op = "set", ent = ent}
			end
		end
	end
	return out, skipped
end

local function step(from, kind)
	local ops = table.remove(from)
	if not ops then
		doc.notice("Nothing to " .. kind)
		return
	end
	if ops.voxels then
		-- Voxels set back, but not where somebody has set them since
		local sets, skipped = {}, 0
		local cur = doc.voxels[ops.def] or {}
		for key, v in pairs(ops.voxels) do
			if (cur[key] or 0) == ops.expect[key] then
				sets[key] = v
			else
				skipped = skipped + 1
			end
		end
		if skipped > 0 then
			doc.notice(skipped .. " voxels changed by somebody else since")
		end
		if next(sets) then
			doc.set_voxels(ops.def, sets, kind)
		end
		return
	end
	local left, skipped = still_applies(ops)
	if skipped > 0 then
		doc.notice(skipped .. " changed by somebody else since; left as is")
	end
	if #left > 0 then
		doc.send(left, nil, kind)
	end
end

function doc.undo()
	step(doc.undo_stack, "undo")
end

function doc.redo()
	step(doc.redo_stack, "redo")
end

buildat.sub_packet("fp:changes", function(data)
	local c = cereal.binary_input(data, CHANGES)
	local own = c.seq >= 0 and doc.pending[c.seq]
	if own then
		own.inverse = inverse_of(c)
	end
	local changed = {}
	for _, e in ipairs(c.ents) do
		doc.ents[e.id] = e
		changed[#changed + 1] = e.id
	end
	for _, id in ipairs(c.deleted) do
		doc.ents[id] = nil
	end
	notify(changed, c.deleted)
end)

buildat.sub_packet("fp:batch_result", function(data)
	local r = cereal.binary_input(data, BATCH_RESULT)
	local p = doc.pending[r.seq]
	doc.pending[r.seq] = nil
	if not p then
		return
	end
	-- An edit is undone by its inverse; an undo is redone by its own, and
	-- a redo undone again
	if r.error == "" and p.inverse and #p.inverse > 0 then
		local stack = p.kind == "undo" and doc.redo_stack or doc.undo_stack
		stack[#stack + 1] = p.inverse
		if #stack > UNDO_DEPTH then
			table.remove(stack, 1)
		end
		if not p.kind then
			doc.redo_stack = {}
		end
	end
	p.done(r.error, r.placeholders)
end)

-- The pictures the server has to trace over, by file name
doc.images = {}
buildat.sub_packet("fp:images", function(data)
	doc.images = cereal.binary_input(data, {"array", "string"})
	if doc.privs_changed then
		doc.privs_changed()
	end
end)

-- The admin's menus and the password change ([FP_ACCESS] 4): the
-- accounts, the open invites and the access settings, which the server
-- sends an admin at the join and after every change; what a request came to
local ADMIN = {"object", {"cmd", "string"}, {"name", "string"},
		{"arg", "string"}, {"on", "byte"}}
local USERS = {"object",
	{"users", {"array", {"object", {"name", "string"},
			{"privs", {"array", "string"}}, {"here", "byte"}}}},
	{"invites", {"array", {"object", {"code", "string"},
			{"privs", {"array", "string"}}, {"by", "string"}}}},
	{"access", {"object", {"open_registration", "byte"}}},
}
-- A plan's members ([FP_PLANS] 5): its owner, whether others read or edit
-- it, and each account's role in it
local MEMBERS = {"object", {"plan", "string"}, {"owner", "string"},
	{"pub", "int32_t"},
	{"members", {"array", {"object", {"name", "string"}, {"role", "string"}}}},
}
doc.members = nil
function doc.plan_admin(cmd, name, arg)
	buildat.send_packet("fp:plan_admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = 0}, ADMIN))
end
buildat.sub_packet("fp:members", function(data)
	doc.members = cereal.binary_input(data, MEMBERS)
	if doc.members_changed then
		doc.members_changed()
	end
end)
doc.users = nil
function doc.admin(cmd, name, arg, on)
	buildat.send_packet("fp:admin", cereal.binary_output({cmd = cmd,
			name = name or "", arg = arg or "", on = on and 1 or 0}, ADMIN))
end
function doc.passwd(old, new)
	buildat.send_packet("fp:passwd", cereal.binary_output(
			{old = old, new = new}, {"object", {"old", "string"},
			{"new", "string"}}))
end
buildat.sub_packet("fp:users", function(data)
	doc.users = cereal.binary_input(data, USERS)
	if doc.users_changed then
		doc.users_changed()
	end
end)
buildat.sub_packet("fp:admin_result", function(data)
	doc.admin_message = cereal.binary_input(data, TEXT).text
	if doc.users_changed then
		doc.users_changed()
	end
	if doc.members_changed then
		doc.members_changed()
	end
end)
buildat.sub_packet("fp:passwd_result", function(data)
	local text = cereal.binary_input(data, TEXT).text
	if doc.passwd_done then
		doc.passwd_done(text)
	end
end)

buildat.sub_packet("fp:privs", function(data)
	doc.privs = {}
	for _, p in ipairs(cereal.binary_input(data, {"array", "string"})) do
		doc.privs[p] = true
	end
	if doc.privs_changed then
		doc.privs_changed()
	end
end)

--
-- Voxels
--
local VOXELS = {"object", {"seq", "int32_t"}, {"def", "int32_t"},
	{"sets", {"unordered_map", "int32_t", "int32_t"}}}
-- The same bytes written as pairs: cereal.binary_output cannot write a map
-- with number keys, since tracing one turns the key into a string in place
-- (lua_tostring in src/lua_bindings/cereal.cpp), which breaks lua_next
local VOXELS_OUT = {"object", {"seq", "int32_t"}, {"def", "int32_t"},
	{"sets", {"array", {"object", {"k", "int32_t"}, {"v", "int32_t"}}}}}
local VOXELS_RESULT = {"object", {"seq", "int32_t"}, {"error", "string"}}

-- A cell of a volume as one number: x, y and z from -128 to 127
function doc.voxel_key(x, y, z)
	return (x + 128) + (y + 128) * 256 + (z + 128) * 65536
end

function doc.voxel_cell(key)
	return key % 256 - 128, math.floor(key / 256) % 256 - 128,
			math.floor(key / 65536) - 128
end

-- sets: cell key -> palette entry, 0 to empty the cell. Undone like a
-- batch: what the cells held before, back.
local voxel_pending = {}
function doc.set_voxels(def, sets, kind)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	local cur = doc.voxels[def] or {}
	local inverse, expect = {}, {}
	for key, v in pairs(sets) do
		inverse[key] = cur[key] or 0
		expect[key] = v
	end
	voxel_pending[seq] = {kind = kind, undo = {voxels = inverse, def = def,
			expect = expect}}
	local pairs_ = {}
	for key, v in pairs(sets) do
		pairs_[#pairs_ + 1] = {k = key, v = v}
	end
	buildat.send_packet("fp:voxels", cereal.binary_output({seq = seq,
			def = def, sets = pairs_}, VOXELS_OUT))
end

buildat.sub_packet("fp:voxels", function(data)
	local v = cereal.binary_input(data, VOXELS)
	local vox = doc.voxels[v.def] or {}
	doc.voxels[v.def] = vox
	for key, m in pairs(v.sets) do
		vox[key] = m ~= 0 and m or nil
	end
	doc.voxel_version[v.def] = (doc.voxel_version[v.def] or 0) + 1
	if doc.voxels_changed then
		doc.voxels_changed(v.def)
	end
end)

buildat.sub_packet("fp:voxels_result", function(data)
	local r = cereal.binary_input(data, VOXELS_RESULT)
	local p = voxel_pending[r.seq]
	voxel_pending[r.seq] = nil
	if not p then
		return
	end
	if r.error ~= "" then
		doc.notice("Refused: " .. r.error)
		return
	end
	local stack = p.kind == "undo" and doc.redo_stack or doc.undo_stack
	stack[#stack + 1] = p.undo
	if #stack > UNDO_DEPTH then
		table.remove(stack, 1)
	end
	if not p.kind then
		doc.redo_stack = {}
	end
end)

--
-- Drag locks, previews and presence
--
local LOCK = {"object", {"seq", "int32_t"}, {"ids", {"array", "int32_t"}}}
local LOCK_RESULT = {"object", {"seq", "int32_t"}, {"error", "string"}}
local PREVIEW = {"object", {"peer", "int32_t"}, {"ents", {"array", ENTITY}}}
local PRESENCE = {"object",
	{"view", "byte"},
	{"cx", "int32_t"}, {"cz", "int32_t"},
	{"px", "int32_t"}, {"py", "int32_t"}, {"pz", "int32_t"},
	{"yaw", "int32_t"}, {"pitch", "int32_t"},
	{"sel", {"array", "int32_t"}},
}
local PRESENCE_OUT = {"object", {"peer", "int32_t"}, {"name", "string"},
	{"p", PRESENCE}}

-- A drag takes the lock on what it moves; refused(why) when somebody else
-- holds it
local lock_waiting = {}
function doc.lock(ids, refused)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	lock_waiting[seq] = refused
	buildat.send_packet("fp:lock", cereal.binary_output({seq = seq, ids = ids},
			LOCK))
end

function doc.unlock()
	buildat.send_packet("fp:unlock", "")
end

buildat.sub_packet("fp:lock_result", function(data)
	local r = cereal.binary_input(data, LOCK_RESULT)
	local refused = lock_waiting[r.seq]
	lock_waiting[r.seq] = nil
	if refused and r.error ~= "" then
		refused(r.error)
	end
end)

-- ents: {{id =, ints = {...}}}, what a drag would make of them
function doc.preview(ents)
	local wire = {}
	for i, e in ipairs(ents) do
		wire[i] = {id = e.id, type = "", ints = e.ints, strs = {}, lists = {}}
	end
	buildat.send_packet("fp:preview", cereal.binary_output(wire,
			{"array", ENTITY}))
end

local function other(peer)
	doc.others[peer] = doc.others[peer] or {preview = {}}
	return doc.others[peer]
end

buildat.sub_packet("fp:preview", function(data)
	local p = cereal.binary_input(data, PREVIEW)
	local o = other(p.peer)
	o.preview = {}
	for _, e in ipairs(p.ents) do
		o.preview[e.id] = e.ints
	end
	if doc.others_changed then
		doc.others_changed()
	end
end)

-- The fields entity id would have if the others' drags landed now, or nil
function doc.previewed(id)
	for _, o in pairs(doc.others) do
		if o.preview[id] then
			return o.preview[id]
		end
	end
	return nil
end

function doc.send_presence(p)
	buildat.send_packet("fp:presence", cereal.binary_output(p, PRESENCE))
end

buildat.sub_packet("fp:presence", function(data)
	local r = cereal.binary_input(data, PRESENCE_OUT)
	local o = other(r.peer)
	o.name, o.p = r.name, r.p
end)

buildat.sub_packet("fp:gone", function(data)
	local peer = cereal.binary_input(data, {"object", {"peer", "int32_t"}}).peer
	doc.others[peer] = nil
	if doc.others_changed then
		doc.others_changed()
	end
end)

--
-- Messages: the chat, and the notices the client gives itself
--
local MSG_LINES = 8
local MSG_SECONDS = 20
local messages = {}
local msg_text = magic.ui.root:CreateChild("Text")
msg_text:SetFont(magic.cache:GetResource("Font", buildat.font_sans), 14)
msg_text.horizontalAlignment = magic.HA_LEFT
msg_text.verticalAlignment = magic.VA_BOTTOM
msg_text:SetPosition(10, -44)
msg_text:SetTextEffect(magic.TE_SHADOW)
msg_text.priority = 100

local function redraw_messages()
	local now = buildat.get_time_us()
	local keep = {}
	for _, m in ipairs(messages) do
		if now - m.t < MSG_SECONDS * 1000000 then
			keep[#keep + 1] = m
		end
	end
	while #keep > MSG_LINES do
		table.remove(keep, 1)
	end
	messages = keep
	local lines = {}
	for _, m in ipairs(messages) do
		lines[#lines + 1] = m.text
	end
	local text = table.concat(lines, "\n")
	if text ~= msg_text.text then
		msg_text:SetText(text)
	end
end

function doc.notice(text)
	log:info(text)
	messages[#messages + 1] = {text = text, t = buildat.get_time_us()}
	redraw_messages()
end

buildat.sub_packet("fp:chat", function(data)
	doc.notice(cereal.binary_input(data, TEXT).text)
end)

buildat.sub_packet("fp:kicked", function(data)
	doc.notice(cereal.binary_input(data, TEXT).text)
	buildat.disconnect()
end)

local chat_input = nil

-- True while a text field has the keyboard, so the editor leaves keys alone
function doc.typing()
	local f = magic.ui.focusElement
	return f ~= nil and f:GetTypeName() == "LineEdit"
end

local function close_chat()
	if chat_input then
		chat_input:Remove()
		chat_input = nil
		magic.ui:SetFocusElement(nil)
	end
end

local function open_chat(initial)
	if chat_input then
		return
	end
	chat_input = magic.ui.root:CreateChild("LineEdit")
	chat_input.textCopyable = true
	chat_input.textSelectable = true
	chat_input:SetStyleAuto()
	chat_input.horizontalAlignment = magic.HA_LEFT
	chat_input.verticalAlignment = magic.VA_BOTTOM
	chat_input.size = magic.IntVector2(
			math.min(560, magic.ui.root.width - 20), 26)
	chat_input:SetPosition(10, -10)
	chat_input:SetText(initial or "")
	chat_input:SetFocus(true)
	magic.SubscribeToEvent(chat_input, "TextFinished", function(self)
		local text = chat_input:GetText()
		close_chat()
		if text ~= "" then
			buildat.send_packet("fp:chat",
					cereal.binary_output({text = text}, TEXT))
		end
	end)
end

--
-- The join dialog
--
local login_window = nil
-- What the server said last in fp:hello; the join dialog reads it
local hello = {}

local function send_login(name, password, code)
	buildat.send_packet("fp:login", cereal.binary_output(
			{name = name, password = password, code = code or ""}, LOGIN))
end

-- simplified: the join dialog is rebuilt on every error rather than
-- updated
local function show_login(error_text, is_local)
	if login_window then
		login_window:Remove()
	end
	local w = magic.ui.root:CreateChild("Window")
	login_window = w
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w.minWidth = 380
	local function label(text)
		local t = w:CreateChild("Text")
		t:SetStyleAuto()
		t:SetText(text)
		return t
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
	label("Floor planner")
	label("Name")
	-- The name used last on this server, kept on the client; else the one
	-- the user gave the client for every game
	local name = field(buildat.storage_read("name") or
			buildat.get_preference("default_username") or "", false)
	local password = nil
	local code = nil
	if is_local then
		-- The plan is on this machine: no password to ask
		label("On this computer: no password needed")
	else
		label(hello.open_registration == 1 and
				"Password (a new name makes an account)" or "Password")
		password = field("", true)
		-- [FP_ACCESS]: the plan's first admin claims it with the code in the
		-- server's log; while registration is closed a new account needs an
		-- invite
		if hello.setup == 1 then
			label("Setup code (see the server's log)")
			code = field("", false)
		elseif hello.open_registration ~= 1 then
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
		doc.rejoin_name = n
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

-- The plans ([FP_PLANS] 4): after the join, the ones this user may read,
-- to open one or make a new one, which is theirs
local PLAN_ROWS = {"array", {"object", {"name", "string"}, {"owner", "string"},
		{"role", "string"}, {"here", "int32_t"}}}
doc.plans = {}
local auto_plan_done = false

local function open_plan(name, create)
	buildat.send_packet("fp:open", cereal.binary_output(
			{name = name, create = create and 1 or 0},
			{"object", {"name", "string"}, {"create", "byte"}}))
end

local ROLE_TEXT = {admin = "admin", owner = "yours", editor = "can edit",
		viewer = "can read"}

local function show_plans(message)
	if login_window then
		login_window:Remove()
	end
	local w = magic.ui.root:CreateChild("Window")
	login_window = w
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w.minWidth = 420
	local function text(t, color)
		local l = w:CreateChild("Text")
		l:SetStyleAuto()
		l:SetText(t)
		if color then
			l:SetColor(color)
		end
	end
	local function button(t, f)
		local b = w:CreateChild("Button")
		b:SetStyleAuto()
		b.minHeight = 28
		local bt = b:CreateChild("Text")
		bt:SetStyleAuto()
		bt:SetText(t)
		bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(b, "Released", f)
	end
	log:info("Plan picker: " .. #doc.plans .. " plans")
	text("Floor planner: open a plan")
	if message and message ~= "" then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	-- The one this user was in last, first
	local last = buildat.storage_read("plan")
	local rows = {}
	for _, p in ipairs(doc.plans) do
		if p.name == last then
			table.insert(rows, 1, p)
		else
			rows[#rows + 1] = p
		end
	end
	for _, p in ipairs(rows) do
		local label = p.name .. "  (" .. (ROLE_TEXT[p.role] or p.role) ..
				(p.owner ~= "" and p.role ~= "owner" and ", " .. p.owner .. "'s" or
				"") .. (p.here > 0 and ", " .. p.here .. " here" or "") .. ")"
		button(label, function() open_plan(p.name, false) end)
	end
	if #rows == 0 then
		text("There are no plans yet")
	end
	text("Or a new one, by name:")
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	local function create()
		local n = e:GetText()
		if n ~= "" then
			open_plan(n, true)
		end
	end
	magic.SubscribeToEvent(e, "TextFinished", create)
	button("New plan", create)
	button("Import a plan...", function() doc.show_import() end)
	e:SetFocus(true)
end

-- **A plan from a file** ([FP_EXPORT] 3): on the web the browser's file
-- picker; on native the .fpplan files in <user>/exports, where an export
-- goes. Then a name for it, which a new plan of this user's gets.
local IMPORT = {"object", {"name", "string"}, {"file", "string"}}
local web = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local picking = false

local function page(title)
	if login_window then
		login_window:Remove()
	end
	local w = magic.ui.root:CreateChild("Window")
	login_window = w
	w:SetStyleAuto()
	w:SetLayout(magic.LM_VERTICAL, 8, magic.IntRect(16, 16, 16, 16))
	w:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	w.minWidth = 420
	local function text(t, color)
		local l = w:CreateChild("Text")
		l:SetStyleAuto()
		l:SetText(t)
		if color then
			l:SetColor(color)
		end
	end
	local function button(t, f)
		local b = w:CreateChild("Button")
		b:SetStyleAuto()
		b.minHeight = 28
		local bt = b:CreateChild("Text")
		bt:SetStyleAuto()
		bt:SetText(t)
		bt:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
		magic.SubscribeToEvent(b, "Released", f)
	end
	text(title)
	return w, text, button
end

-- The file being imported, for its page again when the server refuses
local importing = nil

local function import_as(file_name, data, message)
	importing = {file_name, data}
	local w, text, button = page("Import " .. file_name .. " as a new plan:")
	if message then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	-- The file's name as a plan's: letters, digits, _ and -
	local name = file_name:gsub("%.fpplan$", ""):gsub("[^%w_%-]", "_")
			:gsub("^_+", ""):sub(1, 40)
	local e = w:CreateChild("LineEdit")
	e:SetStyleAuto()
	e.minHeight = 26
	e.textSelectable = true
	e:SetText(name ~= "" and name or "imported")
	local function go()
		local n = e:GetText()
		if n == "" then
			return
		end
		text("Sending " .. math.floor(#data / 1024 + 0.5) .. " KiB...")
		buildat.send_packet("fp:import", cereal.binary_output(
				{name = n, file = data}, IMPORT))
	end
	magic.SubscribeToEvent(e, "TextFinished", go)
	button("Import", go)
	button("Back", function()
		importing = nil
		show_plans()
	end)
	e:SetFocus(true)
end

function doc.show_import(message)
	local _, text, button = page("Import a plan from a file (.fpplan)")
	if message then
		text(message, magic.Color(1.0, 0.4, 0.4))
	end
	if web then
		button("Choose a file...", function()
			picking = buildat.pick_file(".fpplan")
		end)
	else
		local any = false
		local files = buildat.exported_files()
		table.sort(files)
		for _, f in ipairs(files) do
			if f:match("%.fpplan$") then
				any = true
				button(f, function()
					local data, why = buildat.read_exported(f)
					if data then
						import_as(f, data)
					else
						doc.show_import(why)
					end
				end)
			end
		end
		if not any then
			text("No .fpplan files in the exports folder, where")
			text("\"Export this plan\" puts them: <user>/exports")
		end
	end
	button("Back", function() show_plans() end)
end

-- The web's picked file, once the browser has read it
local function poll_picked()
	if not picking then
		return
	end
	local file_name, data = buildat.picked_file()
	if file_name then
		picking = false
		import_as(file_name, data)
	elseif data then
		picking = false
		doc.show_import(data)
	end
end

-- The open plan as a file: the server sends it, and the client saves it
-- as a download or into <user>/exports
function doc.export_plan()
	buildat.send_packet("fp:export", "")
end

buildat.sub_packet("fp:export_data", function(data)
	local r = cereal.binary_input(data, {"object", {"error", "string"},
			{"name", "string"}, {"file", "string"}})
	if r.error ~= "" then
		doc.notice("Not exported: " .. r.error)
		return
	end
	local path, why = buildat.save_file(r.name .. ".fpplan", r.file)
	if not path then
		doc.notice("Not exported: " .. why)
	elseif path == "" then
		doc.notice("Exported " .. r.name .. ".fpplan (" ..
				math.floor(#r.file / 1024 + 0.5) .. " KiB): see your downloads")
	else
		doc.notice("Exported to " .. path)
	end
end)

buildat.sub_packet("fp:plans", function(data)
	doc.plans = cereal.binary_input(data, PLAN_ROWS)
	if doc.in_plan then
		return
	end
	-- A scripted client's plan, or the one the launcher named, once: opened,
	-- or made when there is none of the name
	if not auto_plan_done then
		auto_plan_done = true
		local want = buildat.get_env("BUILDAT_FP_PLAN")
		if not want and doc.is_local and hello.plan ~= "" then
			want = hello.plan
		end
		if want then
			local exists = false
			for _, p in ipairs(doc.plans) do
				exists = exists or p.name == want
			end
			open_plan(want, not exists)
			return
		end
	end
	show_plans()
end)

buildat.sub_packet("fp:open_result", function(data)
	local err = cereal.binary_input(data, TEXT).text
	if err == "" then
		return
	end
	log:info("Plan refused: " .. err)
	if importing then
		import_as(importing[1], importing[2], err)
	elseif doc.in_plan then
		doc.notice(err)
	else
		show_plans(err)
	end
end)

buildat.sub_packet("fp:entered", function(data)
	importing = nil
	doc.plan_name = cereal.binary_input(data, TEXT).text
	doc.in_plan = true
	buildat.storage_write("plan", doc.plan_name)
	log:info("Entered the plan " .. doc.plan_name)
end)

buildat.sub_packet("fp:hello", function(data)
	hello = cereal.binary_input(data, {"object", {"local", "byte"},
			{"setup", "byte"}, {"open_registration", "byte"}, {"plan", "string"}})
	doc.is_local = hello["local"] == 1
	-- Said again when the admin changes who may register: a user who has
	-- joined already has nothing to do with it
	if doc.logged_in then
		return
	end
	-- A scripted or second client can skip the dialog
	local auto_name = buildat.get_env("BUILDAT_FP_NAME")
	if auto_name then
		send_login(auto_name, buildat.get_env("BUILDAT_FP_PASSWORD") or "",
				buildat.get_env("BUILDAT_FP_CODE") or "")
	else
		show_login(nil, hello["local"] == 1)
	end
end)

-- Out of the plan ([FP_OTHER_PLAN], [FP_PLANS] 4): nothing of it is kept,
-- the editor waits under the plans page, which fp:plans brings
buildat.sub_packet("fp:closed", function(data)
	local why = cereal.binary_input(data, TEXT).text
	doc.in_plan = false
	doc.joined_once = false
	doc.ents, doc.voxels, doc.voxel_version = {}, {}, {}
	doc.others, doc.privs = {}, {}
	doc.undo_stack, doc.redo_stack = {}, {}
	doc.suspend_editor()
	if why ~= "" then
		doc.notice(why)
	end
end)

-- Back to the plans
function doc.close_plan()
	buildat.send_packet("fp:leave_plan", "")
end

-- The open plan copied as `name`, which is then the one open and the
-- copier's ([FP_COPY]); the server refuses a name a plan has already
function doc.copy_plan(name)
	buildat.send_packet("fp:copy_plan", cereal.binary_output({text = name},
			TEXT))
end

-- The name a copy is offered: the plan's own and _n, the lowest n no plan
-- has
function doc.copy_name()
	local taken = {}
	for _, p in ipairs(doc.plans or {}) do
		taken[p.name] = true
	end
	local base = doc.plan_name ~= "" and doc.plan_name or "plan"
	local n = 1
	while taken[base .. "_" .. n] do
		n = n + 1
	end
	return base .. "_" .. n
end

buildat.sub_packet("fp:login_result", function(data)
	local err = cereal.binary_input(data, TEXT).text
	if err ~= "" then
		log:info("Login refused: " .. err)
		-- Joined already, a second try's refusal is only said
		if doc.logged_in then
			doc.notice(err)
		else
			show_login(err, hello["local"] == 1)
		end
		return
	end
	-- Into the server: the plans come next
	doc.logged_in = true
	if login_window then
		login_window:Remove()
		login_window = nil
	end
end)

-- The editor is loaded once joined: it needs the document to show anything
local editor = nil
function doc.suspend_editor()
	if editor then
		editor.suspend()
	end
end
function doc.joined()
	doc.joined_once = true
	if login_window then
		login_window:Remove()
		login_window = nil
	end
	magic.ui:SetFocusElement(nil)
	if editor then
		editor.resume()
		return
	end
	local ok, err, m = buildat.run_script_file("main/editor.lua")
	if not ok or type(m) ~= "table" then
		error("floorplanner: could not load editor.lua: " .. tostring(err))
	end
	editor = m
	editor.start(doc)
end

-- The first dialog waits for fp:hello: the plans to pick, or the join

-- Whether a field had the focus last frame: Urho's UI takes a LineEdit's
-- focus on Esc before KeyDown gets here, so Esc in a field would otherwise
-- reach the editor as a bare Esc and open the pause menu
local was_typing = false
-- The chat opens on the frame after T: the key's own text comes after its
-- KeyDown and went into the new field, which then began with a "t"
local chat_pending = false

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if chat_input then
		if key == magic.KEY_ESCAPE then
			close_chat()
		end
		return
	end
	if doc.typing() or (key == magic.KEY_ESCAPE and was_typing) then
		was_typing = false
		if editor and editor.nudge(key, event_data:GetInt("Qualifiers") % 2 == 1) then
			return
		end
		-- Esc in a field drops what was typed: the panel comes back with
		-- what it had. In the join dialog, before there is an editor, it
		-- is the dialog's cancel, which is leaving.
		if key == magic.KEY_ESCAPE then
			magic.ui:SetFocusElement(nil)
			if editor then
				editor.refresh_panels()
			else
				buildat.leave()
			end
		end
		return
	end
	if key == magic.KEY_T and editor then
		chat_pending = true
	elseif key == magic.KEY_ESCAPE and not editor then
		buildat.leave()
	elseif editor then
		editor.key_down(key, event_data)
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	if chat_pending then
		chat_pending = false
		open_chat("")
	end
	was_typing = doc.typing()
	redraw_messages()
	poll_picked()
	if editor then
		editor.update(event_data:GetFloat("TimeStep"))
	end
end)

-- vim: set noet ts=4 sw=4:
