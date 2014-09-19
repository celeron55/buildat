-- Buildat: minigame/client_lua/init.lua
local log = buildat.Logger("minigame")
local dump = buildat.dump
log:info("minigame/init.lua loaded")

local cereal = require("buildat/extension/cereal")
local g3d = require("buildat/extension/graphics3d")

scene = g3d.Scene(g3d.Scene.SCENE_3D)
ground = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_PLANE, 10,10)
ground:loadTexture("minigame/green_texture.png")
scene:addEntity(ground)

scene:getDefaultCamera():setPosition(7,7,7)
scene:getDefaultCamera():lookAt(g3d.Vector3(0,0,0), g3d.Vector3(0,1,0))

local field = {}
local players = {}
local player_boxes = {}
local field_boxes = {}

buildat.sub_packet("minigame:update", function(data)
	values = cereal.binary_input(data, {
		"int32", "int32", "int32", "int32"
	})
	local peer = values[1]
	local num_players = values[2]
	local field_w = values[3]
	local field_h = values[4]
	values = cereal.binary_input(data, {
		"int32", "int32", "int32", "int32",
		{"int32", field_w*field_h}, {"int32", num_players*3}
	})
	--log:info("values="..dump(values))
	local new_field = {}
	for i=1,field_w*field_h do
		table.insert(new_field, values[4+i])
	end
	field = new_field
	log:info("field="..dump(field))

	for _, box in ipairs(field_boxes) do
		scene:removeEntity(box)
	end
	field_boxes = {}
	for y=1,field_h do
		for x=1,field_w do
			local v = field[(y-1)*field_w + (x-1) + 1]
			if v ~= 0 then
				box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, 1,0.5*v,1)
				box:loadTexture("minigame/green_texture.png")
				box:setPosition(x-6, 0.25*v, y-6)
				scene:addEntity(box)
				table.insert(field_boxes, box)
			end
		end
	end

	local new_players = {}
	local players_start = 5+field_w*field_h
	for i=1,num_players do
		local player = {
			peer = values[players_start+(i-1)*3+0],
			x = values[players_start+(i-1)*3+1],
			y = values[players_start+(i-1)*3+2],
		}
		table.insert(new_players, player)
	end
	local old_players = players
	players = new_players
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
			box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, 0.9,0.9,0.9)
			box:loadTexture("minigame/pink_texture.png")
			box:setPosition(player.x-5, 0.5, player.y-5)
			scene:addEntity(box)
			player_boxes[player.peer] = box
		end
		local v = field[(player.y)*field_w + (player.x) + 1] or 0
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

local keyinput = require("buildat/extension/keyinput")

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
end)

