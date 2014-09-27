-- Buildat: extension/urho3d
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/urho3d")
local dump = buildat.dump
local magic_sandbox = require("buildat/extension/magic_sandbox")
local safe_globals = dofile(buildat.extension_path("urho3d").."/safe_globals.lua")
local safe_events = dofile(buildat.extension_path("urho3d").."/safe_events.lua")
local M = {safe = {}}

--
-- ResourceCache support code
--

-- Checks that this is not an absolute file path or anything funny
local allowed_name_pattern = '^[a-zA-Z0-9][a-zA-Z0-9/._ ]*$'
function M.check_safe_resource_name(name)
	if type(name) ~= "string" then
		error("Unsafe resource name: "..dump(name).." (not string)")
	end
	if string.match(name, '^/.*$') then
		error("Unsafe resource name: "..dump(name).." (absolute path)")
	end
	if not string.match(name, allowed_name_pattern) then
		error("Unsafe resource name: "..dump(name).." (unneeded chars)")
	end
	if string.match(name, '[.][.]') then
		error("Unsafe resource name: "..dump(name).." (contains ..)")
	end
	log:verbose("Safe resource name: "..name)
	return name
end

-- Basic tests
assert(pcall(function()
	M.check_safe_resource_name("/etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name(" /etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("\t /etc/passwd")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("Models/Box.mdl")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name("Fonts/Anonymous Pro.ttf")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name("test1/pink_texture.png")
end) == true)
assert(pcall(function()
	M.check_safe_resource_name(" Box.mdl ")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("../../foo")
end) == false)
assert(pcall(function()
	M.check_safe_resource_name("abc$de")
end) == false)

local hack_resaved_files = {}  -- name -> temporary target file

-- Create temporary file with wanted file name to make Urho3D load it correctly
function M.resave_file(resource_name)
	M.check_safe_resource_name(resource_name)
	local path2 = hack_resaved_files[resource_name]
	if path2 == nil then
		local path = __buildat_get_file_path(resource_name)
		if path == nil then
			return nil
		end
		path2 = __buildat_get_path("tmp").."/"..resource_name
		dir2 = string.match(path2, '^(.*)/.+$')
		if dir2 then
			if not __buildat_mkdir(dir2) then
				error("Failed to create directory: \""..dir2.."\"")
			end
		end
		log:info("Temporary path: "..path2)
		local src = io.open(path, "rb")
		local dst = io.open(path2, "wb")
		while true do
			local buf = src:read(100000)
			if buf == nil then break end
			dst:write(buf)
		end
		src:close()
		dst:close()
		hack_resaved_files[resource_name] = path2
	end
	return path2
end

-- Callback from core
function __buildat_file_updated_in_cache(name, hash, cached_path)
	log:debug("__buildat_file_updated_in_cache(): name="..dump(name)..
			", cached_path="..dump(cached_path))
	if hack_resaved_files[name] then
		log:verbose("__buildat_file_updated_in_cache(): Re-saving: "..dump(name))
		hack_resaved_files[name] = nil -- Force re-copy
		M.resave_file(name)
	end
end

--
-- Safe interface
--

local function wc(name, def)
	M.safe[name] = magic_sandbox.wrap_class(name, def)
end

local function wrap_instance(name, instance)
	local class = M.safe[name]
	local class_meta = getmetatable(class)
	if not class_meta then error(dump(name).." is not a whitelisted class") end
	return class_meta.wrap(instance)
end

-- (return_types, param_types, f) or (param_types, f)
local function wrap_function(return_types, param_types, f)
	if type(param_types) == 'function' and f == nil then
		f = param_types
		param_types = return_types
		return_types = {"__safe"}
	end
	return function(...)
		local checked_arg = {}
		for i = 1, #param_types do
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
		local checked_arg = {}
		for i = 1, #param_types do
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

for _, name in ipairs(safe_globals) do
	local v = _G[name]
	if type(v) ~= 'number' and type(v) ~= 'string' then
		error("Invalid safe global "..dump(name).." type: "..dump(type(v)))
	end
	M.safe[name] = v
end

wc("VariantMap", {
	unsafe_constructor = wrap_function({},
	function(x, y, z)
		return wrap_instance("VariantMap", VariantMap())
	end),
	instance = {
		SetFloat = self_function(
				"SetFloat", {}, {"VariantMap", "string", "number"}),
		GetFloat = self_function(
				"GetFloat", {"number"}, {"VariantMap", "string"}),
	}
})

wc("Vector3", {
	unsafe_constructor = wrap_function({"number", "number", "number"},
	function(x, y, z)
		return wrap_instance("Vector3", Vector3(x, y, z))
	end),
	instance_meta = {
		__mul = wrap_function({"Vector3", "number"}, function(self, n)
			return wrap_instance("Vector3", self * n)
		end),
	},
	properties = {
		x = simple_property("number"),
		y = simple_property("number"),
		z = simple_property("number"),
	},
})

wc("Resource", {
})

wc("Component", {
})

wc("Octree", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Drawable", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Light", {
	inherited_from_by_wrapper = M.safe.Drawable,
	properties = {
		lightType = simple_property("number"),
	},
})

wc("Camera", {
	inherited_from_by_wrapper = M.safe.Component,
})

wc("Model", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Material", {
	inherited_from_by_wrapper = M.safe.Resource,
	class = {
		new = function()
			return wrap_instance("Material", Material:new())
		end,
	},
	instance = {
		--SetTexture = wrap_function({"Material", "number", "Texture"},
		--function(self, index, texture)
		--	log:info("Material:SetTexture("..dump(index)..", "..dump(texture)..")")
		--	self:SetTexture(index, texture)
		--end),
		SetTexture = self_function(
				"SetTexture", {}, {"Material", "number", "Texture"}),
		SetTechnique = self_function(
				"SetTechnique", {}, {"Material", "number", "Technique",
						{"number", "__nil"}, {"number", "__nil"}}),
	},
})

