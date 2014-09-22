-- Buildat: client/urho3d.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("client/urho3d")

local sandbox = __buildat_sandbox_environment

-- Set every plain value in global environment to the sandbox
-- ...it's maybe safe enough...
for k, v in pairs(_G) do
	if type(v) == 'number' or type(v) == 'string' then
		--log:info("Setting sandbox["..k.."] = "..buildat.dump(v))
		sandbox[k] = _G[k]
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
	"KEY_W",
	"KEY_S",
	"KEY_A",
	"KEY_D",
}

for _, v in ipairs(safe_globals) do
	sandbox[v] = _G[v]
end

local sandbox_function_name_to_global_function_name = {}
local next_global_function_i = 1

function sandbox.SubscribeToEvent(event_name, function_name)
	if type(sandbox[function_name]) ~= 'function' then
		error("sandbox.SubscribeToEvent(): '"..function_name..
				"' is not a global function in sandbox environment")
	end
	local global_function_i = next_global_function_i
	next_global_function_i = next_global_function_i + 1
	local global_function_name = "__buildat_sandbox_callback_"..global_function_i
	sandbox_function_name_to_global_function_name[function_name] = global_function_name
	_G[global_function_name] = function(eventType, eventData)
		local f = function()
			sandbox[function_name](eventType, eventData)
		end
		__buildat_run_function_in_sandbox(f)
	end
	SubscribeToEvent(event_name, global_function_name)
end
