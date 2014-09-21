-- Buildat: minigame/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
-- Copyright 2014 Břetislav Štec <valsiterb@gmail.com>
local log = buildat.Logger("minigame")
local dump = buildat.dump
log:info("minigame/init.lua loaded")

local mouse_grabbed = false

local cereal = require("buildat/extension/cereal")
local graphics = require("buildat/extension/graphics")
local ui = require("buildat/extension/ui")
local experimental = require("buildat/extension/experimental")
local keyinput = require("buildat/extension/keyinput")
local mouseinput = require("buildat/extension/mouseinput")
local joyinput = require("buildat/extension/joyinput")

local scene = graphics.Scene(graphics.Scene.SCENE_3D)
ground = graphics.ScenePrimitive(graphics.ScenePrimitive.TYPE_PLANE, 10,10)
ground:loadTexture("minigame/green_texture.png")
scene:addEntity(ground)

scene:getDefaultCamera():setPosition(7,7,7)
scene:getDefaultCamera():lookAt(graphics.Vector3(0,0,0), graphics.Vector3(0,1,0))

local scene2d = graphics.Scene(graphics.Scene.SCENE_2D_TOPLEFT)
scene2d:getActiveCamera():setOrthoSize(640, 480)
local label = ui.UILabel("testmodules/minigame", 32)
label:setPosition(120, 25)
scene2d:addEntity(label)

local image = ui.UIImage("minigame/pink_texture.png")
image:Resize(50, 50)
label:setAnchorPoint(graphics.Vector3(0,0,0))
image:setPosition(40, 25);
scene2d:addEntity(image)

--experimental.do_stuff(scene2d)

--- UI ---

local polybox = require("buildat/extension/polycode_sandbox")

polybox.class "SomeUI" (ui.UIElement)
function SomeUI:SomeUI()
	log:info("SomeUI:SomeUI()")
	ui.UIElement.UIElement(self)
	self:Resize(100, 60)
	self:setPosition(640-100, 0)

	self.button_grab_mouse = ui.UIButton("Mouse", 100, 30)
	self.button_grab_mouse:setPosition(0, 0)
	self:addChild(self.button_grab_mouse)

	self.button_clear_field = ui.UIButton("Clear", 100, 30)
	self.button_clear_field:setPosition(0, 30)
	self:addChild(self.button_clear_field)

	self.button_grab_mouse:addEventListener(self, function(self, e)
		log:info("SomeUI:on_button_grab_mouse()")
		self.button_grab_mouse.hasFocus = false
		if not mouse_grabbed then
			mouse_grabbed = true
			mouseinput.show_cursor(false)
		end
	end, ui.UIEvent.CLICK_EVENT)

	self.button_clear_field:addEventListener(self, function(self, e)
		log:info("SomeUI:on_button_clear_field()")
		self.button_clear_field.hasFocus = false
		buildat.send_packet("minigame:clear_field", "")
	end, ui.UIEvent.CLICK_EVENT)
end

scene2d.rootEntity.processInputEvents = true
local some_ui = SomeUI()
log:info("some_ui="..dump(some_ui))
scene2d:addEntity(some_ui)

----------

local field = {}
local players = {}
local player_boxes = {}
local field_boxes = {}

buildat.sub_packet("minigame:update", function(data)
	log:info("data="..buildat.dump(buildat.bytes(data)))
	values = cereal.binary_input(data, {"object",
		{"peer", "int32_t"},
		{"players", {"unordered_map",
			"int32_t",
			{"object",
				{"peer", "int32_t"},
				{"x", "int32_t"},
				{"y", "int32_t"},
			},
		}},
		{"playfield", {"object",
			{"w", "int32_t"},
			{"h", "int32_t"},
			{"tiles", {"array", "int32_t"}},
		}},
	})
	--log:info("values="..dump(values))

	field = values.playfield
	log:info("field="..dump(field))

	for _, box in ipairs(field_boxes) do
		scene:removeEntity(box)
	end
	field_boxes = {}
	for y=1,field.h do
		for x=1,field.w do
			local v = field.tiles[(y-1)*field.w + (x-1) + 1]
			if v ~= 0 then
				box = graphics.ScenePrimitive(graphics.ScenePrimitive.TYPE_BOX, 1,0.5*v,1)
				box:loadTexture("minigame/green_texture.png")
				box:setPosition(x-6, 0.25*v, y-6)
				scene:addEntity(box)
				table.insert(field_boxes, box)
			end
		end
	end

	local player_map = values.players
	local old_players = players
	players = {}
	for k, player in pairs(player_map) do
		table.insert(players, player)
	end
	log:info("players="..dump(players))

	for _, player in ipairs(players) do
		local is_new = true
		for _, old_player in ipairs(old_players) do
			if old_player.peer == player.peer then
				is_new = false
				break
			end
		end
		if is_new then
			box = graphics.ScenePrimitive(graphics.ScenePrimitive.TYPE_BOX, 0.9,0.9,0.9)
			box:loadTexture("minigame/pink_texture.png")
			box:setPosition(player.x-5, 0.5, player.y-5)
			scene:addEntity(box)
			player_boxes[player.peer] = box
		end
		local v = field.tiles[(player.y)*field.w + (player.x) + 1] or 0
		player_boxes[player.peer]:setPosition(player.x-5, 0.5+v*0.5, player.y-5)
	end
	for _, old_player in ipairs(old_players) do
		local was_removed = true
		for _, player in ipairs(players) do
			if player.peer == old_player.peer then
				was_removed = false
				break
			end
		end
		if was_removed then
			scene:removeEntity(player_boxes[old_player.peer])
		end
	end
end)

keyinput.sub(function(key, state)
	if key == keyinput.KEY_LEFT then
		if state == "down" then
			buildat.send_packet("minigame:move", "left")
		end
	end
	if key == keyinput.KEY_RIGHT then
		if state == "down" then
			buildat.send_packet("minigame:move", "right")
		end
	end
	if key == keyinput.KEY_UP then
		if state == "down" then
			buildat.send_packet("minigame:move", "up")
		end
	end
	if key == keyinput.KEY_DOWN then
		if state == "down" then
			buildat.send_packet("minigame:move", "down")
		end
	end
	if key == keyinput.KEY_SPACE then
		if state == "down" then
			buildat.send_packet("minigame:move", "place")
		end
	end
	if key == keyinput.KEY_ESCAPE then
		if state == "down" then
			if mouse_grabbed then
				mouseinput.show_cursor(true)
				mouse_grabbed = false
			end
		end
	end
end)

mouseinput.sub_down(function(button, x, y)
	log:info("mouse down: "..button..", "..x..", "..y)
end)

mouseinput.sub_move(function(x, y)
	if mouse_grabbed then
		--log:info("mouse delta: "..(x-100)..", "..(y-100))
		mouseinput.warp_cursor(100, 100)
	else
		--log:info("mouse move: "..x..", "..y)
	end
end)

local joystick_axes = {}

joyinput.sub_move(function(joystick, axis, value)
	joystick_axes[axis] = value
end)

local counter = 0
experimental.sub_tick(function(dtime)
	--log:info("tick: "..dtime.."s")
	counter = counter + dtime
	if counter > 0.2 then
		counter = counter - 0.2
		if joystick_axes[0] ~= nil and joystick_axes[0] > 0.5 then
			buildat.send_packet("minigame:move","right")
		end
		if joystick_axes[0] ~= nil and joystick_axes[0] < -0.5 then
			buildat.send_packet("minigame:move","left")
		end
		if joystick_axes[1] ~= nil and joystick_axes[1] > 0.5 then
			buildat.send_packet("minigame:move","down")
		end
		if joystick_axes[1] ~= nil and joystick_axes[1] < -0.5 then
			buildat.send_packet("minigame:move","up")
		end
	end
end)

joyinput.sub(function(joystick, button, state)
	if button == 0 then
		if state == "down" then
			buildat.send_packet("minigame:move", "place")
		end
	end
end)

