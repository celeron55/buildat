-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
buildat.extension_path    = __buildat_extension_path

buildat.safe.disconnect    = __buildat_disconnect

function buildat.safe.set_simple_voxel_model(safe_node, w, h, d, safe_buffer)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if not getmetatable(safe_buffer) or
			getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
		error("safe_buffer is not a sandboxed VectorBuffer instance")
	end
	node = getmetatable(safe_node).unsafe
	buffer = getmetatable(safe_buffer).unsafe
	__buildat_set_simple_voxel_model(node, w, h, d, buffer)
end

function buildat.safe.set_8bit_voxel_geometry(safe_node, w, h, d, safe_buffer)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	if not getmetatable(safe_buffer) or
			getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
		error("safe_buffer is not a sandboxed VectorBuffer instance")
	end
	node = getmetatable(safe_node).unsafe
	buffer = getmetatable(safe_buffer).unsafe
	__buildat_set_8bit_voxel_geometry(node, w, h, d, buffer)
end

local IntVector3_prototype = {
	x = 0,
	y = 0,
	z = 0,
	mul_components = function(a, b)
		return buildat.safe.IntVector3(
				a.x * b.x, a.y * b.y, a.z * b.z)
	end,
	div_components = function(a, b)
		return buildat.safe.IntVector3(
				a.x / b.x, a.y / b.y, a.z / b.z)
	end,
	floor = function(a)
		return buildat.safe.IntVector3(
				math.floor(a.x), math.floor(a.y), math.floor(a.z))
	end,
	add = function(a, b)
		return buildat.safe.IntVector3(
				a.x + b.x, a.y + b.y, a.z + b.z)
	end,
	sub = function(a, b)
		return buildat.safe.IntVector3(
				a.x - b.x, a.y - b.y, a.z - b.z)
	end,
}
function buildat.safe.IntVector3(x, y, z)
	local self = {}
	if x ~= nil and y == nil and z == nil then
		self.x = x.x
		self.y = x.y
		self.z = x.z
	else
		self.x = x
		self.y = y
		self.z = z
	end
	setmetatable(self, {
		__index = IntVector3_prototype,
		__add = IntVector3_prototype.add,
		__sub = IntVector3_prototype.sub,
	})
	return self
end

-- vim: set noet ts=4 sw=4:
