-- Buildat: client/init.lua
buildat = {}
function buildat:Logger(module)
	local logger = {}
	function logger:info(text)
		print(os.date("%b %d %H:%M:%S "..module..": "..text))
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

function buildat:run_script_file(name)
	local content = __buildat_get_file_content(name)
	if not content then
		return false
	end
	log:info("buildat:run_script_file("..name.."): #content="..#content)
	local script, err = loadstring(content)
	if not script then
		log:error("Failed to load script: "+err)
		return false
	end
	script()
end

