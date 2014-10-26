-- Buildat: client/sandbox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("sandbox")
local dump = buildat.dump

--
-- Base sandbox environment
--

__buildat_sandbox_environment = {
	assert = assert, -- Safe according to http://lua-users.org/wiki/SandBoxes
	error = error,
	-- Base sandbox from
	-- http://stackoverflow.com/questions/1224708/how-can-i-create-a-secure-lua-sandbox/6982080#6982080
	ipairs = ipairs,
	next = next,
	pairs = pairs,
	pcall = pcall,
	tonumber = tonumber,
	tostring = tostring,
	type = type,
	unpack = unpack,
	coroutine = { create = coroutine.create, resume = coroutine.resume,
		running = coroutine.running, status = coroutine.status,
		wrap = coroutine.wrap },
	string = { byte = string.byte, char = string.char, find = string.find,
		format = string.format, gmatch = string.gmatch, gsub = string.gsub,
		len = string.len, lower = string.lower, match = string.match,
		rep = string.rep, reverse = string.reverse, sub = string.sub,
		upper = string.upper },
	table = { insert = table.insert, maxn = table.maxn, remove = table.remove,
		sort = table.sort },
	math = { abs = math.abs, acos = math.acos, asin = math.asin,
		atan = math.atan, atan2 = math.atan2, ceil = math.ceil, cos = math.cos,
		cosh = math.cosh, deg = math.deg, exp = math.exp, floor = math.floor,
		fmod = math.fmod, frexp = math.frexp, huge = math.huge,
		ldexp = math.ldexp, log = math.log, log10 = math.log10, max = math.max,
		min = math.min, modf = math.modf, pi = math.pi, pow = math.pow,
		rad = math.rad, random = math.random, sin = math.sin, sinh = math.sinh,
		sqrt = math.sqrt, tan = math.tan, tanh = math.tanh },
	os = { clock = os.clock, difftime = os.difftime, time = os.time },
}

--
-- Sandbox require
--

__buildat_sandbox_environment.require = function(name)
	log:debug("require(\""..name.."\")")
	-- Check loaded modules
	if package.loaded[name] then
		local unsafe = package.loaded[name]
		if type(unsafe.safe) ~= 'table' then
			error("require: \""..name.."\" didn't return safe interface")
		end
		return unsafe.safe
	end
	-- Allow loading extensions
	local m = string.match(name, '^buildat/extension/([a-zA-Z0-9_]+)$')
	if m then
		local unsafe = __buildat_require_extension(m)
		if unsafe == nil then
			error("require: Cannot load extension: \""..m.."\"")
		end
		package.loaded[name] = unsafe
		if type(unsafe.safe) ~= 'table' then
			error("require: \""..name.."\" didn't return safe interface")
		end
		log:verbose("Loaded extension \""..name.."\"")
		return unsafe.safe
	end
	-- Allow loading the client-side parts of modules
	local m = string.match(name, '^buildat/module/([a-zA-Z0-9_]+)$')
	if m then
		local interface = __buildat_require_module(m)
		if interface == nil then
			error("require: Cannot load module: \""..m.."\"")
		end
		log:verbose("Loaded module \""..name.."\"")
		return interface
	end
	-- Disallow loading anything else
	error("require: \""..name.."\" not found in sandbox")
end

--
-- Sandbox environment debugging
--

-- Bindings for debug or safety checks (override function)
local __buildat_sandbox_debug_check_value_subs = {}
function __buildat_sandbox_debug_check_value_sub(f)
	table.insert(__buildat_sandbox_debug_check_value_subs, f)
end
function __buildat_sandbox_debug_check_value(value)
	for _, f in ipairs(__buildat_sandbox_debug_check_value_subs) do
		f(value)
	end
end

-- For debugging purposes. Used by extensions/sandbox_test.
__buildat_latest_sandbox_global_wrapper_number = 0 -- Incremented every time
__buildat_latest_sandbox_global_wrapper = nil
-- Save a number of old wrappers for debugging purposes
__buildat_old_sandbox_global_wrappers = {}

