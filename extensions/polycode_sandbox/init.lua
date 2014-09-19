-- Buildat: extension/polycode_sandbox/init.lua
local log = buildat:Logger("extension/polycode_sandbox")
local dump = buildat.dump
local M = {safe = nil}

function M.wrap_class(type_name, def)
	local class = {}
	local meta = {}
	meta.wrap = function(unsafe)
		local safe = {}
		local meta = {type_name = type_name, unsafe = unsafe}
		meta.__index = function(a1, a2)
			local k = a1
			if type(a1) ~= 'string' and type(a2) == 'string' then
				k = a2
			end
			local v = def.instance[k]
			if v ~= nil then return v end
			error("Instance of "..type_name.." does not have field "..dump(k))
		end
		setmetatable(safe, meta)
		return safe
	end
	meta.create_new = function(_, ...)
		return meta.wrap(def.constructor(unpack(arg)))
	end
	meta.__call = function(_, ...)
		return meta.create_new(_, unpack(arg))
	end
	for k, v in pairs(def.class) do
		class[k] = v
	end
	setmetatable(class, meta)
	return class
end

function M.check_type(thing, valid_types)
	if type(valid_types) == 'string' then valid_types = {valid_types} end
	local meta = getmetatable(thing)
	if meta and meta.type_name then
		for _, valid_type in ipairs(valid_types) do
			if valid_type == meta.type_name then
				return meta.unsafe
			end
		end
		error("Disallowed type: "..dump(meta.type_name))
	else
		local type_of_thing = type(thing)
		for _, valid_type in ipairs(valid_types) do
			if valid_type == type_of_thing then
				return thing
			end
		end
		error("Disallowed type: "..dump(type_of_thing))
	end
end

function M.check_enum(thing, valid_values)
	for _, valid_value in ipairs(valid_values) do
		if valid_value == thing then
			return thing
		end
		if valid_value == '__nil' and thing == nil then
			return thing
		end
	end
	error("Disallowed value: "..dump(thing))
end

return M
