-- Buildat: client/sandbox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/sandbox")
local dump = buildat.dump

--
-- Base sandbox environment
--

__buildat_sandbox_environment = {
	assert = assert, -- Safe according to http://lua-users.org/wiki/SandBoxes
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
	log:info("require(\""..name.."\")")
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
		local unsafe = __buildat_load_extension(m)
		if unsafe == nil then
			error("require: Cannot load extension: \""..m.."\"")
		end
		package.loaded[name] = unsafe
		if type(unsafe.safe) ~= 'table' then
			error("require: \""..name.."\" didn't return safe interface")
		end
		log:info("Loaded extension \""..name.."\"")
		return unsafe.safe
	end
	-- Disallow loading anything else
	error("require: \""..name.."\" not found in sandbox")
end

--
-- Running code in sandbox
--

local function wrap_globals(base_sandbox)
	local sandbox = {}
	local sandbox_declared_globals = {}
	setmetatable(sandbox, {
		__index = function(t, k)
			local v = rawget(sandbox, k)
			if v ~= nil then return v end
			return base_sandbox[k]
		end,
		__newindex = function(t, k, v)
			if not sandbox_declared_globals[k] then
				local info = debug.getinfo(2, "Sl")
				log:info("sandbox["..dump(k).."] set by what="..dump(info.what)..
						", name="..dump(info.name))
				if info.what == "Lua" then
					error("Assignment to undeclared global \""..k.."\"\n     in "..
							info.short_src.." line "..info.currentline)
				end
			end
			sandbox_declared_globals[k] = true
			rawset(sandbox, k, v)
		end
	})
	function sandbox.buildat.make_global(t)
		for k, v in pairs(t) do
			if sandbox[k] == nil then
				rawset(sandbox, k, v)
			end
		end
	end
	return sandbox
end

local function run_function_in_sandbox(untrusted_function, sandbox)
	sandbox = wrap_globals(sandbox)
	setfenv(untrusted_function, sandbox)
	return __buildat_pcall(untrusted_function)
end

function __buildat_run_function_in_sandbox(untrusted_function)
	local status, err = run_function_in_sandbox(untrusted_function, __buildat_sandbox_environment)
	if status == false then
		log:error("Failed to run function:\n"..err)
		return false
	end
	return true
end

local function run_code_in_sandbox(untrusted_code, sandbox)
	if untrusted_code:byte(1) == 27 then return false, "binary bytecode prohibited" end
	local untrusted_function, message = loadstring(untrusted_code)
	if not untrusted_function then return false, message end
	return run_function_in_sandbox(untrusted_function, sandbox)
end

function __buildat_run_code_in_sandbox(untrusted_code)
	local status, err = run_code_in_sandbox(untrusted_code, __buildat_sandbox_environment)
	if status == false then
		log:error("Failed to run script:\n"..err)
		return false
	end
	return true
end

function buildat.run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "+name)
		return false
	end
	log:info("buildat.run_script_file("..name.."): code length: "..#code)
	return __buildat_run_code_in_sandbox(code)
end
buildat.safe.run_script_file = buildat.run_script_file

--
-- Insert buildat.safe into sandbox as buildat
--

__buildat_sandbox_environment.buildat = {}
for k, v in pairs(buildat.safe) do
	__buildat_sandbox_environment.buildat[k] = v
end

log:info("sandbox.lua loaded")
-- vim: set noet ts=4 sw=4:
