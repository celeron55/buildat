-- Buildat: extension/urho3d
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/urho3d")
local dump = buildat.dump
local magic_sandbox = require("buildat/extension/magic_sandbox")
local safe_globals = dofile(buildat.extension_path("urho3d").."/safe_globals.lua")
local safe_events = dofile(buildat.extension_path("urho3d").."/safe_events.lua")
-- command_seq:<name> is any name a command sequence's `event` line gives,
-- with the rest of the line as Param ([CMD_EVENT]); the prefix is the
-- whitelist entry
local COMMAND_SEQ_EVENT = {Param = {variant = "String", safe = "string"}}
local function safe_event_def(name)
	if safe_events[name] then
		return safe_events[name]
	end
	if type(name) == "string" and name:sub(1, 12) == "command_seq:" then
		return COMMAND_SEQ_EVENT
	end
	return nil
end
local safe_classes = dofile(buildat.extension_path("urho3d").."/safe_classes.lua")

local Safe = {}
local Unsafe = {}

--
-- Safe interface
--

local function wc(name, def)
	Safe[name] = magic_sandbox.wrap_class(name, def)
end

local function wrap_instance(name, instance)
	if instance == nil then
		return nil
	end
	local class = Safe[name]
	local class_meta = getmetatable(class)
	if not class_meta then error(dump(name).." is not a whitelisted class") end
	return class_meta.wrap(instance)
end

local function type_allows_nil(valid_types)
	if valid_types == '__nil' then
		return true
	end
	if type(valid_types) == 'table' then
		local meta = getmetatable(valid_types)
		if meta and meta.type_name then
			return false
		end
		for _, t in ipairs(valid_types) do
			if t == '__nil' then
				return true
			end
		end
	end
	return false
end

-- (return_types, param_types, f) or (param_types, f)
local function wrap_function(return_types, param_types, f)
	if type(param_types) == 'function' and f == nil then
		f = param_types
		param_types = return_types
		return_types = {"__safe"}
	end
	return function(...)
		local arg = {...}
		local checked_arg = {}
		for i = 1, #param_types do
			if arg[i] == nil and not type_allows_nil(param_types[i]) then
				error("wrapped call argument "..i.." is nil")
			end
			checked_arg[i] = magic_sandbox.safe_to_unsafe(arg[i], param_types[i])
		end
		local wrapped_ret = {}
		local ret = {f(unpack(checked_arg, 1, table.maxn(checked_arg)))}
		for i = 1, #return_types do
			wrapped_ret[i] = magic_sandbox.unsafe_to_safe(ret[i], return_types[i])
		end
		return unpack(wrapped_ret, 1, #return_types)
	end
end

local function self_function(function_name, return_types, param_types)
	return function(...)
		if #param_types < 1 then
			error("At least one argument required (self)")
		end
		local arg = {...}
		local checked_arg = {}
		for i = 1, #param_types do
			if arg[i] == nil and not type_allows_nil(param_types[i]) then
				error(function_name.." argument "..i.." is nil")
			end
			checked_arg[i] = magic_sandbox.safe_to_unsafe(arg[i], param_types[i])
		end
		local wrapped_ret = {}
		local self = checked_arg[1]
		local f = self[function_name]
		if type(f) ~= 'function' then
			error(dump(function_name).." not found in instance")
		end
		local ret = {f(unpack(checked_arg, 1, table.maxn(checked_arg)))}
		for i = 1, #return_types do
			wrapped_ret[i] = magic_sandbox.unsafe_to_safe(ret[i], return_types[i])
		end
		return unpack(wrapped_ret, 1, #return_types)
	end
end

local function simple_property(valid_types)
	return {
		get = function(current_value)
			return magic_sandbox.unsafe_to_safe(current_value, valid_types)
		end,
		set = function(new_value)
			return magic_sandbox.safe_to_unsafe(new_value, valid_types)
		end,
	}
end

-- A property that can be read and not written: the sandbox's __newindex
-- says so by name. What wants it is a property whose setter has a rule
-- attached -- Input.mouseVisible's, which logs why the cursor changed
-- and stands down in a scripted run.
local function read_only_property(valid_types)
	return {
		get = function(current_value)
			return magic_sandbox.unsafe_to_safe(current_value, valid_types)
		end,
	}
end

for _, name in ipairs(safe_globals) do
	local v = _G[name]
	if v == nil then
		-- Dropped or renamed in later Urho; skip so the sandbox still loads.
		log:info("safe global missing: "..name)
	elseif type(v) ~= 'number' and type(v) ~= 'string' then
		error("Invalid safe global "..dump(name).." type: "..dump(type(v)))
	else
		Safe[name] = v
	end
end

local mouse = { hide_wanted = false }

-- What set_preferred_viewports() was last given, unsafe, for
-- renderer:GetViewport(): a preferred viewport drawn at a render scale, or
-- in the scripted client at its logical size ([SEQ_FIXED_SIZE]), goes onto
-- a texture and the renderer holds no viewports at all -- and every
-- reader of GetViewport(0) (voxel_shading's shader parameters, the sky
-- visibility, the parity modes' render path) got nil and gave up in
-- silence: the reference sets since 2026-09-20 had no bounce, ground or
-- lamp term (found on the interior fit). The wrapper answers with the
-- game's own when the renderer has none.
local preferred = {}

safe_classes.define(Safe, {
	wc = wc,
	preferred_viewport = function(index) return preferred[index + 1] end,
	wrap_instance = wrap_instance,
	wrap_function = wrap_function,
	self_function = self_function,
	simple_property = simple_property,
	read_only_property = read_only_property,
	check_safe_resource_name = Unsafe.check_safe_resource_name,
	mouse = mouse,
	--resave_file = Unsafe.resave_file,
})

setmetatable(Safe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		error("extension/urho3d: Class "..dump(k).." is not whitelisted")
	end,
})

-- SubscribeToEvent
--
-- 1.7 LuaScriptEventInvoker stores one handler per event type (last subscribe
-- wins). 2014 kept a vector of functions. Multiplex global events so voxelworld
-- and games can both receive Update.

local urho_SubscribeToEvent = SubscribeToEvent
-- Dropped so Lua cannot replace the mux. Object-specific subs still use
-- urho_SubscribeToEvent (one handler per sender+event, which is correct).
-- UnsubscribeFromEvent("Update") would strip the mux, so drop it too.
SubscribeToEvent = nil
UnsubscribeFromEvent = nil

local sandbox_callback_to_global_function_name = {}
local next_sandbox_global_function_i = 1
local global_event_mux = {} -- event_type -> { {name=, fn=, sandbox=}, ... }
-- Set around add_global_event_handler() by a subscription made from the
-- sandbox; see caller_in_sandbox()
local from_sandbox = false
-- **Which extension subscribed**, taken from its chunk name, so that
-- leaving a game can drop the game's handlers without dropping the
-- launcher's -- which are sandboxed too now ([LAUNCH_SANDBOX]), and
-- were going with them: after a return the room drew and answered
-- nothing (2026-09-23).
local from_sandbox_owner = nil
local function sandbox_owner()
	for level = 2, 6 do
		local info = debug.getinfo(level, "S")
		if not info then break end
		local name = (info.source or ""):match("^@?([%w_]+)/[%w_%-%.]+$")
		if name then return name end
	end
	return nil
end
local global_event_mux_installed = {}

local function add_global_event_handler(event_type, cb_name, fn)
	if not global_event_mux_installed[event_type] then
		global_event_mux[event_type] = {}
		-- A global's name, so only letters and digits: an event named
		-- with a colon (command_seq:scan, [CMD_EVENT]) is a function
		-- Urho3D cannot look up otherwise
		local mux_name = "__buildat_mux_"..event_type:gsub("[^%w_]", "_")
		_G[mux_name] = function(event_type_thing, unsafe_event_data)
			-- A copy, because a handler is allowed to unsubscribe from
			-- inside the event -- leaving a session on Escape does -- and
			-- that would shorten the list being walked. One that has been
			-- unsubscribed by an earlier handler is not called: it may have
			-- been holding what it was about to touch.
			local live = global_event_mux[event_type]
			local list = {}
			for i, entry in ipairs(live) do
				list[i] = entry
			end
			for i = 1, #list do
				local entry = list[i]
				local still_there = false
				for _, e in ipairs(live) do
					if e == entry then
						still_there = true
						break
					end
				end
				if still_there then
					entry.fn(event_type_thing, unsafe_event_data)
				end
			end
		end
		urho_SubscribeToEvent(event_type, mux_name)
		global_event_mux_installed[event_type] = true
	end
	table.insert(global_event_mux[event_type], {name = cb_name, fn = fn,
			sandbox = from_sandbox, owner = from_sandbox_owner})
end

-- Every global handler a sandboxed script subscribed, dropped; the
-- object-specific ones go with their objects
-- `keep` is an extension whose handlers are not a game's -- the launch
-- UI's, which has to still be there when the game is gone
local function drop_sandbox_handlers(keep)
	local n = 0
	for event_type, list in pairs(global_event_mux) do
		for i = #list, 1, -1 do
			if list[i].sandbox and
					not (keep and list[i].owner == keep) then
				table.remove(list, i)
				n = n + 1
			end
		end
	end
	log:info("drop_sandbox_handlers(): "..n.." handlers dropped")
	return n
end

local function remove_global_event_handler(event_type, cb_name)
	local list = global_event_mux[event_type]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i].name == cb_name then
			table.remove(list, i)
		end
	end
end

function Safe.SubscribeToEvent(x, y, z)
	log:debug("Safe.SubscribeToEvent("..dump(x)..", "..dump(y)..", "..dump(z)..")")
	-- Whether the subscriber is sandboxed game code: its environment's
	-- buildat says so ([MENU_CONTEXT] drops those handlers on leaving)
	local caller_env = getfenv(2)
	local subscriber_in_sandbox = type(caller_env) == "table" and
			type(caller_env.buildat) == "table" and
			caller_env.buildat.is_in_sandbox == true
	local object = x
	local sub_event_type = y
	local callback = z
	if z == nil then
		object = nil
		sub_event_type = x
		callback = y
	end
	if object then
		if not getmetatable(object) or not getmetatable(object).unsafe then
			error("SubscribeToEvent(): Object must be sandboxed")
		end
	end
	if not safe_event_def(sub_event_type) then
		error("Event type is not whitelisted: "..dump(sub_event_type))
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current sandbox environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_sandbox_global_function_i
	next_sandbox_global_function_i = next_sandbox_global_function_i + 1
	local global_callback_name = "__buildat_sandbox_callback_"..global_function_i
	sandbox_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(event_type_thing, unsafe_event_data)
		local error = error
		local f = function()
			-- How the hell does one get a string out of event_type_thing?
			-- It is not a Variant, and none of the Lua examples try to do anything
			-- with it.
			-- Let's just assume it's the correct one...
			local got_event_type = sub_event_type
			-- Filter event_data (Urho3D::VariantMap)
			local safe_fields = safe_event_def(got_event_type)
			if not safe_fields then
				log:warning("Received unsafe event: "..dump(got_event_type))
				return
			end
			-- 1.7 VariantMap is indexed: eventData["Key"] returns a Variant.
			local safe_event_data = Safe.VariantMap()
			for field_name, field_def in pairs(safe_fields) do
				local variant_type = field_def.variant
				local safe_type = field_def.safe
				local variant = unsafe_event_data[field_name]
				if variant == nil then
					error("Value for field "..dump(field_name).." in "..
							dump(got_event_type).." is nil")
				end
				-- 1.7 VariantMap __index returns an empty Variant for missing
				-- keys, not nil. Treat empty as missing.
				if variant.IsEmpty and variant:IsEmpty() then
					error("Value for field "..dump(field_name).." in "..
							dump(got_event_type).." is empty")
				end
				local safe_value = nil
				if variant_type == "Ptr" then
					local get_type = field_def.get_type or safe_type
					local unsafe_value = variant:GetPtr(get_type)
					if unsafe_value == nil then
						error("Value for field "..dump(field_name).." as "..
								dump(safe_type).." in "..dump(got_event_type)..
								" gotten as "..dump(get_type).." is nil")
					end
					safe_value = wrap_instance(safe_type, unsafe_value)
					safe_event_data:SetPtr(field_name, safe_value)
				else
					local get_type = field_def.get_type or variant_type
					local getter = variant["Get"..get_type]
					if type(getter) ~= "function" then
						error("Variant has no Get"..get_type.." for field "..
								dump(field_name).." in "..dump(got_event_type))
					end
					local unsafe_value = getter(variant)
					if safe_type == 'number' or safe_type == 'string' or
							safe_type == 'boolean' then
						safe_value = magic_sandbox.unsafe_to_safe(unsafe_value, safe_type)
					else
						safe_value = wrap_instance(safe_type, unsafe_value)
					end
					local setter = safe_event_data["Set"..get_type]
					if type(setter) ~= "function" then
						error("Safe.VariantMap has no Set"..get_type)
					end
					setter(safe_event_data, field_name, safe_value)
				end
			end
			-- Call callback
			if object then
				callback(object, got_event_type, safe_event_data)
			else
				callback(got_event_type, safe_event_data)
			end
		end
		__buildat_run_function_in_sandbox(f)
	end
	if object then
		local unsafe_object = getmetatable(object).unsafe
		urho_SubscribeToEvent(unsafe_object, sub_event_type, global_callback_name)
	else
		from_sandbox = subscriber_in_sandbox
		from_sandbox_owner = subscriber_in_sandbox and sandbox_owner() or nil
		add_global_event_handler(sub_event_type, global_callback_name,
				_G[global_callback_name])
		from_sandbox, from_sandbox_owner = false, nil
	end
	log:debug("-> global_callback_name="..dump(global_callback_name))
	return global_callback_name
end

-- **What is subscribed by name unsubscribes by the same name.**
-- SubscribeToEvent stores the handler under a generated global name and
-- hands that name back, so an unsubscribe given what Urho3D's own API
-- takes -- a function, or the name of one in the caller's environment --
-- matched nothing and the handler went on firing over a screen it had
-- already removed (2026-09-24: the console's Escape handler, after the
-- console was closed).
function Safe.UnsubscribeFromEvent(sub_event_type, cb_name)
	log:debug("Safe.UnsubscribeFromEvent("..dump(sub_event_type)..", "..dump(cb_name)..")")
	local cb = cb_name
	if type(cb) == "string" then
		local caller_environment = getfenv(2)
		cb = type(caller_environment) == "table" and
				caller_environment[cb_name] or nil
	end
	if type(cb) == "function" then
		cb_name = sandbox_callback_to_global_function_name[cb] or cb_name
	end
	remove_global_event_handler(sub_event_type, cb_name)
end

-- A scene drawn into a texture instead of into the window, for a thumbnail:
-- see l_render_scene_to_texture() in src/lua_bindings/misc_urho3d.cpp for what
-- the texture does and does not do.
Safe.render_scene_to_texture = wrap_function({"Scene", "Node", "number",
		"number"}, function(scene, camera_node, w, h)
	return wrap_instance("Texture2D", __buildat_render_scene_to_texture(
			scene, camera_node, w, h))
end)

-- **A whole image in one call** ([ROOM_BOOT]): the bytes are w * h *
-- components of them, row by row from the top left, and for four
-- components that is R, G, B, A. A generated tile written a pixel at a
-- time is four thousand crossings of the sandbox; this is one.
Safe.image_set_data = wrap_function({"Image", "number", "number", "number",
		"string"}, function(image, w, h, components, data)
	-- wrap_function has already unwrapped the Image
	__buildat_image_set_data(image, w, h, components, data)
end)

-- The viewports the user's graphics preferences are applied to, as against
-- the raw renderer:SetViewport() ones which are drawn the way the game says
-- and nothing else. Use this instead of renderer:SetViewport(): the engine
-- draws the scene at the render_scale the user asked for, under a UI that
-- stays at native resolution, and the viewport stays the game's own -- what
-- it does to renderPath afterwards still works.
--
--     magic.set_preferred_viewports({viewport})            -- one view
--     magic.set_preferred_viewports({vp_top, vp_bottom})   -- two
--     magic.set_preferred_viewports({})                    -- teardown
--
-- A game that does not call this is drawn at native resolution and keeps
-- working; the preference is a preference.
function Safe.set_preferred_viewports(viewports)
	if type(viewports) ~= 'table' then
		error("set_preferred_viewports(): expected a table of Viewports")
	end
	local unsafe = {}
	for i = 1, #viewports do
		unsafe[i] = magic_sandbox.safe_to_unsafe(viewports[i], "Viewport")
	end
	preferred = unsafe
	__buildat_set_preferred_viewports(unsafe)
end

-- **Who has the screen** ([LAUNCH_WORLD], 2026-09-24: the room stands
-- down too early). A launcher that keeps drawing while a game loads has
-- to know when the game actually takes the view, and taking the view is
-- set_preferred_viewports. **The count is the client's**, not this
-- file's: each sandbox gets its own copy of this extension, so a game
-- bumping a count here is not something the launcher's copy can see.
function Safe.viewport_generation()
	return __buildat_viewport_generation()
end

-- **A field of view of the screen's short side** (user, 2026-09-30): a
-- camera's fov is vertical, which on a portrait screen is a slot. deg is
-- then the narrower of the width and the height, and what comes back is the
-- vertical fov that gives it.
function Safe.fov_for(deg)
	local w, h = Safe.graphics.width, Safe.graphics.height
	if h <= w or w <= 0 then
		return deg
	end
	return math.deg(2 * math.atan(math.tan(math.rad(deg) / 2) * h / w))
end

-- The camera kept at fov_for(deg), a turned phone and a resized window
-- included; for a game whose fov does not change otherwise
function Safe.keep_fov(camera, deg)
	camera.fov = Safe.fov_for(deg)
	local w, h = Safe.graphics.width, Safe.graphics.height
	Safe.SubscribeToEvent("Update", function()
		local g = Safe.graphics
		if g.width ~= w or g.height ~= h then
			w, h = g.width, g.height
			-- A camera the game has removed since is left alone
			pcall(function() camera.fov = Safe.fov_for(deg) end)
		end
	end)
end

--
-- Unsafe interface
--

-- Just wrap everything to the global environment as we don't have a full list
-- of Urho3D's API available.

setmetatable(Unsafe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		return _G[k]
	end,
})

-- Unsafe SubscribeToEvent with function support

local unsafe_callback_to_global_function_name = {}
local next_unsafe_global_function_i = 1

function Unsafe.SubscribeToEvent(x, y, z)
	local object = x
	local event_name = y
	local callback = z
	if callback == nil then
		object = nil
		event_name = x
		callback = y
	end
	if type(callback) == 'string' then
		-- Allow supplying callback function name like Urho3D does by default
		local caller_environment = getfenv(2)
		callback = caller_environment[callback]
		if type(callback) ~= 'function' then
			error("SubscribeToEvent(): '"..callback..
					"' is not a global function in current unsafe environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_unsafe_global_function_i
	next_unsafe_global_function_i = next_unsafe_global_function_i + 1
	local global_callback_name = "__buildat_unsafe_callback_"..global_function_i
	unsafe_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(event_type, event_data)
		local f = function()
			if object then
				callback(object, event_type, event_data)
			else
				callback(event_type, event_data)
			end
		end
		local ok, err = __buildat_pcall(f)
		if not ok then
			__buildat_fatal_error("Error calling callback: "..err)
		end
	end
	if object then
		urho_SubscribeToEvent(object, event_name, global_callback_name)
	else
		add_global_event_handler(event_name, global_callback_name,
				_G[global_callback_name])
	end
	return global_callback_name
end

-- The mouse's capture, three ways ([FOCUS_LOG] 4). The game says what it
-- wants through SetMouseVisible (hide_wanted); these keep it so across
-- the window manager:
-- * Alt down frees the cursor (ungrab, visible) so alt+tab reaches the
--   WM -- a captured window has the keyboard grabbed too, and without
--   this alt+tab never leaves the game (the playtest of 19:40);
-- * focus lost frees it, focus regained hides and captures it again;
-- * a click while it is free -- a stray Alt, no switch -- captures it.
-- What made the mouse stay free for good was none of these: the game's
-- own mouse key is Tab, and alt+tab handed the Tab to the client first.
Safe.SubscribeToEvent("KeyDown", function(_, event_data)
	if not mouse.hide_wanted then
		return
	end
	local key = event_data:GetInt("Key")
	if key == KEY_ALT or key == KEY_LALT or key == KEY_RALT then
		input:SetMouseChangeReason("alt down")
		input:SetMouseMode(MM_FREE)
		input:SetMouseVisible(true)
	end
end)
Safe.SubscribeToEvent("MouseButtonDown", function()
	if not mouse.hide_wanted then
		return
	end
	if input:GetMouseMode() == MM_FREE then
		input:SetMouseChangeReason("a click while free")
		input:SetMouseMode(MM_ABSOLUTE)
		input:SetMouseVisible(false)
	end
end)
Safe.SubscribeToEvent("InputFocus", function(_, event_data)
	if not mouse.hide_wanted then
		return
	end
	local focus = event_data:GetBool("Focus")
	input:SetMouseChangeReason(focus and "focus regained" or "focus lost")
	if focus then
		input:SetMouseMode(MM_ABSOLUTE)
		input:SetMouseVisible(false)
	else
		input:SetMouseMode(MM_FREE)
		input:SetMouseVisible(true)
	end
end)

--
-- A removed UI element is dead to the sandbox ([UI_UAF])
--
-- tolua's userdata outlives the element it points at, so a wrapper held
-- past the element's removal -- a closed form's button -- reads freed
-- memory on its next property. The tree sends ElementRemoved for the
-- element before it detaches, while it and its children are whole, so
-- every wrapper of it or of anything under it is marked dead here and
-- errors from then on. A re-parent is a removal followed by an add in
-- the same C++ call (UIElement::InsertChild) with no Lua between: the
-- add un-marks what the removal marked, and only that.
--
-- simplified: a wrapper's dead-ness is by pointer, and a freed element's
-- address can be reused; the add's un-mark then reaches wrappers of an
-- old element that a new one happens to sit on. No crash from it -- the
-- wrapper then reads the new element -- and the fix is a generation
-- counter on the C++ side.

local removed_wrappers = setmetatable({}, {__mode = "k"})

-- The removed subtree, walked while it is whole; the wrappers are then
-- found by lookup and nothing of theirs is called -- a wrapper
-- whose element went without an event (the tree torn down from C++) is
-- exactly the dangling pointer this is here for, and GetParent() on it
-- was the walk's own use-after-free (a driven run, 2026-09-20 16:08)
local function subtree(element, set)
	set[element] = true
	for i = 0, element:GetNumChildren() - 1 do
		subtree(element:GetChild(i), set)
	end
	return set
end

add_global_event_handler("ElementRemoved", "__buildat_ui_dead",
	function(_, data)
		local removed = data["Element"]:GetPtr("UIElement")
		-- Weak too, and `true` for the same reason as magic_sandbox.live
		local set = setmetatable({}, {__mode = "k"})
		for element in pairs(subtree(removed, {})) do
			local wrappers = magic_sandbox.live[element]
			if wrappers then
				local why = "UIElement " .. dump(element:GetName()) ..
						" was removed"
				for safe in pairs(wrappers) do
					local meta = getmetatable(safe)
					if not meta.dead then
						meta.dead = why
						set[safe] = true
					end
				end
			end
		end
		removed_wrappers[removed] = set
	end)

add_global_event_handler("ElementAdded", "__buildat_ui_dead",
	function(_, data)
		local added = data["Element"]:GetPtr("UIElement")
		local set = removed_wrappers[added]
		if not set then return end
		removed_wrappers[added] = nil
		for safe in pairs(set) do
			getmetatable(safe).dead = nil
		end
	end)

do
	local holder = Safe.ui.root:CreateChild("UIElement")
	local child = holder:CreateChild("UIElement", "uaf_child")
	local moved = holder:CreateChild("UIElement", "uaf_moved")
	-- The re-parent on the unsafe side: AddChild is not whitelisted
	ui.root:AddChild(getmetatable(moved).unsafe)
	assert(moved:GetName() == "uaf_moved", "a re-parented element read as dead")
	holder:Remove()
	local ok, err = pcall(function() return child:GetName() end)
	assert(not ok and tostring(err):find("uaf_child"),
			"a removed element's child did not error: " .. tostring(err))
	moved:Remove()
	assert(not pcall(function() return moved:GetName() end),
			"a removed element did not error")
end

--
-- What the whitelist actually lets through
--
-- A property missing from safe_classes.lua makes a feature **silently do
-- nothing** -- no error, no warning -- which is the whole cost of a
-- whitelist sweep and the reason one is done in batches. So the classes a
-- sweep adds get a round trip here, once, at load: made through
-- CreateChild the way a game makes them, written to and read back. An
-- element that never arrived in the whitelist errors on CreateChild, and a
-- property that did not arrive comes back wrong.
--
-- util/whitelist_sweep.py is the other half: it says which of Urho3D's
-- classes are still neither wrapped nor refused.

do
	local holder = Safe.ui.root:CreateChild("UIElement")

	local view = holder:CreateChild("ScrollView")
	view.scrollStep = 0.25
	assert(math.abs(view.scrollStep - 0.25) < 1e-6,
			"whitelist: ScrollView.scrollStep did not stick")
	local content = holder:CreateChild("UIElement")
	view.contentElement = content
	assert(view.contentElement ~= nil,
			"whitelist: ScrollView.contentElement did not stick")

	local bar = holder:CreateChild("ScrollBar")
	bar.orientation = O_VERTICAL
	bar.range = 10
	bar.value = 4
	assert(bar.orientation == O_VERTICAL and math.abs(bar.value - 4) < 1e-6,
			"whitelist: ScrollBar did not take its orientation and value")
	bar:ChangeValue(1)
	assert(math.abs(bar.value - 5) < 1e-6,
			"whitelist: ScrollBar:ChangeValue() did nothing")

	local slider = holder:CreateChild("Slider")
	slider.range = 100
	slider.value = 20
	assert(math.abs(slider.value - 20) < 1e-6,
			"whitelist: Slider.value did not stick")

	local progress = holder:CreateChild("ProgressBar")
	progress.range = 1
	progress.value = 0.5
	progress.showPercentText = false
	assert(math.abs(progress.value - 0.5) < 1e-6 and
			progress.showPercentText == false,
			"whitelist: ProgressBar did not take its value")

	local list = holder:CreateChild("ListView")
	assert(list.numItems == 0, "whitelist: a new ListView is not empty")
	list:AddItem(holder:CreateChild("Text"))
	list:AddItem(holder:CreateChild("Text"))
	assert(list.numItems == 2,
			"whitelist: ListView:AddItem() did not add")
	list.selection = 1
	assert(list.selection == 1 and list:IsSelected(1),
			"whitelist: ListView.selection did not stick")
	assert(list:GetItem(0) ~= nil,
			"whitelist: ListView:GetItem() answered nothing")
	list:RemoveItem(0)
	assert(list.numItems == 1,
			"whitelist: ListView:RemoveItem() did not remove")

	local menu = holder:CreateChild("Menu")
	local popup = holder:CreateChild("Window")
	menu.popup = popup
	menu.popupOffset = Safe.IntVector2(0, 20)
	assert(menu.popup ~= nil and menu.popupOffset.y == 20,
			"whitelist: Menu did not take its popup and offset")

	local drop = holder:CreateChild("DropDownList")
	drop.placeholderText = "pick one"
	drop:AddItem(holder:CreateChild("Text"))
	drop:AddItem(holder:CreateChild("Text"))
	assert(drop.numItems == 2 and drop.placeholderText == "pick one",
			"whitelist: DropDownList did not take its items")
	assert(drop.listView ~= nil,
			"whitelist: DropDownList has no list view of its own")

	local tip = holder:CreateChild("ToolTip")
	tip.delay = 0.5
	assert(math.abs(tip.delay - 0.5) < 1e-6,
			"whitelist: ToolTip.delay did not stick")

	local cursor = holder:CreateChild("Cursor")
	cursor.useSystemShapes = false
	assert(cursor.useSystemShapes == false,
			"whitelist: Cursor.useSystemShapes did not stick")

	-- Text3D is a Drawable rather than a UI element, so it wants a node of
	-- its own; the scene is thrown away with it
	local scene = Safe.Scene:new()
	-- With no Octree a drawable says so, once per frame, into everybody
	-- else's log: this scene exists for two property writes and is thrown
	-- away, but it is still a scene
	scene:CreateComponent("Octree")
	local node = scene:CreateChild("whitelist_check")
	local label = node:CreateComponent("Text3D")
	-- **The font first.** Text::SetFontSize() begins "Initial font must be
	-- set" and returns false without one, so a size set before a font is
	-- silently the default -- which is the exact shape of failure this whole
	-- sweep exists to catch, and it was caught here.
	label:SetFont(Safe.cache:GetResource("Font",
			"Fonts/OverpassMono-Regular.ttf"), 24)
	label.text = "over there"
	label.wordwrap = false
	label.fixedScreenSize = true
	assert(label.text == "over there" and label.fontSize == 24 and
			label.fixedScreenSize == true,
			"whitelist: Text3D did not take its font, text and size")
	node:Remove()

	-- Pixels, and the six faces a sky is drawn on. An image made here rather
	-- than read from anywhere: what the cache hands over is the same class.
	local img = Safe.Image:new()
	assert(img:SetSize(4, 4, 4), "whitelist: Image:SetSize() refused")
	assert(img.width == 4 and img.components == 4,
			"whitelist: Image did not take its size")
	img:SetPixel(1, 1, Safe.Color(1, 0, 0, 1))
	local px = img:GetPixel(1, 1)
	assert(px.r > 0.99 and px.g < 0.01,
			"whitelist: a pixel written is not the pixel read")
	assert(img:Resize(2, 2) and img.width == 2,
			"whitelist: Image:Resize() did nothing")

	-- SetData sizes the cube from face 0, so this is the whole of it: one
	-- square image on every face
	local cube = Safe.TextureCube:new()
	local face = Safe.Image:new()
	face:SetSize(4, 4, 4)
	face:Clear(Safe.Color(0, 0, 1, 1))
	for i = 0, 5 do
		assert(cube:SetData(i, face),
				"whitelist: TextureCube:SetData() refused face " .. i)
	end

	-- Arithmetic, which is the whole of the Math batch, so it is checked by
	-- doing some rather than by writing a number and reading it back.
	local iv = Safe.IntVector3(1, 2, 3) + Safe.IntVector3(4, 5, 6)
	assert(iv.x == 5 and iv.y == 7 and iv.z == 9,
			"whitelist: IntVector3 does not add")
	assert(math.abs(Safe.Vector4(1, 2, 3, 4):DotProduct(
			Safe.Vector4(1, 0, 0, 0)) - 1) < 1e-6,
			"whitelist: Vector4 does not dot")
	-- Five out along -Z, pointing back at a box two across around the
	-- origin: the near face is four away
	local ray = Safe.Ray(Safe.Vector3(0, 0, -5), Safe.Vector3(0, 0, 1))
	assert(math.abs(ray:HitDistanceBox(Safe.BoundingBox(-1, 1)) - 4) < 1e-3,
			"whitelist: a ray does not hit a box where it should")
	-- And a sphere of radius two: a point five out is three from its surface
	assert(math.abs(Safe.Sphere(Safe.Vector3(0, 0, 0), 2):Distance(
			Safe.Vector3(0, 0, 5)) - 3) < 1e-3,
			"whitelist: a sphere does not measure to a point")

	holder:Remove()

	-- Said out loud, because the failure that cost the most here was a check
	-- that could not be told from one that never ran: an error anywhere in
	-- this block takes the whole extension down with it, and then nothing
	-- logs anything at all. A run without this line is a run where the
	-- sandbox did not load.
	log:info("whitelist: the wrapped classes round-tripped")
end

--
-- Create the final interface
--

local M = {}
M.drop_sandbox_handlers = drop_sandbox_handlers
M.safe = Safe
M.unsafe = Unsafe

return M
-- vim: set noet ts=4 sw=4:
