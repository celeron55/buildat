-- Buildat: client/sandbox.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/sandbox")

local buildat_safe_list = {
	"bytes",
	"dump",
	"Logger",
}

local buildat_safe = {}

for _, name in ipairs(buildat_safe_list) do
	buildat_safe[name] = buildat[name]
end

local sandbox = {
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

sandbox.buildat = buildat

sandbox.require = function(name)
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
			error("require: Extension not found: \""..m.."\"")
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

local function run_in_sandbox(untrusted_code, sandbox)
	if untrusted_code:byte(1) == 27 then return false, "binary bytecode prohibited" end
	local untrusted_function, message = loadstring(untrusted_code)
	if not untrusted_function then return false, message end
	setfenv(untrusted_function, sandbox)
	return __buildat_pcall(untrusted_function)
end

function __buildat_run_in_sandbox(untrusted_code)
	local status, err = run_in_sandbox(untrusted_code, sandbox)
	if status == false then
		log:error("Failed to run script:\n"..err)
		return false
	end
	return true
end

function buildat:run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "+name)
		return false
	end
	log:info("buildat:run_script_file("..name.."): code length: "..#code)
	return __buildat_run_in_sandbox(code)
end
