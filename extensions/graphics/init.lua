-- Buildat: extension/graphics/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local polybox = require("buildat/extension/polycode_sandbox")
local log = buildat.Logger("extension/graphics")
local dump = buildat.dump
local M = {safe = {}}

local hack_resaved_textures = {}

function M.resave_texture_for_polycode(texture_name)
	local path = __buildat_get_file_path(texture_name)
	local path2 = hack_resaved_textures[path]
	if path2 == nil then
		-- HACK: Create temporary file with the original file extension to
		--       make Polycode load it directly
		local hash_hex = string.match(path, '/([a-zA-Z0-9]+)$')
		local ext = string.match(texture_name, '\.([a-zA-Z0-9]+)$')
		log:info("File hash_hex="..dump(hash_hex).." extension"..dump(ext))
		path2 = __buildat_get_path("tmp").."/"..hash_hex.."."..ext
		log:info("Temporary path: "..path2)
		local src = io.open(path, "rb")
		local dst = io.open(path2, "wb")
		while true do
			local buf = src:read(100000)
			if buf == nil then break end
			dst:write(buf)
		end
		src:close()
		dst:close()
		hack_resaved_textures[path] = path2
	end
	return path2
end

-- NOTE: When adding an entity to a scene, it must be store it in some
--       globally persistent location until it is removed.
-- NOTE: These are the raw Polycode entities without wrappers.
M.scene_entities = {}

local function scene_entity_added(scene, entity)
	local entities = M.scene_entities[scene]
	if entities == nil then
		entities = {}
		M.scene_entities[scene] = entities
	end
	table.insert(entities, entity)
end

local function scene_entity_removed(scene, entity)
	-- TODO
end

M.safe.Scene = polybox.wrap_class("Scene", {
	constructor = function(sceneType, virtualScene)
		polybox.check_enum(sceneType, {Scene.SCENE_3D, Scene.SCENE_2D})
		polybox.check_enum(virtualScene, {true, false, "__nil"})
		return Scene(sceneType, virtualScene)
	end,
	class = {
		SCENE_3D = Scene.SCENE_3D,
		SCENE_2D = Scene.SCENE_2D,
	},
	instance = {
		addEntity = function(safe, entity_safe)
			unsafe = polybox.check_type(safe, "Scene")
			entity_unsafe = polybox.check_type(entity_safe, {"ScenePrimitive", "UILabel", "UIImage"})
			unsafe:addEntity(entity_unsafe)
			scene_entity_added(entity_unsafe)
		end,
		getDefaultCamera = function(safe)
			unsafe = polybox.check_type(safe, "Scene")
			return getmetatable(M.safe.Camera).wrap(unsafe:getDefaultCamera())
		end,
		getActiveCamera = function(safe)
			unsafe = polybox.check_type(safe, "Scene")
			return getmetatable(M.safe.Camera).wrap(unsafe:getActiveCamera())
		end,
		removeEntity = function(safe, entity_safe)
			unsafe = polybox.check_type(safe, "Scene")
			entity_unsafe = polybox.check_type(entity_safe, "ScenePrimitive")
			unsafe:removeEntity(entity_unsafe)
		end,
	},
})

M.safe.ScenePrimitive = polybox.wrap_class("ScenePrimitive", {
	constructor = function(type, v1, v2, v3, v4, v5)
		polybox.check_enum(type, {ScenePrimitive.TYPE_BOX, ScenePrimitive.TYPE_PLANE})
		polybox.check_type(v1, {"number", "nil"})
		polybox.check_type(v2, {"number", "nil"})
		polybox.check_type(v3, {"number", "nil"})
		polybox.check_type(v4, {"number", "nil"})
		polybox.check_type(v5, {"number", "nil"})
		return ScenePrimitive(type, v1, v2, v3, v4, v5)
	end,
	class = {
		TYPE_BOX = ScenePrimitive.TYPE_BOX,
		TYPE_PLANE = ScenePrimitive.TYPE_PLANE,
	},
	instance = {
		loadTexture = function(safe, texture_name)
			unsafe = polybox.check_type(safe, "ScenePrimitive")
			         polybox.check_type(texture_name, "string")
			local path2 = M.resave_texture_for_polycode(texture_name)
			unsafe:loadTexture(path2)
		end,
		setPosition = function(safe, x, y, z)
			unsafe = polybox.check_type(safe, "ScenePrimitive")
			         polybox.check_type(x, "number")
			         polybox.check_type(y, "number")
			         polybox.check_type(z, "number")
			unsafe:setPosition(x, y, z)
		end,
	},
})

M.safe.Camera = polybox.wrap_class("Camera", {
	constructor = function()
		return Camera()
	end,
	class = {
	},
	instance = {
		setPosition = function(safe, x, y, z)
			unsafe = polybox.check_type(safe, "Camera")
			         polybox.check_type(x, "number")
			         polybox.check_type(y, "number")
			         polybox.check_type(z, "number")
			unsafe:setPosition(x, y, z)
		end,
		lookAt = function(safe, v1, v2)
			unsafe = polybox.check_type(safe, "Camera")
			unsafe_v1 = polybox.check_type(v1, "Vector3")
			unsafe_v2 = polybox.check_type(v2, "Vector3")
			unsafe:lookAt(unsafe_v1, unsafe_v2)
		end,
		setOrthoSize = function(safe, x, y)
			unsafe = polybox.check_type(safe, "Camera")
			         polybox.check_type(x, "number")
			         polybox.check_type(y, "number")
			unsafe:setOrthoSize(x, y)
		end,
	},
})

M.safe.Vector3 = polybox.wrap_class("Vector3", {
	constructor = function(x, y, z)
		polybox.check_type(x, "number")
		polybox.check_type(y, "number")
		polybox.check_type(z, "number")
		return Vector3(x, y, z)
	end,
	class = {
	},
	instance = {
	},
})

return M
