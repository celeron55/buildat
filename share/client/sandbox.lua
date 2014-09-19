local log = buildat:Logger("__client/sandbox")

local sandbox = {}

sandbox.buildat = buildat

sandbox.require = function(name)
	error("require: \""..name.."\" not found in sandbox")
end

local function run_in_sandbox(untrusted_code, sandbox)
	if untrusted_code:byte(1) == 27 then return nil, "binary bytecode prohibited" end
	local untrusted_function, message = loadstring(untrusted_code)
	if not untrusted_function then return nil, message end
	setfenv(untrusted_function, sandbox)
	return pcall(untrusted_function)
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
		log:error("Failed to run script: "..err)
		return false
	end
	return true
end
