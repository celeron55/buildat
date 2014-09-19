-- Buildat: test1/client_lua/init.lua
local log = buildat.Logger("test1")
local dump = buildat.dump
log:info("test1/init.lua loaded")

-- Test extension interface safety
local test = require("buildat/extension/test")

test.f()

-- Test some 3D things
local g3d = require("buildat/extension/graphics3d")

scene = g3d.Scene(g3d.Scene.SCENE_3D)
ground = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_PLANE, 5,5)
ground:loadTexture("test1/green_texture.png")
scene:addEntity(ground)

scene:getDefaultCamera():setPosition(7,7,7)
scene:getDefaultCamera():lookAt(g3d.Vector3(0,0,0), g3d.Vector3(0,1,0))

local cereal = require("buildat/extension/cereal")

local the_box = nil

buildat.sub_packet("test1:add_box", function(data)
	values = cereal.binary_input(data, {
		"double", "double", "double",
		"double", "double", "double"
	})
	local w = values[1]
	local h = values[2]
	local d = values[3]
	local x = values[4]
	local y = values[5]
	local z = values[6]
	log:info("values="..dump(values))
	box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, w,h,d)
	box:loadTexture("test1/pink_texture.png")
	box:setPosition(x, y, z)
	scene:addEntity(box)
	the_box = box

	data = cereal.binary_output(
		{1,      "Foo", "Bar"},
		{"byte", {"string", 2}}
	)
	buildat.send_packet("test1:box_added", data)
end)

local keyinput = require("buildat/extension/keyinput")

keyinput.sub(function(key, state)
	log:info("key: "..key.." "..state)
	if key == keyinput.KEY_SPACE then
		if state == "down" then
			the_box:setPosition(0.0, 1.0, 0.0)
			scene:addEntity(box)
		end
	end
end)

local mouseinput = require("buildat/extension/mouseinput")

mouseinput.sub_move(function(x, y)
	--log:info("mouse move: "..x..", "..y..")")
end)
mouseinput.sub_down(function(button, x, y)
	--log:info("mouse down: "..button..", "..x..", "..y..")")
end)
mouseinput.sub_up(function(button, x, y)
	--log:info("mouse up: "..button..", "..x..", "..y..")")
end)

buildat.sub_packet("test1:array", function(data)
	values = cereal.binary_input(data, {"int32"})
	values = cereal.binary_input(data, {"int32", {"int32", values[1]}})
	log:info("test1:array: "..dump(values))

	data = cereal.binary_output(
		values,
		{"int32", {"int32", values[1]}}
	)
	buildat.send_packet("test1:array_response", data)
end)

--[[
-- Temporary test
require "Polycode/Core"
scene = Scene(Scene.SCENE_2D)
scene:getActiveCamera():setOrthoSize(640, 480)
label = SceneLabel("Hello from remote module!", 32)
label:setPosition(0, -100, 0)
scene:addChild(label)
--]]
