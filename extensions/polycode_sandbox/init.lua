-- Buildat: extension/polycode_sandbox/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("extension/polycode_sandbox")
local dump = buildat.dump
local M = {safe = {}}

-- The resulting value from this function should be placed directly in the
-- sandbox environment's global environment as _G[type_name]
function M.wrap_class(type_name, def)
	local class = {}
	local class_meta = {}
	class_meta.def = def
	class_meta.type_name = type_name
	class_meta.inherited_from_in_sandbox = def.inherited_from_in_sandbox
	class_meta.inherited_from_by_wrapper = def.inherited_from_by_wrapper
	class_meta.wrap = function(unsafe)
		local safe = {}
		local meta = {
			unsafe = unsafe,
		}
		setmetatable(meta, {
			__index = class_meta, -- For reading class properties
		})
		meta.__index = function(table, key)
			if def.custom_index then
				return def.custom_index(safe, key)
			end
			local class_meta0 = class_meta
			while true do
				if class_meta0.inherited_from_in_sandbox or
				   class_meta0.inherited_from_by_wrapper then
					local sandboxed_superclass_meta = getmetatable(
							class_meta0.inherited_from_in_sandbox or
							class_meta0.inherited_from_by_wrapper)
					-- Wrap superclass instance and property fields
					local super_def = sandboxed_superclass_meta.def
					if super_def.instance and super_def.instance[key] then
						return super_def.instance[key]
					end
					if super_def.properties and super_def.properties[key] then
						local property_def = super_def.properties[key]
						if property_def.get then
							local current_value = unsafe[key]
							return property_def.get(current_value)
						end
						error("Property \""..key.."\" of "..type_name.."'s superclass "..
								super_type_name.." cannot be read")
					end
					class_meta0 = sandboxed_superclass_meta
				else
					break
				end
			end
			if class_meta.inherited_from_in_sandbox then
				-- Have been added to this class in the sandbox environment
				local safe_class = __buildat_sandbox_environment[type_name]
				return safe_class[key]
			end
			-- Properties and fields (methods) can be read
			if def.properties then
				local property_def = def.properties[key]
				if property_def ~= nil then
					if property_def.get == nil then
						error("Property \""..name.."\" of "..type_name.." cannot be read")
					end
					local current_value = unsafe[key]
					return property_def.get(current_value)
				end
			end
			if def.instance then
				local v = def.instance[key]
				if v ~= nil then
					return v
				end
			end
			error("Instance of "..type_name.." does not have field or property "..dump(key))
		end
		meta.__newindex = function(table, key, value)
			if def.custom_newindex then
				return def.custom_newindex(safe, key, value)
			end
			local class_meta0 = class_meta
			while true do
				if class_meta0.inherited_from_in_sandbox or
				   class_meta0.inherited_from_by_wrapper then
					local sandboxed_superclass_meta = getmetatable(
							class_meta0.inherited_from_in_sandbox or
							class_meta0.inherited_from_by_wrapper)
					-- Wrap superclass instance and property fields
					local super_def = sandboxed_superclass_meta.def
					if super_def.properties and super_def.properties[key] then
						local property_def = super_def.properties[key]
						if property_def.set then
							local new_value = property_def.set(value)
							unsafe[key] = new_value
							return
						end
						error("Property \""..key.."\" of "..type_name.."'s superclass "..
								super_type_name.." cannot be written")
					end
					class_meta0 = sandboxed_superclass_meta
				else
					break
				end
			end
			if class_meta.inherited_from_in_sandbox then
				-- Have been defined to this class in the sandbox environment
				local safe_class = __buildat_sandbox_environment[type_name]
				safe_class[key] = value
				return
			end
			-- Only propreties can be set
			if def.properties then
				local property_def = def.properties[key]
				if property_def ~= nil then
					if property_def.set == nil then
						error("Property \""..name.."\" of "..type_name.." cannot be written")
					end
					local new_value = property_def.set(value)
					unsafe[key] = new_value
					return
				end
			end
			error("Instance of "..type_name.." does not have property "..dump(key))
		end
		setmetatable(safe, meta)
		return safe
	end
	class_meta.create_new = function(_, ...)
		local unsafe_instance = def.constructor(unpack(arg))
		--log:info("unsafe_instance="..dump(unsafe_instance))
		local safe_instance = class_meta.wrap(unsafe_instance)
		--log:info("safe_instance="..dump(safe_instance))
		if def.safe_constructor then
			def.safe_constructor(safe_instance)
		end
		return safe_instance
	end
	class_meta.__call = function(_, ...)
		return class_meta.create_new(_, unpack(arg))
	end
	if def.class then
		for k, v in pairs(def.class) do
			class[k] = v
		end
	end
	setmetatable(class, class_meta)
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
		-- Check if thing is inherited safely from a valid type
		local unsafe_instance = meta.unsafe
		while true do
			local tried_super_types = {} -- For error message
			local super = meta.inherited_from_in_sandbox or
					meta.inherited_from_by_wrapper
			--print("super="..dump(super)..", valid_types="..dump(valid_types))
			if super == nil then
				break
			end
			meta = getmetatable(super)
			for _, valid_type in ipairs(valid_types) do
				--print("meta="..dump(meta))
				if valid_type == meta.type_name then
					return unsafe_instance
				end
				table.insert(tried_super_types, meta.type_name)
			end
		end
		error("Disallowed type: "..dump(meta.type_name)..", super types "
				..dump(tried_super_types))
	else
		local type_of_thing = type(thing)
		for _, valid_type in ipairs(valid_types) do
			if valid_type == type_of_thing then
				return thing
			end
			if valid_type == '__nil' and thing == nil then
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

-- Sandbox wrapper for Polycode's Lua class model:
-- Function returns a class creation function.
function M.safe.class(name)
	-- Function creates a class into the global sandbox namespace
	return function(sandboxed_superclass)
		-- The unsafe way (which also produces unusable types for this usage):
		--class(name)(superclass)
		--__buildat_sandbox_environment[name] = _G[name]

		-- We need to create the original non-sandboxed version of the 
		-- wanted resulting class.
		-- It should be doable by getting the type_name of the sandboxed
		-- superclass and using it to index the non-sandboxed global namespace.
		local sandboxed_superclass_meta = getmetatable(sandboxed_superclass)
		if sandboxed_superclass_meta == nil or
				sandboxed_superclass_meta.type_name == nil then
			error("Parameter does not look like a sandboxed class created "..
					"by polycode_sandbox.wrap_class()")
		end
		local super_type_name = sandboxed_superclass_meta.type_name
		local superclass = _G[super_type_name]
		if superclass == nil then
			error("A corresponding non-sandboxed class does not exist for "..
					"super_type_name=\""..super_type_name.."\"")
		end
		-- Create the non-sandboxed version of the wanted class into the global
		-- non-sandboxed namespace
		class(name)(superclass)

		-- Now safety-wrap the end result
		local sandboxed_class = M.wrap_class(name, {
			inherited_from_in_sandbox = sandboxed_superclass,
			constructor = function(...)
				-- Ignore arguments to this unsafe constructor
				local unsafe_instance = _G[name]()
				return unsafe_instance
			end,
			safe_constructor = function(safe_instance, ...)
				-- The user-facing "constructor" function is added to the
				-- environment after running this original M.wrap_class(), so
				-- get it now and run it
				local user_constructor = __buildat_sandbox_environment[name][name]
				if user_constructor ~= nil then
					-- Allow arguments to this safe constructor
					user_constructor(safe_instance, unpack(arg))
				end
			end,
		})
		__buildat_sandbox_environment[name] = sandboxed_class
	end
end

return M
