-- Buildat: client/replication.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
local log = buildat.Logger("__client/replication")

-- Viewport 0 is created in C++. It is set to view the network-synchronized
-- scene with one camera.
-- NOTE: Yes, this is a bit of a hack
local viewport = renderer:GetViewport(0)
local scene = viewport:GetScene()

-- Contains a non-sandboxed Scene
__buildat_replicated_scene = scene

-- Remove temporary viewport and camera from scene
local camera_node = scene:GetChild("__buildat_replicated_scene_camera")
scene:RemoveChild(camera_node)
renderer:SetViewport(0, nil)

-- vim: set noet ts=4 sw=4:

