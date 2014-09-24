-- Buildat: client/test.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/test")

--[[
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from Lua!", 32)
label:setPosition(-50, -50, 0)
scene:addChild(label)
]]

# vim: set noet ts=4 sw=4:
