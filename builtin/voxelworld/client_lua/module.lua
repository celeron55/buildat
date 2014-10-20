-- Buildat: builtin/voxelworld/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("voxelworld")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local cereal = require("buildat/extension/cereal")
local dump = buildat.dump
local M = {}

local UPDATE_TIME_FRACTION = 0.10

--local LOD_DISTANCE = 140
--local LOD_DISTANCE = 100
local LOD_DISTANCE = 80
--local LOD_DISTANCE = 50
local LOD_THRESHOLD = 0.2

local PHYSICS_DISTANCE = 100
local INITIAL_PHYSICS_NEAR_WEIGHT = 1.0

local INITIAL_GEOMETRY_NEAR_WEIGHT = 0.15

local MAX_LOD = 4

local camera_node = nil
local update_counter = -1

local camera_p = magic.Vector3(0, 0, 0)
local camera_dir = magic.Vector3(0, 0, 0)

local camera_last_p = camera_p
local camera_last_dir = camera_dir

local end_of_update_processing_us = 0

local voxel_reg = buildat.createVoxelRegistry()
local atlas_reg = buildat.createAtlasRegistry()

M.chunk_size_voxels = nil
M.section_size_chunks = nil
M.section_size_voxels = nil
-- Start higher than any conceivable value because otherwise things will never
-- be triggered to reflect this value
M.camera_far_clip = 1000

-- voxelworld is ready once the init and voxel_registry packets (and in the
-- future possibly some other ones) have been received)
local is_ready = false
local on_ready_callbacks = {}

function on_ready()
	if is_ready then
		error("on_ready(): already ready")
	end
	is_ready = true
	for _, v in ipairs(on_ready_callbacks) do
		v()
	end
	on_ready_callbacks = nil
end

local geometry_update_cbs = {} -- function(node)

