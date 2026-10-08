-- Buildat: builtin/luanti/client_lua/bodies.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The module's client half: the bodies. Run by module.lua, which takes
-- what this puts in M into its own ([SPLITS]: moved out as it was).

local log = buildat.Logger("luanti")
local magic = require("buildat/extension/urho3d")
local cereal = require("buildat/extension/cereal")
local voxelworld = require("buildat/module/voxelworld")

local M = {}

--
-- Bodies: voxels that came off the world ([BODY_INTERACT])
--
-- A node with voxel_body_data is a volume in the world's own format,
-- meshed with the world's registry the way a chunk is and moved by the
-- server. Its voxels live in a region of the same coordinate space far
-- above the map -- region k from (0, REGION_Y + k * REGION_STRIDE, 0), a
-- body voxel's position being base + local -- so a dig or a place on one
-- goes over the wire as an ordinary position and the server's own node
-- functions resolve it. pointed_body() is the ray into them, beside
-- pointed_object() above; body_world() is where a region position is
-- drawn.
M.REGION_Y = 1000000
M.REGION_STRIDE = 4096
local body_nodes = {} -- node id -> {node, volume, k, size}

local function setup_body(node)
	local data = node:GetVar("voxel_body_data"):GetBuffer()
	local voxel_reg = voxelworld.get_voxel_registry()
	local atlas_reg = voxelworld.get_atlas_registry()
	if voxel_reg == nil or atlas_reg == nil then
		log:warning("body " .. node:GetID() .. ": no registry yet")
		return
	end
	local k = node:GetVar("voxel_body_region"):GetInt()
	local volume = buildat.deserialize_volume(data)
	local region = volume:get_enclosing_region()
	-- The one-voxel border is the volume's; the body is what is inside
	local size = buildat.Vector3(region.x1 - region.x0 - 1,
			region.y1 - region.y0 - 1, region.z1 - region.z0 - 1)
	body_nodes[node:GetID()] = {node = node, volume = volume, k = k,
			size = size}
	-- Lit the way a chunk is: the mesher bakes the light the voxels
	-- carried in the world, and voxel_shading's materials over it.
	-- simplified: no horizon map, so a body under the sky wears the
	-- shadow it had where it came from
	local voxel_shading = require("buildat/module/voxel_shading")
	buildat.set_voxel_geometry(node, data, voxel_reg, atlas_reg,
			voxelworld.use_skylight, function()
		voxel_shading.apply_to_node(node)
	end, nil)
	log:info("body " .. node:GetID() .. " meshed (region " .. k .. ")")
end

require("buildat/extension/replicate").sub_sync_node_added({}, function(node)
	if not node:GetVar("voxel_body_data"):IsEmpty() then
		setup_body(node)
	end
end)
-- A body a voxel of which changed: meshed again once its var has come
-- (it replicates on the network frame after the packet; a third of a
-- second is that with room)
local body_stale = {} -- node id -> when to mesh, in us
buildat.sub_packet("luanti:body_changed", function(data)
	local v = cereal.binary_input(data, {"object", {"id", "int32_t"}})
	body_stale[v.id] = buildat.get_time_us() + 300000
end)
magic.SubscribeToEvent("Update", function()
	local now = buildat.get_time_us()
	for id, at in pairs(body_stale) do
		if now >= at then
			body_stale[id] = nil
			local b = body_nodes[id]
			if b then
				setup_body(b.node)
			end
		end
	end
end)
require("buildat/extension/replicate").sub_sync_node_removed(function(node, node_id)
	body_nodes[node_id] = nil
end)

-- The body a region position is in, and its local voxel
local function body_of(p)
	if p.y < M.REGION_Y then
		return nil
	end
	local k = math.floor((p.y - M.REGION_Y) / M.REGION_STRIDE)
	for _, b in pairs(body_nodes) do
		if b.k == k then
			return b, buildat.Vector3(p.x, p.y - M.REGION_Y - k * M.REGION_STRIDE, p.z)
		end
	end
	return nil
end

-- Where a region position's voxel is drawn: the body's transform over
-- its local voxel's centre, as a buildat.Vector3; nil for none
function M.body_world(p)
	local b, l = body_of(p)
	if not b then
		return nil
	end
	local w = b.node.worldTransform * magic.Vector3(l.x + 0.5, l.y + 0.5, l.z + 0.5)
	return buildat.Vector3(w.x, w.y, w.z)
end

-- Every body's centre in the world, for a run that wants to look at one
function M.bodies()
	local out = {}
	for _, b in pairs(body_nodes) do
		local c = b.node.worldTransform * magic.Vector3(b.size.x / 2,
				b.size.y / 2, b.size.z / 2)
		out[#out + 1] = {x = c.x, y = c.y, z = c.z, id = b.node:GetID()}
	end
	return out
end

-- The node name at a region position, as node_name_at() answers for the
-- map's own
function M.body_node_name(p)
	local b, l = body_of(p)
	if not b then
		return nil
	end
	local reg = voxelworld.get_voxel_registry()
	local id = reg:id_of(b.volume:get_voxel_at(l.x, l.y, l.z))
	if id == 0 then
		return nil
	end
	local def = reg:get_by_id(id)
	return def and def.name.block_name or nil
end

-- The ray from (x, y, z) along (dx, dy, dz) into every body within
-- max_distance: the first solid voxel hit as its region position, the
-- voxel before it (the place's "above") and the distance; the ray walked
-- in each body's own space, a tenth of a voxel a step, as the world's
-- march is. Air and nothing are the registry's id 0 and the game's air.
function M.pointed_body(x, y, z, dx, dy, dz, max_distance)
	local reg = voxelworld.get_voxel_registry()
	if reg == nil then
		return nil
	end
	local best, best_above, best_t = nil, nil, max_distance
	for _, b in pairs(body_nodes) do
		local inv = b.node.worldTransform:Inverse()
		local o = inv * magic.Vector3(x, y, z)
		local d = inv * magic.Vector3(x + dx, y + dy, z + dz) - o
		local last = nil
		local n = math.floor(best_t / 0.1)
		for i = 1, n do
			local t = i * 0.1
			local lx = math.floor(o.x + d.x * t)
			local ly = math.floor(o.y + d.y * t)
			local lz = math.floor(o.z + d.z * t)
			if lx >= 0 and ly >= 0 and lz >= 0 and lx < b.size.x and
					ly < b.size.y and lz < b.size.z then
				local id = reg:id_of(b.volume:get_voxel_at(lx, ly, lz))
				local def = id ~= 0 and reg:get_by_id(id)
				if def and def.name.block_name ~= "air" then
					local base_y = M.REGION_Y + b.k * M.REGION_STRIDE
					best = buildat.Vector3(lx, base_y + ly, lz)
					best_above = last and buildat.Vector3(last[1],
							base_y + last[2], last[3]) or best
					best_t = t
					break
				end
			end
			last = {lx, ly, lz}
		end
	end
	return best, best_above, best_t
end

return M
-- vim: set noet ts=4 sw=4:
