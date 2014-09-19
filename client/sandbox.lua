local log = buildat:Logger("__client/sandbox")

local buildat_safe_list = {
	"Logger",
}

local buildat_safe = {}

for _, name in ipairs(buildat_safe_list) do
	buildat_safe[name] = buildat[name]
end

local sandbox = {}

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
	if untrusted_code:byte(1) == 27 then return nil, "binary bytecode prohibited" end
	local untrusted_function, message = loadstring(untrusted_code)
	if not untrusted_function then return nil, message end
	setfenv(untrusted_function, sandbox)
	return __buildat_pcall(untrusted_function)
end

function buildat:run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "+name)
		return false
	end
	log:info("buildat:run_script_file("..name.."): #code="..#code)
	local status, err = run_in_sandbox(code, sandbox)
	--local status, err = run_in_sandbox(
	--		[[buildat:Logger("foo"):info("Pihvi")]], sandbox)
	if status == false then
		log:error("Failed to run script:\n"..err)
		return false
	end
	return true
end
