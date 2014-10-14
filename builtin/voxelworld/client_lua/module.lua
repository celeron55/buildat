-- Buildat: builtin/voxelworld/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("voxelworld")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local cereal = require("buildat/extension/cereal")
local dump = buildat.dump
local M = {}

local LOD_DISTANCE = 100
--local LOD_DISTANCE = 140
--local LOD_DISTANCE = 50
local LOD_THRESHOLD = 0.2

local camera_node = nil
local update_counter = -1

local camera_p = magic.Vector3(0, 0, 0)
local camera_dir = magic.Vector3(0, 0, 0)
local camera_last_p = camera_p
local camera_last_dir = camera_dir

local end_of_update_processing_us = 0

M.chunk_size_voxels = nil
M.section_size_chunks = nil
M.section_size_voxels = nil

--[[
	table.binsearch( table, value [, compval [, reversed] ] )

	Searches the table through BinarySearch for the given value.
	If the  value is found:
		it returns a table holding all the mathing indices (e.g. { startindice,endindice } )
		endindice may be the same as startindice if only one matching indice was found
	If compval is given:
		then it must be a function that takes one value and returns a second value2,
		to be compared with the input value, e.g.:
		compvalue = function( value ) return value[1] end
	If reversed is set to true:
		then the search assumes that the table is sorted in reverse order (largest value at position 1)
		note when reversed is given compval must be given as well, it can be nil/_ in this case
	Return value:
		on success: a table holding matching indices (e.g. { startindice,endindice } )
		on failure: nil
]]--
do
	-- Avoid heap allocs for performance
	local default_fcompval = function(value) return value end
	local fcompf = function(a,b) return a < b end
	local fcompr = function(a,b) return a > b end
	function table_binsearch(t,value,fcompval,reversed)
		-- Initialise functions
		local fcompval = fcompval or default_fcompval
		local fcomp = reversed and fcompr or fcompf
		--  Initialise numbers
		local iStart,iEnd,iMid = 1,#t,0
		-- Binary Search
		while iStart <= iEnd do
			-- calculate middle
			iMid = math.floor((iStart+iEnd)/2)
			-- get compare value
			local value2 = fcompval(t[iMid])
			-- get all values that match
			if value == value2 then
				local tfound,num = {iMid,iMid},iMid - 1
				while value == fcompval(t[num]) do
					tfound[1],num = num,num - 1
				end
				num = iMid + 1
				while value == fcompval(t[num]) do
					tfound[2],num = num,num + 1
				end
				return tfound
			-- keep searching
			elseif fcomp(value, value2) then
				iEnd = iMid - 1
			else
				iStart = iMid + 1
			end
		end
	end
end

--[[
	table.bininsert( table, value [, comp] )

	Inserts a given value through BinaryInsert into the table sorted by [, comp].

	If 'comp' is given, then it must be a function that receives
	two table elements, and returns true when the first is less
	than the second, e.g. comp = function(a, b) return a > b end,
	will give a sorted table, with the biggest value on position 1.
	[, comp] behaves as in table.sort(table, value [, comp])
	returns the index where 'value' was inserted
]]--
do
	-- Avoid heap allocs for performance
	local fcomp_default = function(a,b) return a < b end
	function table_bininsert(t, value, fcomp)
		-- Initialise compare function
		local fcomp = fcomp or fcomp_default
		--  Initialise numbers
		local iStart,iEnd,iMid,iState = 1,#t,1,0
		-- Get insert position
		while iStart <= iEnd do
			-- calculate middle
			iMid = math.floor((iStart+iEnd)/2)
			-- compare
			if fcomp(value, t[iMid]) then
				iEnd,iState = iMid - 1,0
			else
				iStart,iState = iMid + 1,1
			end
		end
		table.insert(t,(iMid+iState),value)
		return (iMid+iState)
	end
end

local function SpatialUpdateQueue()
	local function fcomp(a, b)
		-- Always maintain all f<=1.0 items at the end of the table
		if a.f > 1.0 and b.f <= 1.0 then
			return true
		end
		if a.f <= 1.0 and b.f > 1.0 then
			return false
		end
		return a.fw > b.fw
	end
	local self = {
		p = buildat.Vector3(0, 0, 0),
		queue_oldest_p = buildat.Vector3(0, 0, 0),
		queue = {},
		old_queue = nil,

		-- This has to be called once per frame or so
		update = function(self, max_operations)
			max_operations = max_operations or 100
			if self.old_queue then
				log:debug("SpatialUpdateQueue(): Items in old queue: "..
						#self.old_queue)
				-- Move stuff from old queue to new queue
				for i = 1, max_operations do
					local item = table.remove(self.old_queue)
					if not item then
						self.old_queue = nil
						break
					end
					self:put_item(item)
				end
			end
		end,
		set_p = function(self, p)
			p = buildat.Vector3(p) -- Strip out the heavy Urho3D wrapper
			self.p = p
			if self.old_queue == nil and
					(p - self.queue_oldest_p):length() > 20 then
				-- Move queue to old_queue and reset queue
				self.old_queue = self.queue
				self.queue = {}
				self.queue_oldest_p = self.p
			end
		end,
		put_item = function(self, item)
			local d = (item.p - self.p):length()
			item.f = nil
			item.fw = nil
			if item.near_trigger_d then
				local f_near = d / item.near_trigger_d
				local fw_near = f_near / item.near_weight
				if item.fw == nil or (fw_near < item.fw and
						(item.f == nil or f_near < item.f)) then
					item.f = f_near
					item.fw = fw_near
				end
			end
			if item.far_trigger_d then
				local f_far = item.far_trigger_d / d
				local fw_far = f_far / item.far_weight
				if item.fw == nil or (fw_far < item.fw and
						(item.f == nil or f_far < item.f)) then
					item.f = f_far
					item.fw = fw_far
				end
			end
			assert(item.f)
			assert(item.fw)
			log:verbose("put_item"..
					": d="..dump(d)..
					", near_weight="..dump(item.near_weight)..
					", near_trigger_d="..dump(item.near_trigger_d)..
					", far_weight="..dump(item.far_weight)..
					", far_trigger_d="..dump(item.far_trigger_d)..
					" -> f="..item.f..", fw="..item.fw)
			table_bininsert(self.queue, item, fcomp)
		end,
		-- Put something to be prioritized bidirectionally
		put = function(self, p, near_weight, near_trigger_d,
				far_weight, far_trigger_d, value)
			if near_trigger_d and far_trigger_d then
				assert(near_trigger_d < far_trigger_d)
				assert(near_weight)
				assert(far_weight)
			else
				assert((near_trigger_d and near_weight) or
						(far_trigger_d and far_weight))
			end
			p = buildat.Vector3(p) -- Strip out the heavy Urho3D wrapper
			self:put_item({p=p, value=value,
					near_weight=near_weight, near_trigger_d=near_trigger_d,
					far_weight=far_weight, far_trigger_d=far_trigger_d})
		end,
		get = function(self)
			local item = table.remove(self.queue)
			if not item then return nil end
			return item.value
		end,
		-- item.f is the trigger_d value normalized so that f<1.0 means the item
		-- has passed its trigger_d.
		peek_next_f = function(self)
			local item = self.queue[#self.queue]
			if not item then return nil end
			return item.f
		end,
		-- item.fw is a comparison value; both near_priority and far_priority
		-- items are normalized so that values that have fw=1 have equal
		-- priority.
		peek_next_fw = function(self)
			local item = self.queue[#self.queue]
			if not item then return nil end
			return item.fw
		end,
		get_length = function(self)
			return #self.queue
		end,
	}
	return self
end

function M.init()
	log:info("voxelworld.init()")

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
		log:info(dump(values))
		M.chunk_size_voxels = buildat.Vector3(values.chunk_size_voxels)
		M.section_size_chunks = buildat.Vector3(values.section_size_chunks)
		M.section_size_voxels =
				M.chunk_size_voxels:mul_components(M.section_size_chunks)
	end)

	--local node_update_queue = SpatialUpdateQueue()
	local node_update_queue = buildat.SpatialUpdateQueue()

	local function update_voxel_geometry(node)
		local data = node:GetVar("buildat_voxel_data"):GetBuffer()
		--local registry_name = node:GetVar("buildat_voxel_registry_name"):GetBuffer()

		-- TODO: node:GetWorldPosition() is not at center of node
		local node_p = node:GetWorldPosition()
		local d = (node_p - camera_p):Length()
		local lod_fraction = d / LOD_DISTANCE
		local lod = math.floor(1 + lod_fraction)
		if lod > 3 then
			lod = 3
		end

		log:verbose("update_voxel_geometry(): node="..dump(node:GetName())..
				", #data="..data:GetSize()..", d="..d..", lod="..lod)

		local near_trigger_d = nil
		local near_weight = nil
		local far_trigger_d = nil
		local far_weight = nil

		if lod == 1 then
			buildat.set_voxel_geometry(node, data, registry_name)

			-- 1 -> 2
			far_trigger_d = LOD_DISTANCE * (1.0 + LOD_THRESHOLD)
			far_weight = 0.4
		else
			buildat.set_voxel_lod_geometry(lod, node, data, registry_name)

			if lod == 1 then
				-- Shouldn't go here
			elseif lod == 2 then
				-- 2 -> 1
				near_trigger_d = LOD_DISTANCE * (1.0 - LOD_THRESHOLD)
				near_weight = 2.0
				-- 2 -> 3
				far_trigger_d = 2 * LOD_DISTANCE * (1.0 + LOD_THRESHOLD)
				far_weight = 0.3
			elseif lod == 3 then
				-- 3 -> 2
				near_trigger_d = 2 * LOD_DISTANCE * (1.0 - LOD_THRESHOLD)
				near_weight = 0.5
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
		--local registry_name = node:GetVar("buildat_voxel_registry_name"):GetBuffer()

		log:verbose("update_voxel_physics(): node="..dump(node:GetName())..
				", #data="..data:GetSize())

		buildat.set_voxel_physics_boxes(node, data, registry_name)
	end

	magic.SubscribeToEvent("Update", function(event_type, event_data)
		--local t0 = buildat.get_time_us()
		--local dt = event_data:GetFloat("TimeStep")
		update_counter = update_counter + 1

		if camera_node then
			camera_dir = camera_node.direction
			camera_p = camera_node:GetWorldPosition()
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
		local max_handling_time_us = (current_us - end_of_update_processing_us) / 2
		local stop_at_us = current_us + max_handling_time_us

		node_update_queue:set_p(camera_p)
		-- Scale queue update operations according to the handling time of the
		-- rest of the processing
		node_update_queue:update(max_handling_time_us / 200 + 1)

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
	end)

	replicate.sub_sync_node_added({}, function(node)
		if not node:GetVar("buildat_voxel_data"):IsEmpty() then
			-- TODO: node:GetWorldPosition() is not at center of node
			node_update_queue:put(node:GetWorldPosition(),
					0.2, 1000.0, nil, nil, {
				type = "geometry",
				current_lod = 0,
				node_id = node:GetID(),
			})
			-- Create physics stuff when node comes closer than 100
			-- TODO: node:GetWorldPosition() is not at center of node
			node_update_queue:put(node:GetWorldPosition(),
					1.0, 100.0, nil, nil, {
				type = "physics",
				node_id = node:GetID(),
			})
		end
		--local name = node:GetName()
	end)
end

function M.set_camera(new_camera_node)
	camera_node = new_camera_node
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
