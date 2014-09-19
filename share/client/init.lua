-- Buildat: client/init.lua
buildat = {}
function buildat:Logger(module)
	local logger = {}
	function logger:info(text)
		print(os.date("%b %d %H:%M:%S "..module..": "..text))
	end
	function logger:error(text)
		print(os.date("%b %d %H:%M:%S "..module.." ERROR: "..text))
	end
	return logger
end

local log = buildat:Logger("__client")

log:info("init.lua loaded")

require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from Lua!", 32)
label:setPosition(-50, -50, 0)
scene:addChild(label)

buildat.packet_subs = {}

function buildat:sub_packet(name, cb)
	buildat.packet_subs[name] = cb
end
function buildat:unsub_packet(cb)
	for name, cb1 in pairs(buildat.packet_subs) do
		if cb1 == cb then
			buildat.packet_subs[cb] = nil
		end
	end
end

function buildat:send_packet(name, data)
	__buildat_send_packet(name, data)
end

local sandbox_env = {
	buildat = buildat,
}

local function run_in_sandbox(untrusted_code)
	if untrusted_code:byte(1) == 27 then return nil, "binary bytecode prohibited" end
	local untrusted_function, message = loadstring(untrusted_code)
	if not untrusted_function then return nil, message end
	setfenv(untrusted_function, sandbox_env)
	return pcall(untrusted_function)
end

function buildat:run_script_file(name)
	local code = __buildat_get_file_content(name)
	if not code then
		log:error("Failed to load script file: "+name)
		return false
	end
	log:info("buildat:run_script_file("..name.."): #code="..#code)
	local status, err = run_in_sandbox(code)
	--local status, err = run_in_sandbox([[buildat:Logger("foo"):info("Pihvi")]])
	if status == false then
		log:error("Failed to run script: "..err)
		return false
	end
	return true
end
