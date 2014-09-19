-- Buildat: test1/client_lua/init.lua
local log = buildat:Logger("test1")
log:info("test1/init.lua loaded")

--[[
-- Temporary test
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from remote module!", 32)
label:setPosition(0, -100, 0)
scene:addChild(label)
--]]

local test = require("buildat/extension/test")

test.f()

