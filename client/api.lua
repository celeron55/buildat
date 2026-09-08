-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
buildat.list_games        = __buildat_list_games
buildat.start_local_server = __buildat_start_local_server
buildat.stop_local_server = __buildat_stop_local_server
buildat.request_stop_local_server = __buildat_request_stop_local_server
buildat.force_kill_local_server = __buildat_force_kill_local_server
buildat.local_server_ready = __buildat_local_server_ready
buildat.local_server_port = __buildat_local_server_port
buildat.local_server_running = __buildat_local_server_running
buildat.extension_path    = __buildat_extension_path
buildat.get_time_us       = __buildat_get_time_us
buildat.sha1              = __buildat_sha1
buildat.sha256            = __buildat_sha256
buildat.hex               = __buildat_hex
buildat.random_bytes      = __buildat_random_bytes
-- Big-endian byte strings in, byte strings out
buildat.bignum = {
	add     = __buildat_bignum_add,
	mul     = __buildat_bignum_mul,
	mod     = __buildat_bignum_mod,
	sub_mod = __buildat_bignum_sub_mod,
	mul_mod = __buildat_bignum_mul_mod,
	mod_exp = __buildat_bignum_mod_exp,
}
buildat.set_ui_scale      = __buildat_set_ui_scale
buildat.get_ui_scale      = __buildat_get_ui_scale
buildat.font_sans         = "Fonts/Overpass-Regular.ttf"
buildat.font_mono         = "Fonts/OverpassMono-Regular.ttf"
buildat.SpatialUpdateQueue = __buildat_SpatialUpdateQueue

buildat.safe.disconnect    = __buildat_disconnect
buildat.safe.set_ui_scale  = __buildat_set_ui_scale
buildat.safe.get_ui_scale  = __buildat_get_ui_scale
buildat.safe.font_sans     = buildat.font_sans
buildat.safe.font_mono     = buildat.font_mono
buildat.safe.get_time_us   = __buildat_get_time_us
buildat.safe.sha1          = __buildat_sha1
buildat.safe.sha256        = __buildat_sha256
buildat.safe.hex           = __buildat_hex
buildat.safe.profiler_block_begin = __buildat_profiler_block_begin
buildat.safe.profiler_block_end   = __buildat_profiler_block_end
buildat.safe.VoxelName            = __buildat_VoxelName
buildat.safe.AtlasSegmentDefinition = __buildat_AtlasSegmentDefinition
buildat.safe.VoxelDefinition      = __buildat_VoxelDefinition
buildat.safe.createVoxelRegistry  = __buildat_createVoxelRegistry
buildat.safe.createAtlasRegistry  = __buildat_createAtlasRegistry
buildat.safe.Region        = __buildat_Region
buildat.safe.VoxelInstance = __buildat_VoxelInstance
buildat.safe.Volume        = __buildat_Volume
buildat.safe.deserialize_volume       = __buildat_deserialize_volume
buildat.safe.deserialize_volume_int32 = __buildat_deserialize_volume_int32
buildat.safe.deserialize_volume_8bit  = __buildat_deserialize_volume_8bit
-- cast_voxel_rays(args): marches rays through voxel data. args.directions is a
-- flat array of numbers, three to a ray. With args.rays_per_cell set,
-- consecutive rays are one cell's and what comes back is their average
-- visibility per cell; without it, what every ray ran into. See the comments
-- in src/lua_bindings/voxel_volume.cpp.
buildat.safe.cast_voxel_rays          = __buildat_cast_voxel_rays
-- cast_voxel_rays_start(args) takes what cast_voxel_rays() takes and returns a
-- handle; cast_voxel_rays_collect(handle) returns nil until the marching has
-- finished on a worker thread, and then what cast_voxel_rays() would have
-- returned. The volumes and the registry are held for the job's lifetime, so a
-- chunk arriving meanwhile does not pull data out from under it.
buildat.safe.cast_voxel_rays_start    = __buildat_cast_voxel_rays_start
buildat.safe.cast_voxel_rays_collect  = __buildat_cast_voxel_rays_collect
-- write_floats(vector_buffer, values): the values into the buffer as floats,
-- replacing what was in it
buildat.safe.write_floats             = __buildat_write_floats
-- What stopped a ray cast by cast_voxel_rays(); see its comment in
-- src/lua_bindings/voxel_volume.cpp
buildat.safe.VOXEL_RAY = {
	BLOCKED  = 0, -- Ran into something not passable
	NO_DATA  = 1, -- Left the volumes it was given
	RANGE    = 2, -- Used up max_steps
	SKYLIGHT = 3, -- Reached the stop_skylight it was given
}

-- NOTE: Maybe not actually safe
--buildat.safe.class_info = class_info -- Luabind class_info()

buildat.safe.SpatialUpdateQueue = function()
	local internal = __buildat_SpatialUpdateQueue()
	return {
		update = function(self, ...)
			return internal:update(...)
		end,
		set_p = function(self, ...)
			return internal:set_p(...)
		end,
		put = function(self, safe_p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			return internal:put(p, near_weight, near_trigger_d,
					far_weight, far_trigger_d, value)
		end,
		get = function(self, ...)
			return internal:get(...)
		end,
		peek_next_f = function(self, ...)
			return internal:peek_next_f(...)
		end,
		peek_next_fw = function(self, ...)
			return internal:peek_next_fw(...)
		end,
		get_length = function(self, ...)
			return internal:get_length(...)
		end,
		set_p = function(self, safe_p)
			if not getmetatable(safe_p) or
					getmetatable(safe_p).type_name ~= "Vector3" then
				error("p is not a sandboxed Vector3 instance")
			end
			p = getmetatable(safe_p).unsafe
			internal:set_p(p)
		end,
	}
end

-- TODO: Implement sandbox unwrapping in C++ and remove these from here
--       (already done in lua_bindings/voxel.cpp)

function buildat.safe.set_simple_voxel_model(safe_node, w, h, d, safe_buffer)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end

	__buildat_set_simple_voxel_model(node, w, h, d, buffer)
end

function buildat.safe.set_8bit_voxel_geometry(safe_node, w, h, d, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_8bit_voxel_geometry(node, w, h, d, buffer, ...)
end

function buildat.safe.set_voxel_geometry(safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_geometry(node, buffer, ...)
end

function buildat.safe.set_voxel_lod_geometry(lod, safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_lod_geometry(lod, node, buffer, ...)
end

function buildat.safe.clear_voxel_geometry(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_geometry(node)
end

function buildat.safe.set_voxel_physics_boxes(safe_node, safe_buffer, ...)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	buffer = nil
	if type(safe_buffer) == 'string' then
		buffer = safe_buffer
	else
		if not getmetatable(safe_buffer) or
				getmetatable(safe_buffer).type_name ~= "VectorBuffer" then
			error("safe_buffer is not a sandboxed VectorBuffer instance")
		end
		buffer = getmetatable(safe_buffer).unsafe
	end
	__buildat_set_voxel_physics_boxes(node, buffer, ...)
end

function buildat.safe.clear_voxel_physics_boxes(safe_node)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe

	__buildat_clear_voxel_physics_boxes(node)
end

local Vector3_prototype = {
	x = 0,
	y = 0,
	z = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..", "..a.z..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y and a.z == b.z)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector3(
				a.x * b.x, a.y * b.y, a.z * b.z)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector3(
				a.x / b.x, a.y / b.y, a.z / b.z)
	end,
	floor = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x), math.floor(a.y), math.floor(a.z))
	end,
	round = function(a)
		return buildat.safe.Vector3(
				math.floor(a.x+0.5), math.floor(a.y+0.5), math.floor(a.z+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector3(
				a.x + b.x, a.y + b.y, a.z + b.z)
	end,
	sub = function(a, b)
		return buildat.safe.Vector3(
				a.x - b.x, a.y - b.y, a.z - b.z)
	end,
	mul = function(a, b)
		return buildat.safe.Vector3(
				a.x * b, a.y * b, a.z * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector3(
				a.x / b, a.y / b, a.z / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y + a.z*a.z)
	end,
}
function buildat.safe.Vector3(x, y, z)
	local self = {}
	if x ~= nil and y == nil and z == nil then
		assert(type(x.x) == "number" and type(x.y) == "number" and
				type(x.z) == "number")
		self.x = x.x
		self.y = x.y
		self.z = x.z
	else
		self.x = x
		self.y = y
		self.z = z
	end
	setmetatable(self, {
		__index = Vector3_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector3_prototype.add,
		__sub = Vector3_prototype.sub,
		__mul = Vector3_prototype.mul,
		__div = Vector3_prototype.div,
	})
	return self
end

local Vector2_prototype = {
	x = 0,
	y = 0,
	dump = function(a)
		return "("..a.x..", "..a.y..")"
	end,
	eq = function(a, b)
		return (a.x == b.x and a.y == b.y)
	end,
	mul_components = function(a, b)
		return buildat.safe.Vector2(
				a.x * b.x, a.y * b.y)
	end,
	div_components = function(a, b)
		return buildat.safe.Vector2(
				a.x / b.x, a.y / b.y)
	end,
	floor = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x), math.floor(a.y))
	end,
	round = function(a)
		return buildat.safe.Vector2(
				math.floor(a.x+0.5), math.floor(a.y+0.5))
	end,
	add = function(a, b)
		return buildat.safe.Vector2(
				a.x + b.x, a.y + b.y)
	end,
	sub = function(a, b)
		return buildat.safe.Vector2(
				a.x - b.x, a.y - b.y)
	end,
	mul = function(a, b)
		return buildat.safe.Vector2(
				a.x * b, a.y * b)
	end,
	div = function(a, b)
		return buildat.safe.Vector2(
				a.x / b, a.y / b)
	end,
	length = function(a)
		return math.sqrt(a.x*a.x + a.y*a.y)
	end,
}
function buildat.safe.Vector2(x, y)
	local self = {}
	if x ~= nil and y == nil then
		assert(type(x.x) == "number" and type(x.y) == "number")
		self.x = x.x
		self.y = x.y
	else
		self.x = x
		self.y = y
	end
	setmetatable(self, {
		__index = Vector2_prototype,
		__eq = Vector3_prototype.eq,
		__add = Vector2_prototype.add,
		__sub = Vector2_prototype.sub,
		__mul = Vector2_prototype.mul,
		__div = Vector2_prototype.div,
	})
	return self
end

-- vim: set noet ts=4 sw=4:
