-- Buildat: client_lua/boot.lua
local log = buildat:Logger("client_lua")
log:info("boot.lua loaded")

-- Temporary test
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from remote module!", 32)
label:setPosition(0, -100, 0)
scene:addChild(label)