local function debug_new_wrapper(sandbox)
	if __buildat_latest_sandbox_global_wrapper then
		table.insert(__buildat_old_sandbox_global_wrappers, __buildat_latest_sandbox_global_wrapper)
		-- Keep a number of old wrappers.
		-- These wrappers are created at quite a fast pace due to Update events.
		if #__buildat_old_sandbox_global_wrappers > 60*5 then
			table.remove(__buildat_old_sandbox_global_wrappers, 1)
		end
	end
	__buildat_latest_sandbox_global_wrapper_number = __buildat_latest_sandbox_global_wrapper_number + 1
	__buildat_latest_sandbox_global_wrapper = sandbox
end

--
-- Running code in sandbox
--

local function wrap_globals(base_sandbox)
	local sandbox = {}
	local sandbox_declared_globals = {}
	-- Sandbox special functions
	sandbox.sandbox = {}
	function sandbox.sandbox.make_global(t)
		for k, v in pairs(t) do
			if sandbox[k] == nil then
				rawset(sandbox, k, v)
			end
		end
	end
	-- Prevent setting sandbox globals from functions (only from the main chunk)
	setmetatable(sandbox, {
		__index = function(t, k)
			local v = rawget(sandbox, k)
			if v ~= nil then return v end
			return base_sandbox[k]
		end,
		__newindex = function(t, k, v)
			if not sandbox_declared_globals[k] then
				local info = debug.getinfo(2, "Sl")
				log:debug("Global: "..dump(k).." (set by {what="..dump(info.what)..
						", name="..dump(info.name).."})")
				if info.what == "Lua" then
					error("Assignment to undeclared global \""..k.."\"\n     in "..
							info.short_src.." line "..info.currentline)
				end
			end
			sandbox_declared_globals[k] = true
			rawset(sandbox, k, v)
		end
	})
	debug_new_wrapper(sandbox)
	return sandbox
end

local function run_function_in_sandbox(untrusted_function, sandbox)
	sandbox = wrap_globals(sandbox)
	setfenv(untrusted_function, sandbox)
	local retval = nil
	local status, err = __buildat_pcall(function()
		retval = untrusted_function()
	end)
	return status, err, retval
end

function __buildat_run_function_in_sandbox(untrusted_function)
	local status, err, retval = run_function_in_sandbox(
			untrusted_function, __buildat_sandbox_environment)
	if status == false then
		log:error("Failed to run function:\n"..err)
	end
	return status, err, retval
end

local function run_code_in_sandbox(untrusted_code, sandbox, chunkname)
	if untrusted_code:byte(1) == 27 then
		return false, "binary bytecode prohibited", nil
	end
	local untrusted_function, message = loadstring(untrusted_code, chunkname)
	if not untrusted_function then
		return false, message, nil
	end
	return run_function_in_sandbox(untrusted_function, sandbox)
end

function __buildat_run_code_in_sandbox(untrusted_code, chunkname)
	local status, err, retval = run_code_in_sandbox(
			untrusted_code, __buildat_sandbox_environment, chunkname)
	if status == false then
		log:error("Failed to run script:\n"..err)
	end
	return status, err, retval
end

function buildat.run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "..name)
		return false
	end
	log:info("buildat.run_script_file("..name.."): code length: "..#code)
	return __buildat_run_code_in_sandbox(code, name)
end
buildat.safe.run_script_file = buildat.run_script_file

--
-- Insert buildat.safe into sandbox as buildat
--

__buildat_sandbox_environment.buildat = {}
for k, v in pairs(buildat.safe) do
	__buildat_sandbox_environment.buildat[k] = v
end

-- With this you can do stuff like
--   local is_in_sandbox = getfenv(2).buildat.is_in_sandbox
-- in extensions.
__buildat_sandbox_environment.buildat.is_in_sandbox = true

setmetatable(__buildat_sandbox_environment.buildat, {
	__newindex = function(t, k, v)
		assert("Cannot add fields to buildat namespace in sandbox environment")
	end,
})

log:info("sandbox.lua loaded")
-- vim: set noet ts=4 sw=4:
