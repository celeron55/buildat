-- Buildat: extension/graphics3d/init.lua
local log = buildat:Logger("extension/graphics3d")
local dump = buildat.dump
local M = {safe = {}}

function sandbox_wrap_class(name, constructor, class_fields, instance_fields)
	local class = {}
	local meta = {}
	meta.wrap = function(unsafe)
		local safe = {}
		local meta = {unsafe = unsafe}
		meta.__index = function(a1, a2)
			local k = a1
			if type(a1) ~= 'string' and type(a2) == 'string' then
				k = a2
			end
			local v = instance_fields[k]
			if v ~= nil then return v end
			error("Instance of "..name.." does not have field "..dump(k))
		end
		setmetatable(safe, meta)
		return safe
	end
	meta.create_new = function(_, ...)
		return meta.wrap(constructor(unpack(arg)))
	end
	meta.__call = function(_, ...)
		return meta.create_new(_, unpack(arg))
	end
	for k, v in pairs(class_fields) do
		class[k] = v
	end
	setmetatable(class, meta)
	return class
end

M.safe.ScenePrimitive = sandbox_wrap_class("ScenePrimitive",
function(type, v1, v2, v3, v4, v5)
	log:info("unsafe="..dump(unsafe))
	log:info("type="..dump(type))
	log:info("v1="..dump(v1))
	return ScenePrimitive(type, v1, v2, v3, v4, v5)
end, {
	TYPE_BOX = ScenePrimitive.TYPE_BOX,
	TYPE_PLANE = ScenePrimitive.TYPE_PLANE,
}, {
	loadTexture = function(safe, texture_name)
		-- TODO
		local meta = getmetatable(safe)
		meta.unsafe:loadTexture("foo")
	end,
	setPosition = function(safe, x, y, z)
		local meta = getmetatable(safe)
		meta.unsafe:setPosition(x, y, z)
	end,
})

M.safe.Camera = sandbox_wrap_class("Camera",
function()
	return Camera()
end, {
}, {
	setPosition = function(safe, x, y, z)
		local meta = getmetatable(safe)
		meta.unsafe:setPosition(x, y, z)
	end,
	lookAt = function(safe, v1, v2)
		local meta = getmetatable(safe)
		meta.unsafe:lookAt(v1, v2)
	end,
})

M.safe.Scene = sandbox_wrap_class("Scene",
function(sceneType, virtualScene)
	return Scene(sceneType, virtualScene)
end, {
	SCENE_3D = Scene.SCENE_3D,
	SCENE_2D = Scene.SCENE_2D,
}, {
	addEntity = function(safe, entity_unsafe)
		local meta = getmetatable(safe)
		local entity_meta = getmetatable(entity_unsafe)
		log:info("entity_meta="..dump(entity_meta))
		meta.unsafe:addEntity(entity_meta.unsafe)
	end,
	getDefaultCamera = function(safe)
		local meta = getmetatable(safe)
		local camera_class_meta = getmetatable(M.safe.Camera)
		return camera_class_meta.wrap(meta.unsafe:getDefaultCamera())
	end,
})

return M