wc("Texture", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Texture2D", {
	inherited_from_by_wrapper = M.safe.Texture,
})

wc("Font", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("StaticModel", {
	inherited_from_by_wrapper = M.safe.Octree,
	properties = {
		model = simple_property(M.safe.Model),
		material = simple_property(M.safe.Material),
	},
})

wc("Technique", {
	inherited_from_by_wrapper = M.safe.Resource,
})

wc("Node", {
	instance = {
		CreateComponent = wrap_function({"Node", "string"}, function(self, name)
			local component = self:CreateComponent(name)
			assert(component)
			return wrap_instance(name, component)
		end),
		GetComponent = wrap_function({"Node", "string"}, function(self, name)
			local component = self:GetComponent(name)
			assert(component)
			return wrap_instance(name, component)
		end),
		LookAt = wrap_function({"Node", "Vector3"}, function(self, p)
			self:LookAt(p)
		end),
		Translate = wrap_function({"Node", "Vector3"}, function(self, v)
			self:Translate(v)
		end),
	},
	properties = {
		scale = simple_property(M.safe.Vector3),
		direction = simple_property(M.safe.Vector3),
		position = simple_property(M.safe.Vector3),
	},
})

wc("Plane", {
})

wc("Scene", {
	inherited_from_by_wrapper = M.safe.Node,
	unsafe_constructor = wrap_function({}, function()
		return wrap_instance("Scene", Scene())
	end),
	instance = {
		CreateChild = wrap_function({"Scene", "string"}, function(self, name)
			return wrap_instance("Node", self:CreateChild(name))
		end)
	},
})

wc("ResourceCache", {
	instance = {
		GetResource = wrap_function({"ResourceCache", "string", "string"},
		function(self, resource_type, resource_name)
			-- TODO: If resource_type=XMLFile, we probably have to go through it and
			--       resave all references to other files found in there
			resource_name = M.check_safe_resource_name(resource_name)
			M.resave_file(resource_name)
			local res = cache:GetResource(resource_type, resource_name)
			return wrap_instance(resource_type, res)
		end),
	},
})

wc("Viewport", {
	class = {
		new = wrap_function({"__to_nil", "Scene", "Camera"},
		function(_, scene, camera_component)
			return wrap_instance("Viewport", Viewport:new(scene, camera_component))
		end),
	},
})

wc("Renderer", {
	instance = {
		SetViewport = wrap_function({"Renderer", "number", "Viewport"},
		function(self, index, viewport)
			self:SetViewport(index, viewport)
		end),
	},
})

wc("Animatable", {
})

wc("UIElement", {
	inherited_from_by_wrapper = M.safe.Animatable,
	instance = {
		CreateChild = wrap_function({"UIElement", "string", {"string", "__nil"}},
		function(self, element_type, name)
			return wrap_instance("UIElement", self:CreateChild(element_type, name))
		end),
		SetText = self_function("SetText", {}, {"UIElement", "string"}),
		SetFont = self_function("SetFont", {}, {"UIElement", "Font"}),
		SetPosition = self_function(
				"SetPosition", {}, {"UIElement", "number", "number"}),
	},
	properties = {
		horizontalAlignment = simple_property("number"),
		verticalAlignment = simple_property("number"),
		height = simple_property("number"),
	},
})

wc("UI", {
	instance = {
	},
	properties = {
		root = simple_property(M.safe.UIElement),
		focusElement = simple_property({M.safe.UIElement, "__nil"}),
	},
})

wc("Input", {
	instance = {
		GetKeyDown = self_function("GetKeyDown", {"boolean"}, {"Input", "number"}),
	},
})

M.safe.cache = wrap_instance("ResourceCache", cache)
M.safe.renderer = wrap_instance("Renderer", renderer)
M.safe.ui = wrap_instance("UI", ui)
M.safe.input = wrap_instance("Input", input)

setmetatable(M.safe, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		error("extension/urho3d: "..dump(k).." not found in safe interface")
	end,
})

-- SubscribeToEvent

local sandbox_callback_to_global_function_name = {}
local next_sandbox_global_function_i = 1

function M.safe.SubscribeToEvent(x, y, z)
	local object = x
	local sub_event_type = y
	local callback = z
	if callback == nil then
		object = nil
		sub_event_type = x
		callback = y
	end
	if not safe_events[sub_event_type] then
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
		-- How the hell does one get a string out of event_type_thing?
		-- It is not a Variant, and none of the Lua examples try to do anything
		-- with it.
		-- Let's just assume it's the correct one...
		local got_event_type = sub_event_type
		-- Filter event_data (Urho3D::VariantMap)
		local safe_fields = safe_events[got_event_type]
		if not safe_fields then
			log:warning("Received unsafe event: "..dump(got_event_type))
		end
		local safe_event_data = M.safe.VariantMap()
		for field_name, field_def in pairs(safe_fields) do
			local variant_type = field_def.variant
			local safe_type = field_def.safe
			local unsafe_value = unsafe_event_data["Get"..variant_type](
					unsafe_event_data, field_name)
			local safe_value = magic_sandbox.unsafe_to_safe(unsafe_value, safe_type)
			safe_event_data["Set"..variant_type](
					safe_event_data, field_name, safe_value)
		end
		-- Call callback
		local f = function()
			if object then
				callback(object, got_event_type, safe_event_data)
			else
				callback(got_event_type, safe_event_data)
			end
		end
		__buildat_run_function_in_sandbox(f)
	end
	if object then
		SubscribeToEvent(object, sub_event_type, global_callback_name)
	else
		SubscribeToEvent(sub_event_type, global_callback_name)
	end
	return global_callback_name
end

--
-- Unsafe interface
--

-- Just wrap everything to the global environment as we don't have a full list
-- of Urho3D's API available.

setmetatable(M, {
	__index = function(t, k)
		local v = rawget(t, k)
		if v ~= nil then return v end
		return _G[k]
	end,
})

-- Add GetResource wrapper to ResourceCache instance

--[[M.cache.GetResource = function(self, resource_type, resource_name)
	local path = M.resave_file(resource_name)
	-- Note: path is unused
	resource_name = M.check_safe_resource_name(resource_name)
	return M.cache:GetResource(resource_type, resource_name)
end]]

-- Unsafe SubscribeToEvent with function support

local unsafe_callback_to_global_function_name = {}
local next_unsafe_global_function_i = 1

function M.SubscribeToEvent(x, y, z)
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
		SubscribeToEvent(object, event_name, global_callback_name)
	else
		SubscribeToEvent(event_name, global_callback_name)
	end
	return global_callback_name
end

return M
-- vim: set noet ts=4 sw=4:
