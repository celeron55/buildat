local log = buildat:Logger("__client/test")

--[[
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from Lua!", 32)
label:setPosition(-50, -50, 0)
scene:addChild(label)
]]

