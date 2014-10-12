-- Buildat: builtin/voxelworld/client_lua/module.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("voxelworld")
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
local cereal = require("buildat/extension/cereal")
local dump = buildat.dump
local M = {}

local camera_node = nil
local update_counter = 0

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
	end)

	magic.SubscribeToEvent("Update", function(event_type, event_data)
		if camera_node then
			local p = camera_node.position
			if update_counter % 60 == 0 then
				--log:info("p: "..p.x..", "..p.y..", "..p.z)
				local data = cereal.binary_output({
					p = {
						x = p.x,
						y = p.y,
						z = p.z,
					},
				}, {"object",
					{"p", {"object",
						{"x", "double"},
						{"y", "double"},
						{"z", "double"},
					}},
				})
				buildat.send_packet("voxelworld:camera_position", data)
			end
			update_counter = update_counter + 1
		end
	end)
end

function M.set_camera(new_camera_node)
	camera_node = new_camera_node
end

return M
-- vim: set noet ts=4 sw=4:
