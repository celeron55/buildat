-- Buildat: extensions/skycube/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- The sky, rendered into a small cube for the world to reflect: sun, moon
-- and dawn where they are, rather than the gradient VoxelSky.xml baked at
-- build time with a sun disc at one fixed direction. One piece for both
-- Luanti clients -- games/vanilla and extensions/luanti_client --
-- since the sky shader and the zone handover are shared between them. See
-- [SKY_REFLECTIONS] in doc/plan/rendering_plan.md.
--
--   local skycube = require("buildat/extension/skycube")  -- the sandbox hands out .safe
--   local cube = skycube.new(magic, sky_material)  -- the skybox's material
--   zone.zoneTexture = cube.texture
--   cube:update()   -- when the sky has moved enough to show
--
-- The cube is a scene of its own holding one Skybox that shares the sky's
-- material, so whatever the client sets on the material -- the hour's
-- colours, the sun's direction, the moon -- is what the cube draws, and
-- six viewports on the cube's faces with one camera each at the origin.
-- The faces are drawn only when update() asks: a reflection nobody
-- watches change is not worth six renders a frame.
local M = {safe = {}}

-- 64 a side: a reflection is mip-blurred by roughness and a mirror of the
-- sky at this size is a sky
local SIZE = 64

-- Where each of Urho3D's six faces looks: the same directions, set the
-- same way (the node's direction, world up), that View.cpp gives a point
-- light's shadow cameras, so the faces land where the cube-map sampler
-- expects them
local FACES = {
	{face = "FACE_POSITIVE_X", dir = {1, 0, 0}},
	{face = "FACE_NEGATIVE_X", dir = {-1, 0, 0}},
	{face = "FACE_POSITIVE_Y", dir = {0, 1, 0}},
	{face = "FACE_NEGATIVE_Y", dir = {0, -1, 0}},
	{face = "FACE_POSITIVE_Z", dir = {0, 0, 1}},
	{face = "FACE_NEGATIVE_Z", dir = {0, 0, -1}},
}

local Cube = {}
Cube.__index = Cube

function M.safe.new(magic, material)
	local self = setmetatable({}, Cube)
	self.scene = magic.Scene()
	self.scene:CreateComponent("Octree")
	local node = self.scene:CreateChild("Sky")
	local box = node:CreateComponent("Skybox")
	box:SetModel(magic.cache:GetResource("Model", "Models/Box.mdl"))
	box.material = material

	-- Half floats: the sky is drawn in HDR at the reference's radiances
	-- (several times white, see [PBR_FIT]) and eight bits would clip it
	self.texture = magic.TextureCube:new()
	if not self.texture:SetSize(SIZE, magic.Graphics.GetRGBAFloat16Format(),
			magic.TEXTURE_RENDERTARGET) then
		error("skycube: could not make a " .. SIZE .. " render target cube")
	end
	self.surfaces = {}
	for i, f in ipairs(FACES) do
		local cam_node = self.scene:CreateChild("Face" .. i)
		cam_node.direction = magic.Vector3(f.dir[1], f.dir[2], f.dir[3])
		local camera = cam_node:CreateComponent("Camera")
		camera.fov = 90
		camera.nearClip = 0.1
		camera.farClip = 100
		local surface = self.texture:GetRenderSurface(magic[f.face])
		surface:SetViewport(0, magic.Viewport:new(self.scene, camera))
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		self.surfaces[i] = surface
	end
	self:update()
	return self
end

-- Draw the six faces again, on the next frame
function Cube:update()
	for _, surface in ipairs(self.surfaces) do
		surface:QueueUpdate()
	end
end

return M
