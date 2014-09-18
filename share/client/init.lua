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

print("")
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from Lua!", 32)
label:setPosition(-50, -50, 0)
scene:addChild(label)

function buildat:sub_packet(name, cb)
end
function buildat:unsub_packet(cb)
end