function M.init()
	log:info("voxelworld.init()")

	local node_update_queue = buildat.SpatialUpdateQueue()

	local function queue_initial_node_update(node)
		node_update_queue:put(node:GetWorldPosition(),
				INITIAL_GEOMETRY_NEAR_WEIGHT, M.camera_far_clip * 1.2,
				nil, nil, {
			type = "geometry",
			current_lod = 0,
			node_id = node:GetID(),
		})
		node_update_queue:put(node:GetWorldPosition(),
				INITIAL_PHYSICS_NEAR_WEIGHT, PHYSICS_DISTANCE, nil, nil, {
			type = "physics",
			node_id = node:GetID(),
		})
	end

	buildat.sub_packet("voxelworld:init", function(data)
		local values = cereal.binary_input(data, {"object",
			{"chunk_size_voxels", {"object",
				{"x", "int32_t"},
				{"y", "int32_t"},
				{"z", "int32_t"},
			}},
			{"section_size_chunks", {"object",
				{"x", "int32_t"},
				{"y", "int32_t"},
				{"z", "int32_t"},
			}},
		})
		log:info("voxelworld:init: "..dump(values))
		M.chunk_size_voxels = buildat.Vector3(values.chunk_size_voxels)
		M.section_size_chunks = buildat.Vector3(values.section_size_chunks)
		M.section_size_voxels =
				M.chunk_size_voxels:mul_components(M.section_size_chunks)
	end)

	buildat.sub_packet("voxelworld:voxel_registry", function(data)
		voxel_reg:deserialize(data)
		on_ready() -- This is the last packet
	end)

	buildat.sub_packet("voxelworld:node_voxel_data_updated", function(data)
		local values = cereal.binary_input(data, {"object",
			{"node_id", "int32_t"},
		})
		log:info("voxelworld:node_voxel_data_updated: "..dump(values))
		local node = replicate.main_scene:GetNode(values.node_id)
		queue_initial_node_update(node)
	end)

	local function update_voxel_geometry(node)
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()

		local node_p = node:GetWorldPosition()
		local d = (node_p - camera_p):Length()
		local lod_fraction = d / LOD_DISTANCE
		local lod = math.floor(1 + lod_fraction)
		if lod > MAX_LOD then lod = MAX_LOD end

		log:verbose("update_voxel_geometry(): lod="..lod..
				", d="..math.floor(d)..", #data="..data:GetSize()..
				", node="..node:GetID())

		for _, cb in ipairs(geometry_update_cbs) do
			cb(node)
		end

		local near_trigger_d = nil
		local near_weight = nil
		local far_trigger_d = nil
		local far_weight = nil

		if d >= M.camera_far_clip * 1.4 then
			log:verbose("Clearing voxel geometry outside camera far clip ("
					..M.camera_far_clip..")")
			buildat.clear_voxel_geometry(node)

			-- clip out -> 4
			near_trigger_d = 1.2 * M.camera_far_clip
			near_weight = 0.4
		elseif lod == 1 then
			buildat.set_voxel_geometry(
					node, data, voxel_reg, atlas_reg)

			-- 1 -> 2
			far_trigger_d = LOD_DISTANCE * (1.0 + LOD_THRESHOLD)
			far_weight = 0.5
		else
			buildat.set_voxel_lod_geometry(lod, node, data, voxel_reg, atlas_reg)

			if lod == 1 then
				-- Shouldn't go here
			elseif lod == 2 then
				-- 2 -> 1
				near_trigger_d = LOD_DISTANCE * (1.0 - LOD_THRESHOLD)
				near_weight = 0.75
				-- 2 -> 3
				far_trigger_d = 2 * LOD_DISTANCE * (1.0 + LOD_THRESHOLD)
				far_weight = 0.4
			elseif lod == 3 then
				-- 3 -> 2
				near_trigger_d = 2 * LOD_DISTANCE * (1.0 - LOD_THRESHOLD)
				near_weight = 0.6
				-- 3 -> 4
				far_trigger_d = 3 * LOD_DISTANCE * (1.0 + LOD_THRESHOLD)
				far_weight = 0.4
			elseif lod == 4 then
				-- 4 -> 3
				near_trigger_d = 3 * LOD_DISTANCE * (1.0 - LOD_THRESHOLD)
				near_weight = 0.5
				-- 4 -> clip out
				far_trigger_d = M.camera_far_clip * 1.4
				far_weight = 0.4
			end
		end
		node_update_queue:put(node_p,
				near_weight, near_trigger_d,
				far_weight, far_trigger_d, {
			type = "geometry",
			current_lod = lod,
			node_id = node:GetID(),
		})
	end

	local function update_voxel_physics(node)
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()

		local node_p = node:GetWorldPosition()
		local d = (node_p - camera_p):Length()

		log:verbose("update_voxel_physics(): d="..math.floor(d)..
				", #data="..data:GetSize()..", node="..node:GetID())

		local near_trigger_d = nil
		local near_weight = nil
		local far_trigger_d = nil
		local far_weight = nil

		if d > PHYSICS_DISTANCE then
			log:verbose("Clearing physics boxes outside physics distance ("..
					PHYSICS_DISTANCE..")")
			buildat.clear_voxel_physics_boxes(node)

			near_trigger_d = PHYSICS_DISTANCE * 0.8
			near_weight = 1.0
		else
			buildat.set_voxel_physics_boxes(node, data, voxel_reg)

			far_trigger_d = PHYSICS_DISTANCE * 1.2
			far_weight = 0.2
		end
		node_update_queue:put(node_p,
				near_weight, near_trigger_d,
				far_weight, far_trigger_d, {
			type = "physics",
			node_id = node:GetID(),
		})
	end

	magic.SubscribeToEvent("Update", function(event_type, event_data)
		buildat.profiler_block_begin("Buildat|voxelworld:update")

		-- Required for handling device resets (eg. fullscreen toggle)
		atlas_reg:update()

		--local t0 = buildat.get_time_us()
		--local dt = event_data:GetFloat("TimeStep")
		update_counter = update_counter + 1

		if camera_node then
			camera_dir = camera_node.direction
			camera_p = camera_node:GetWorldPosition()
			M.camera_far_clip = camera_node:GetComponent("Camera").farClip
		end

		if camera_node and M.section_size_voxels then
			-- TODO: How should position information be sent to the server?
			local p = camera_p
			if update_counter % 60 == 0 then
				local section_p = buildat.Vector3(p):div_components(
						M.section_size_voxels):floor()
				--log:info("p: "..p.x..", "..p.y..", "..p.z.." -> section_p: "..
				--		section_p.x..", "..section_p.y..", "..section_p.z)
				--[[send_get_section(section_p + buildat.Vector3( 0, 0, 0))
				send_get_section(section_p + buildat.Vector3(-1, 0, 0))
				send_get_section(section_p + buildat.Vector3( 1, 0, 0))
				send_get_section(section_p + buildat.Vector3( 0, 1, 0))
				send_get_section(section_p + buildat.Vector3( 0,-1, 0))
				send_get_section(section_p + buildat.Vector3( 0, 0, 1))
				send_get_section(section_p + buildat.Vector3( 0, 0,-1))]]
			end
		end

		-- Node updates: Handle one or a few per frame
		local current_us = buildat.get_time_us()
		-- Spend time doing this proportionate to the rest of the update cycle
		local last_outer_frame_us = (current_us - end_of_update_processing_us)
		local max_handling_time_us = last_outer_frame_us * UPDATE_TIME_FRACTION
		local stop_at_us = current_us + max_handling_time_us

		node_update_queue:set_p(camera_p)
		-- Scale queue update operations according to the handling time of the
		-- rest of the processing
		node_update_queue:update(max_handling_time_us / 50 + 1)

		for i = 1, 10 do -- Usually there is time only for a few
			local f = node_update_queue:peek_next_f()
			local fw = node_update_queue:peek_next_fw()
			local did_update = false
			if f and f <= 1.0 then
				local node_update = node_update_queue:get()
				local node = replicate.main_scene:GetNode(node_update.node_id)
				log:verbose("Node update #"..
						node_update_queue:get_length()..
						" (f="..(math.floor(f*100)/100)..""..
						", fw="..(math.floor(fw*100)/100)..")"..
						": "..node:GetName())
				if node_update.type == "geometry" then
					update_voxel_geometry(node)
				end
				if node_update.type == "physics" then
					update_voxel_physics(node)
				end
				did_update = true
			else
				log:verbose("Poked update #"..
						node_update_queue:get_length()..
						" (f="..(math.floor((f or -1)*100)/100)..""..
						", fw="..(math.floor((fw or -1)*100)/100)..")")
				--node_update_queue.queue = {} -- For testing
			end
			-- Check this at the end of the loop so at least one is handled
			if not did_update or buildat.get_time_us() >= stop_at_us then
				log:debug("Handled "..i.." node updates")
				break
			end
		end
		end_of_update_processing_us = buildat.get_time_us()

		if camera_node then
			camera_last_dir = camera_dir
			camera_last_p = camera_p
		end
		--log:info(buildat.get_time_us()-t0)
		buildat.profiler_block_end()
	end)

	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("buildat_voxel_data"):IsEmpty() then
			queue_initial_node_update(node)
		end
		--local name = node:GetName()
	end)
end

function M.set_camera(new_camera_node)
	camera_node = new_camera_node
end

function M.get_voxel_registry()
	return voxel_reg
end

function M.get_atlas_registry()
	return atlas_reg
end

function M.sub_ready(cb)
	if is_ready then
		cb()
	else
		table.insert(on_ready_callbacks, cb)
	end
end

function M.sub_geometry_update(cb)
	table.insert(geometry_update_cbs, cb)
end

function send_get_section(p)
	local data = cereal.binary_output({
		p = {
			x = p.x,
			y = p.y,
			z = p.z,
		},
	}, {"object",
		{"p", {"object",
			{"x", "int32_t"},
			{"y", "int32_t"},
			{"z", "int32_t"},
		}},
	})
	--log:info(dump(buildat.bytes(data)))
	buildat.send_packet("voxelworld:get_section", data)
end

return M
-- vim: set noet ts=4 sw=4:
