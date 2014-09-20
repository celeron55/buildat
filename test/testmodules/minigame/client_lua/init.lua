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
				box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, 1,0.5*v,1)
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
			box = g3d.ScenePrimitive(g3d.ScenePrimitive.TYPE_BOX, 0.9,0.9,0.9)
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

