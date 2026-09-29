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

local STYLE = magic.cache:GetResource("XMLFile", "__menu/res/main_style.xml")
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
local LOGIN = {"object", {"name", "string"}, {"password", "string"}}
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
-- kind: nil for an edit, "undo" or "redo" for what undoes one
function doc.send(ops, done, kind)
	local seq = doc.next_seq
	doc.next_seq = seq + 1
	local wire = {}
	for i, op in ipairs(ops) do
		local e = op.ent
		wire[i] = {op = OP_CODES[op.op], ent = {id = e.id, type = e.type or "",
				ints = e.ints or {}, strs = e.strs or {}, lists = e.lists or {}}}
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

local function send_login(name, password)
	buildat.send_packet("fp:login", cereal.binary_output(
			{name = name, password = password}, LOGIN))
end

local function show_login(error_text)
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
	local name = field("", false)
	label("Password (a new name makes an account)")
	local password = field("", true)
	-- simplified: the connection is not encrypted yet ([TRANSPORT])
	local warn = label("The password is sent unencrypted: use a trusted network")
	warn:SetColor(magic.Color(1.0, 0.8, 0.4))
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
		send_login(name:GetText(), password:GetText())
	end
	magic.SubscribeToEvent(button, "Released", function() join() end)
	magic.SubscribeToEvent(name, "TextFinished", function()
		password:SetFocus(true)
	end)
	magic.SubscribeToEvent(password, "TextFinished", function() join() end)
	name:SetFocus(true)
end

buildat.sub_packet("fp:login_result", function(data)
	local err = cereal.binary_input(data, TEXT).text
	if err ~= "" then
		log:info("Login refused: " .. err)
		show_login(err)
	end
end)

-- The editor is loaded once joined: it needs the document to show anything
local editor = nil
function doc.joined()
	if login_window then
		login_window:Remove()
		login_window = nil
	end
	magic.ui:SetFocusElement(nil)
	if editor then
		return
	end
	local ok, err, m = buildat.run_script_file("main/editor.lua")
	if not ok or type(m) ~= "table" then
		error("floorplanner: could not load editor.lua: " .. tostring(err))
	end
	editor = m
	editor.start(doc)
end

-- A scripted or second client can skip the dialog
local auto_name = buildat.get_env("BUILDAT_FP_NAME")
if auto_name then
	send_login(auto_name, buildat.get_env("BUILDAT_FP_PASSWORD") or "")
else
	show_login(nil)
end

magic.SubscribeToEvent("KeyDown", function(event_type, event_data)
	local key = event_data:GetInt("Key")
	if chat_input then
		if key == magic.KEY_ESCAPE then
			close_chat()
		end
		return
	end
	if doc.typing() then
		return
	end
	if key == magic.KEY_T and editor then
		open_chat("")
	elseif key == magic.KEY_ESCAPE and not editor then
		buildat.leave()
	elseif editor then
		editor.key_down(key, event_data)
	end
end)

magic.SubscribeToEvent("Update", function(event_type, event_data)
	redraw_messages()
	if editor then
		editor.update(event_data:GetFloat("TimeStep"))
	end
end)

-- vim: set noet ts=4 sw=4:
