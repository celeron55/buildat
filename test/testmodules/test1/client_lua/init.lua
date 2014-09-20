-- Buildat: test1/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
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
	local values = cereal.binary_input(data, {"object",
		{"w", "double"},
		{"h", "double"},
		{"d", "double"},
		{"x", "double"},
		{"y", "double"},
		{"z", "double"},
	})
	local w = values.w
	local h = values.h
	local d = values.d
	local x = values.x
	local y = values.y
	local z = values.z
	log:info("values="..dump(values))
	box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, w,h,d)
	box:loadTexture("test1/pink_texture.png")
	box:setPosition(x, y, z)
	scene:addEntity(box)
	the_box = box

	values = {
		a = 128,
		b = 1000,
		c = 3.14,
		d = "Foo",
		e = {"Bar1", "Bar2"},
		f = {x=1, y=2},
	}
	data = cereal.binary_output(values, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	buildat.send_packet("test1:box_added", data)

	-- Try deserializing it too and see if all is working
	values = cereal.binary_input(data, {"object",
		{"a", "byte"},
		{"b", "int32_t"},
		{"c", "double"},
		{"d", "string"},
		{"e", {"array", "string"}},
		{"f", {"object", {"x", "int32_t"}, {"y", "int32_t"}}}
	})
	assert(values.a == 128)
	assert(values.b == 1000)
	assert(values.c == 3.14)
	assert(values.d == "Foo")
	assert(values.e[2] == "Bar2")
	assert(values.f.y == 2)
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
	local array = cereal.binary_input(data, {"array", "int32_t"})
	log:info("test1:array: "..dump(array))

	data = cereal.binary_output(array, {"array", "int32_t"})
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
