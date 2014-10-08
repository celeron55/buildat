-- Buildat: client/api.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/api")

buildat.connect_server    = __buildat_connect_server
buildat.extension_path    = __buildat_extension_path

buildat.safe.disconnect    = __buildat_disconnect

function buildat.safe.set_simple_voxel_model(safe_node, w, h, d, data)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("Node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe
	__buildat_set_simple_voxel_model(node, w, h, d, data)
end

function buildat.safe.set_8bit_voxel_geometry(safe_node, w, h, d, data)
	if not getmetatable(safe_node) or
			getmetatable(safe_node).type_name ~= "Node" then
		error("Node is not a sandboxed Node instance")
	end
	node = getmetatable(safe_node).unsafe
	__buildat_set_8bit_voxel_geometry(node, w, h, d, data)
end

-- vim: set noet ts=4 sw=4:
