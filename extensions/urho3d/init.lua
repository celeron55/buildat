-- Buildat: extension/urho3d
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/urho3d")
local dump = buildat.dump
local M = {safe = {}}

--
-- Safe interface
--

-- Set every plain value in global environment to the sandbox
-- ...it's maybe safe enough... TODO: Not safe
for k, v in pairs(_G) do
	if type(v) == 'number' or type(v) == 'string' then
		--log:info("Setting sandbox["..k.."] = "..buildat.dump(v))
		M.safe[k] = _G[k]
	end
end

-- TODO: Require explicit whitelisting of classes, method/function argument and
--       property types

local safe_globals = {
	-- Instances
	"cache",
	"ui",
	"renderer",
	"input",
	-- Types
	"Scene",
	"Text",
	"Color",
	"Vector3",
	"Quaternion",
	"Viewport",
	"CustomGeometry",
	"Texture",
	"Material",
	-- Functions
	"Random",
	"Clamp",
	-- WTF properties
	"KEY_UP",
	"KEY_DOWN",
	"KEY_LEFT",
	"KEY_RIGHT",
	"KEY_W",
	"KEY_S",
	"KEY_A",
	"KEY_D",
}

for _, v in ipairs(safe_globals) do
	M.safe[v] = _G[v]
end

-- ResourceCache

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

M.safe.cache = {
	GetResource = function(self, resource_type, resource_name)
		-- TODO: If resource_type=XMLFile, we probably have to go through it and
		--       resave all references to other files found in there
		resource_name = M.check_safe_resource_name(resource_name)
		M.resave_file(resource_name)
		return cache:GetResource(resource_type, resource_name)
	end,
}

-- SubscribeToEvent

local sandbox_callback_to_global_function_name = {}
local next_sandbox_global_function_i = 1

function M.safe.SubscribeToEvent(x, y, z)
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
					"' is not a global function in current sandbox environment")
		end
	else
		-- Allow directly supplying callback function
	end
	local global_function_i = next_sandbox_global_function_i
	next_sandbox_global_function_i = next_sandbox_global_function_i + 1
	local global_callback_name = "__buildat_sandbox_callback_"..global_function_i
	sandbox_callback_to_global_function_name[callback] = global_callback_name
	_G[global_callback_name] = function(eventType, eventData)
		local f = function()
			if object then
				callback(object, eventType, eventData)
			else
				callback(eventType, eventData)
			end
		end
		__buildat_run_function_in_sandbox(f)
	end
	if object then
		SubscribeToEvent(object, event_name, global_callback_name)
	else
		SubscribeToEvent(event_name, global_callback_name)
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
	_G[global_callback_name] = function(eventType, eventData)
		if object then
			callback(object, eventType, eventData)
		else
			callback(eventType, eventData)
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
