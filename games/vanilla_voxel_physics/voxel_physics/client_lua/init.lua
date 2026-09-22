-- Buildat: games/vanilla_voxel_physics/voxel_physics/client_lua/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The bodies that came off the world ([VOXEL_PHYSICS_SAMPLE]): a node with
-- voxel_body_data is a volume in the world's own format, meshed with the
-- world's registry the way a chunk is; the server moves it. Run after
-- main/init.lua, which is what has the registries.
local log = buildat.Logger("voxel_physics")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local voxel_shading = require("buildat/module/voxel_shading")

local function setup_body(node)
	local data = node:GetVar("voxel_body_data"):GetBuffer()
	local voxel_reg = voxelworld.get_voxel_registry()
	local atlas_reg = voxelworld.get_atlas_registry()
	if voxel_reg == nil or atlas_reg == nil then
		log:warning("body " .. node:GetID() .. ": no registry yet")
		return
	end
	-- Lit the way a chunk is: the mesher bakes the light the voxels
	-- carried in the world, and voxel_shading's materials over it, which
	-- is the callback voxelworld hands a chunk. simplified: no horizon
	-- map, so a body under the sky wears the shadow it had where it
	-- came from
	buildat.set_voxel_geometry(node, data, voxel_reg, atlas_reg,
			voxelworld.use_skylight, function()
		voxel_shading.apply_to_node(node)
	end, nil)
	log:info("body " .. node:GetID() .. " meshed")
end

replicate.sub_sync_node_added({}, function(node)
	if not node:GetVar("voxel_body_data"):IsEmpty() then
		setup_body(node)
	end
end)
log:info("voxel_physics client half loaded")
