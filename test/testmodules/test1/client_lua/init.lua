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

-- Test some 3D things
local g3d = require("buildat/extension/graphics3d")

scene = g3d.Scene(g3d.Scene.SCENE_3D)
ground = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_PLANE, 5,5)
ground:loadTexture("Resources/green_texture.png")
scene:addEntity(ground)

box =  g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, 1,1,1)
box:loadTexture("Resources/pink_texture.png")
box:setPosition(0.0, 0.5, 0.0)
scene:addEntity(box)

scene:getDefaultCamera():setPosition(7,7,7)
scene:getDefaultCamera():lookAt(g3d.Vector3(0,0,0), g3d.Vector3(0,1,0))
