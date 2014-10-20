-- Buildat: builtin/ground_plane_lighting/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local dump = buildat.dump
local log = buildat.Logger("ground_plane_lighting")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local voxelworld = require("buildat/module/voxelworld")
local M = {}

voxelworld.sub_geometry_update(function(node)
	local yst_data = node:GetVar("gpl_voxel_yst_data"):GetBuffer()
	log:verbose("#yst_data="..yst_data:GetSize())
	local yst_volume = buildat.deserialize_volume_8bit(yst_data)

	local cs = voxelworld.chunk_size_voxels

	local v_min = cs.y + 1

	for x = 0, cs.x - 1 do
		for z = 0, cs.z - 1 do
			local v = yst_volume:get_voxel_at(0, 0, 0)
			--log:verbose("voxel at ("..x..",0,"..z.."): "..v.id)
			if v.data < v_min then
				v_min = v.data
			end
		end
	end

	--local v_avg = v_sum / cs.x / cs.z
	--log:verbose("v_avg: "..v_avg)

	--local has_sunlight = buildat.voxel_heuristic_has_sunlight(
	--		data, voxel_reg)
	-- TODO: This is a hack that doesn't even work properly
	local has_sunlight = (v_min < cs.y + 1)

	local node_p = node:GetWorldPosition()
	local scene = node.scene

	local zone_node = scene:CreateChild("Zone")
	local zone = zone_node:CreateComponent("Zone")
	zone.boundingBox = magic.BoundingBox(
			node_p - magic.Vector3(cs.x, cs.y, cs.z)/2,
			node_p + magic.Vector3(cs.x, cs.y, cs.z)/2
	)
	if has_sunlight then
		zone.ambientColor = magic.Color(0.1, 0.1, 0.1)
		zone.fogColor = magic.Color(0.6, 0.7, 0.8)
	else
		zone.ambientColor = magic.Color(0, 0, 0)
		zone.fogColor = magic.Color(0, 0, 0)
	end
	--zone.ambientColor = magic.Color(
	--		math.random(), math.random(), math.random())
	--zone.fogEnd = 10 + math.random() * 50
	zone.fogStart = 10
	zone.fogEnd = voxelworld.camera_far_clip * 1.2
	--zone.ambientGradient = true
end)

return M
-- vim: set noet ts=4 sw=4:
